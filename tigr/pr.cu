
#include "../shared/timer.hpp"
#include "../shared/tigr_utilities.hpp"
#include "../shared/graph.hpp"
#include "../shared/virtual_graph.hpp"
#include "../shared/globals.hpp"
#include "../shared/argument_parsing.hpp"
#include "../shared/gpu_error_check.cuh"
#include <algorithm>
#define DELTA 0.01
// __global__ void maxAbs(float *pr1,
// 					   float *pr2,
// 					   long n)
// {
// 	__shared__ long cache[];
// 	long partId = blockDim.x * blockIdx.x + threadIdx.x;
// 	if (partId < n / 8)
// 	{
// 		if (threadIdx.x == 0)
// 		{
// 			cache[blockIdx.x] = 0;
// 		}
// 		__syncthreads();

// 		for (size_t i = 0; i < count; i++)
// 		{
// 			float d = abs(pr1[partId], pr2[partId]);
// 			atomicMax(&cache[blockIdx.x], d);
// 		}
// 		__syncthreads();

// 		if (threadIdx.x == 0)
// 		{
// 			cache[blockIdx.x] = 0;
// 		}
// 	}
// }

// __global__ void dabs(float *n1,float *n2,float *n3,unsigned int size){
// 	unsigned int index = threadIdx.x + (blockDim.x * blockIdx.x);

// }

// __global__ void getmaxcu(float *num, unsigned int size)
// {
// 	float temp;
// 	unsigned int index = threadIdx.x + (blockDim.x * blockIdx.x);
// 	unsigned int nTotalThreads = size;
// 	unsigned int i;
// 	unsigned int tenPoint = nTotalThreads / 10; // divide by ten
// 	if (index < tenPoint)
// 	{
// 		for (i = 1; i < 10; i++)
// 		{
// 			temp = num[index + tenPoint * i];
// 			//compare to "0" index
// 			if (temp > num[index])
// 			{
// 				num[index] = temp;
// 			}
// 		}
// 	}
// }

__global__ void kernel(unsigned int numParts,
					   unsigned int *nodePointer,
					   PartPointer *partNodePointer,
					   unsigned int *edgeList,
					   float *pr1,
					   float *pr2)
{
	int partId = blockDim.x * blockIdx.x + threadIdx.x;

	if (partId < numParts)
	{
		int id = partNodePointer[partId].node;
		int part = partNodePointer[partId].part;

		// int sourceWeight = dist[id];

		int thisPointer = nodePointer[id];
		int degree = edgeList[thisPointer];

		float sourcePR = (float)pr2[id] / degree;

		int numParts;
		if (degree % Part_Size == 0)
			numParts = degree / Part_Size;
		else
			numParts = degree / Part_Size + 1;

		int end;
		// int w8;
		int ofs = thisPointer + part + 1;

		for (int i = 0; i < Part_Size; i++)
		{
			if (part + i * numParts >= degree)
				break;
			end = ofs + i * numParts;
			// w8 = end + 1;

			atomicAdd(&pr1[edgeList[end]], sourcePR);
		}
	}
}

__global__ void clearLabel(float *prA, float *prB, unsigned int num_nodes, float base)
{
	unsigned int id = blockDim.x * blockIdx.x + threadIdx.x;
	if (id < num_nodes)
	{
		prA[id] = base + prA[id] * 0.85;
		prB[id] = 0;
	}
}

int main(int argc, char **argv)
{
	ArgumentParser arguments(argc, argv, false, true);

	Graph graph(arguments.input, false);
	graph.ReadGraph();

	VirtualGraph vGraph(graph);

	vGraph.MakeUGraph();

	uint num_nodes = graph.num_nodes;
	uint num_edges = graph.num_edges;

	if (arguments.hasDeviceID)
		cudaSetDevice(arguments.deviceID);

	cudaFree(0);

	float *pr1, *pr2, *prd;
	pr1 = new float[num_nodes];
	pr2 = new float[num_nodes];
	prd = new float[num_nodes];

	float initPR = (float) 0.85;
	cout << initPR << endl;

	for (int i = 0; i < num_nodes; i++)
	{
		pr1[i] = 0;
		pr2[i] = initPR;
	}

	unsigned int *d_nodePointer;
	unsigned int *d_edgeList;
	PartPointer *d_partNodePointer;
	float *d_pr1;
	float *d_pr2;
	bool finished;
	bool *d_finished;
	gpuErrorcheck(cudaMalloc(&d_finished, sizeof(bool)));
	finished = false;
	gpuErrorcheck(cudaMemcpy(d_finished, &finished, sizeof(bool), cudaMemcpyHostToDevice));

	gpuErrorcheck(cudaMalloc(&d_nodePointer, num_nodes * sizeof(unsigned int)));
	gpuErrorcheck(cudaMalloc(&d_edgeList, (num_edges + num_nodes) * sizeof(unsigned int)));
	gpuErrorcheck(cudaMalloc(&d_pr1, num_nodes * sizeof(float)));
	gpuErrorcheck(cudaMalloc(&d_pr2, num_nodes * sizeof(float)));
	gpuErrorcheck(cudaMalloc(&d_partNodePointer, vGraph.numParts * sizeof(PartPointer)));

	Timer t3;
	t3.Start();

	gpuErrorcheck(cudaMemcpy(d_nodePointer, vGraph.nodePointer, num_nodes * sizeof(unsigned int), cudaMemcpyHostToDevice));
	gpuErrorcheck(cudaMemcpy(d_edgeList, vGraph.edgeList, (num_edges + num_nodes) * sizeof(unsigned int), cudaMemcpyHostToDevice));
	gpuErrorcheck(cudaMemcpy(d_pr1, pr1, num_nodes * sizeof(float), cudaMemcpyHostToDevice));
	gpuErrorcheck(cudaMemcpy(d_pr2, pr2, num_nodes * sizeof(float), cudaMemcpyHostToDevice));
	gpuErrorcheck(cudaMemcpy(d_partNodePointer, vGraph.partNodePointer, vGraph.numParts * sizeof(PartPointer), cudaMemcpyHostToDevice));

	Timer t;
	t.Start();

	int itr = 0;
	// make it fast
	float base = (float)0.15 / num_nodes;
	do
	{
		itr++;
		if (itr % 2 == 1)
		{
			kernel<<<vGraph.numParts / 512 + 1, 512>>>(vGraph.numParts,
													   d_nodePointer,
													   d_partNodePointer,
													   d_edgeList,
													   d_pr1,
													   d_pr2);

			gpuErrorcheck(cudaMemcpy(pr1, d_pr1, num_nodes * sizeof(float), cudaMemcpyDeviceToHost));
			gpuErrorcheck(cudaMemcpy(pr2, d_pr2, num_nodes * sizeof(float), cudaMemcpyDeviceToHost));
			gpuErrorcheck(cudaDeviceSynchronize());
			for (size_t i = 0; i < num_nodes; i++)
			{
				prd[i] = abs(pr1[i] - pr2[i]);
			}

			float err = *std::max_element(prd, prd + num_nodes);
			if (err  < DELTA )
			{
				finished = true;
			}

			clearLabel<<<num_nodes / 512 + 1, 512>>>(d_pr1, d_pr2, num_nodes, base);
		}
		else
		{
			kernel<<<vGraph.numParts / 512 + 1, 512>>>(vGraph.numParts,
													   d_nodePointer,
													   d_partNodePointer,
													   d_edgeList,
													   d_pr2,
													   d_pr1);
			gpuErrorcheck(cudaMemcpy(pr1, d_pr1, num_nodes * sizeof(float), cudaMemcpyDeviceToHost));
			gpuErrorcheck(cudaMemcpy(pr2, d_pr2, num_nodes * sizeof(float), cudaMemcpyDeviceToHost));
			gpuErrorcheck(cudaDeviceSynchronize());
			for (size_t i = 0; i < num_nodes; i++)
			{
				prd[i] = abs(pr1[i] - pr2[i]);
			}

			float err = *std::max_element(prd, prd + num_nodes);
			if (err  < DELTA )
			{
				finished = true;
				cout << " pr convergence" << endl;
			}
			clearLabel<<<num_nodes / 512 + 1, 512>>>(d_pr2, d_pr1, num_nodes, base);
		}
		if (finished)
		{
			break;
		}

		gpuErrorcheck(cudaPeekAtLastError());
		gpuErrorcheck(cudaDeviceSynchronize());

	} while (itr < arguments.numberOfItrs);

	cudaDeviceSynchronize();

	cout << "Number of iterations = " << itr << endl;

	float runtime = t.Finish();
	cout << "Processing finished in " << runtime << " (ms).\n";
	cout << "Total time in " << t3.Finish() << " (ms).\n";

	if (itr % 2 == 1)
	{
		gpuErrorcheck(cudaMemcpy(pr1, d_pr1, num_nodes * sizeof(float), cudaMemcpyDeviceToHost));
	}
	else
	{
		gpuErrorcheck(cudaMemcpy(pr1, d_pr2, num_nodes * sizeof(float), cudaMemcpyDeviceToHost));
	}

	utilities::PrintResults(pr1, 30);

	//float sum = 0;
	//for(int i=0; i<num_nodes; i++)
	//	sum = sum + pr1[i];
	//cout << sum << endl << endl;

	if (arguments.hasOutput)
		utilities::SaveResults(arguments.output, pr1, num_nodes);

	gpuErrorcheck(cudaFree(d_nodePointer));
	gpuErrorcheck(cudaFree(d_edgeList));
	gpuErrorcheck(cudaFree(d_pr1));
	gpuErrorcheck(cudaFree(d_pr2));
	gpuErrorcheck(cudaFree(d_partNodePointer));
}
