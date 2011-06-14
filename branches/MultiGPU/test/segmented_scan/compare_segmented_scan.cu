/******************************************************************************
 * 
 * Copyright 2010-2011 Duane Merrill
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 * 
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License. 
 * 
 * For more information, see our Google Code project site: 
 * http://code.google.com/p/back40computing/
 * 
 ******************************************************************************/


/******************************************************************************
 * Simple test driver program for segmented scan.
 ******************************************************************************/

#include <stdio.h> 

// Test utils
#include "b40c_test_util.h"
#include "test_segmented_scan.h"

#include <thrust/device_vector.h>
#include <thrust/scan.h>
#include <thrust/iterator/zip_iterator.h>
#include <thrust/tuple.h>
#include <thrust/functional.h>

using namespace b40c;


/******************************************************************************
 * Defines, constants, globals 
 ******************************************************************************/

bool 	g_verbose 						= false;
int 	g_max_ctas 						= 0;
int 	g_iterations  					= 1;
bool 	g_inclusive						= false;


/******************************************************************************
 * Utility Routines
 ******************************************************************************/

/**
 * Displays the commandline usage for this tool
 */
void Usage() 
{
	printf("\ncompare_segmented_scan [--device=<device index>] [--v] [--i=<num-iterations>] "
			"[--max-ctas=<max-thread-blocks>] [--n=<num-elements>] [--inclusive]\n");
	printf("\n");
	printf("\t--v\tDisplays copied results to the console.\n");
	printf("\n");
	printf("\t--i\tPerforms the segmented scan operation <num-iterations> times\n");
	printf("\t\t\ton the device. Re-copies original input each time. Default = 1\n");
	printf("\n");
	printf("\t--n\tThe number of elements to comprise the sample problem\n");
	printf("\t\t\tDefault = 512\n");
	printf("\n");
}


template <typename OutputType, typename HeadFlagType, typename AssociativeOperator>
struct segmented_scan_functor
{
    AssociativeOperator binary_op;

    typedef typename thrust::tuple<OutputType, HeadFlagType> result_type;

    __host__ __device__
    segmented_scan_functor(AssociativeOperator _binary_op) : binary_op(_binary_op) {}

    __host__ __device__
    result_type operator()(result_type a, result_type b)
    {
        return result_type(thrust::get<1>(b) ? thrust::get<0>(b) : binary_op(thrust::get<0>(a), thrust::get<0>(b)),
                           thrust::get<1>(a) | thrust::get<1>(b));
    }
};


/**
 * Timed segmented scan.  Uses the GPU to copy the specified vector of elements for the given
 * number of iterations, displaying runtime information.
 */
template <
	typename T,
	typename Flag,
	bool EXCLUSIVE,
	T BinaryOp(const T&, const T&),
	T Identity()>
double TimedThrustSegmentedScan(
	T *h_data,
	Flag *h_flag_data,
	T *h_reference,
	size_t num_elements)
{
	// Allocate device storage  
	T *d_src, *d_dest;
	Flag *d_flag_src;
	if (util::B40CPerror(cudaMalloc((void**) &d_src, sizeof(T) * num_elements),
		"TimedSegmentedScan cudaMalloc d_src failed: ", __FILE__, __LINE__)) exit(1);
	if (util::B40CPerror(cudaMalloc((void**) &d_dest, sizeof(T) * num_elements),
		"TimedSegmentedScan cudaMalloc d_dest failed: ", __FILE__, __LINE__)) exit(1);
	if (util::B40CPerror(cudaMalloc((void**) &d_flag_src, sizeof(Flag) * num_elements),
		"TimedSegmentedScan cudaMalloc d_dest failed: ", __FILE__, __LINE__)) exit(1);

	// Move a fresh copy of the problem into device storage
	if (util::B40CPerror(cudaMemcpy(d_src, h_data, sizeof(T) * num_elements, cudaMemcpyHostToDevice),
		"TimedSegmentedScan cudaMemcpy d_src failed: ", __FILE__, __LINE__)) exit(1);
	if (util::B40CPerror(cudaMemcpy(d_flag_src, h_flag_data, sizeof(Flag) * num_elements, cudaMemcpyHostToDevice),
		"TimedSegmentedScan cudaMemcpy d_src failed: ", __FILE__, __LINE__)) exit(1);
	
	// Perform a single iteration to allocate any memory if needed, prime code caches, etc.
	thrust::device_ptr<T> dev_src(d_src);
	thrust::device_ptr<T> dev_dest(d_dest);
	thrust::device_ptr<Flag> dev_flag_src(d_flag_src);
	if (EXCLUSIVE) {

		// shift input one to the right and initialize segments with init
		thrust::detail::raw_buffer<T, thrust::device_space_tag> temp(num_elements);
		thrust::replace_copy_if(
			dev_src,
			dev_src + num_elements - 1,
			dev_flag_src + 1, temp.begin() + 1, thrust::negate<Flag>(), Identity());
		temp[0] = Identity();

		thrust::detail::device::inclusive_scan(thrust::make_zip_iterator(thrust::make_tuple(temp.begin(), dev_flag_src)),
											   thrust::make_zip_iterator(thrust::make_tuple(temp.begin(), dev_flag_src)) + num_elements,
											   thrust::make_zip_iterator(thrust::make_tuple(dev_dest,     dev_flag_src)),
								               segmented_scan_functor<T, Flag, thrust::plus<T> >(thrust::plus<T>()));

	} else {

		thrust::detail::device::inclusive_scan
            (thrust::make_zip_iterator(thrust::make_tuple(dev_src, dev_flag_src)),
             thrust::make_zip_iterator(thrust::make_tuple(dev_src, dev_flag_src)) + num_elements,
             thrust::make_zip_iterator(thrust::make_tuple(dev_dest, dev_flag_src)),
             segmented_scan_functor<T, Flag, thrust::plus<T> >(thrust::plus<T>()));
	}
	
	// Perform the timed number of iterations

	cudaEvent_t start_event, stop_event;
	cudaEventCreate(&start_event);
	cudaEventCreate(&stop_event);

	double elapsed = 0;
	float duration = 0;
	for (int i = 0; i < g_iterations; i++) {

		// Move a fresh copy of flags into device storage because we destroyed it last time :(
		if (util::B40CPerror(cudaMemcpy(d_flag_src, h_flag_data, sizeof(Flag) * num_elements, cudaMemcpyHostToDevice),
			"TimedSegmentedScan cudaMemcpy d_src failed: ", __FILE__, __LINE__)) exit(1);

		// Start timing record
		cudaEventRecord(start_event, 0);

		if (EXCLUSIVE) {

			// shift input one to the right and initialize segments with init
			thrust::detail::raw_buffer<T, thrust::device_space_tag> temp(num_elements);
			thrust::replace_copy_if(
				dev_src,
				dev_src + num_elements - 1,
				dev_flag_src + 1, temp.begin() + 1, thrust::negate<Flag>(), Identity());
			temp[0] = Identity();

			thrust::detail::device::inclusive_scan(thrust::make_zip_iterator(thrust::make_tuple(temp.begin(), dev_flag_src)),
												   thrust::make_zip_iterator(thrust::make_tuple(temp.begin(), dev_flag_src)) + num_elements,
												   thrust::make_zip_iterator(thrust::make_tuple(dev_dest,     dev_flag_src)),
									               segmented_scan_functor<T, Flag, thrust::plus<T> >(thrust::plus<T>()));

		} else {

			thrust::detail::device::inclusive_scan
	            (thrust::make_zip_iterator(thrust::make_tuple(dev_src, dev_flag_src)),
	             thrust::make_zip_iterator(thrust::make_tuple(dev_src, dev_flag_src)) + num_elements,
	             thrust::make_zip_iterator(thrust::make_tuple(dev_dest, dev_flag_src)),
	             segmented_scan_functor<T, Flag, thrust::plus<T> >(thrust::plus<T>()));
		}
		
		// End timing record
		cudaEventRecord(stop_event, 0);
		cudaEventSynchronize(stop_event);
		cudaEventElapsedTime(&duration, start_event, stop_event);
		elapsed += (double) duration;		
	}

	// Display timing information
	double avg_runtime = elapsed / g_iterations;
	double throughput = ((double) num_elements) / avg_runtime / 1000.0 / 1000.0;
	printf("\nThrust SegmentedScan: %d iterations, %lu elements, ", g_iterations, (unsigned long) num_elements);
    printf("%f GPU ms, %f x10^9 elts/sec",
		avg_runtime, throughput);
	
    // Clean up events
	cudaEventDestroy(start_event);
	cudaEventDestroy(stop_event);

    // Copy out data
	T *h_dest = (T*) malloc(num_elements * sizeof(T));
    if (util::B40CPerror(cudaMemcpy(h_dest, d_dest, sizeof(T) * num_elements, cudaMemcpyDeviceToHost),
		"TimedSegmentedScan cudaMemcpy d_dest failed: ", __FILE__, __LINE__)) exit(1);

    // Free allocated memory
    if (d_src) cudaFree(d_src);
    if (d_dest) cudaFree(d_dest);
    if (d_flag_src) cudaFree(d_flag_src);

	// Flushes any stdio from the GPU
	cudaThreadSynchronize();

	// Display copied data
	if (g_verbose) {
		printf("\n\nData:\n");
		for (int i = 0; i < num_elements; i++) {
			PrintValue<T>(h_dest[i]);
			printf(", ");
		}
		printf("\n\n");
	}

    // Verify solution
	CompareResults(h_dest, h_reference, num_elements, true);
	printf("\n");
	fflush(stdout);

	if (h_dest) free(h_dest);

	return throughput;
}



/**
 * Creates an example segmented scan problem and then dispatches the problem
 * to the GPU for the given number of iterations, displaying runtime information.
 */
template<
	typename T,
	typename Flag,
	bool EXCLUSIVE,
	T BinaryOp(const T&, const T&),
	T Identity()>
void TestSegmentedScan(size_t num_elements)
{
    // Allocate the segmented scan problem on the host and fill the keys with random bytes

	T *h_data 			= (T*) malloc(num_elements * sizeof(T));
	T *h_reference 		= (T*) malloc(num_elements * sizeof(T));
	Flag *h_flag_data	= (Flag*) malloc(num_elements * sizeof(Flag));

	if ((h_data == NULL) || (h_reference == NULL) || (h_flag_data == NULL)){
		fprintf(stderr, "Host malloc of problem data failed\n");
		exit(1);
	}

	for (size_t i = 0; i < num_elements; ++i) {
//		util::RandomBits<T>(h_data[i], 0);
//		util::RandomBits<Flag>(h_flag_data[i], 0);
		h_data[i] = 1;
		h_flag_data[i] = (i % 11) == 0;
	}

	for (size_t i = 0; i < num_elements; ++i) {
		if (EXCLUSIVE)
		{
			h_reference[i] = ((i == 0) || (h_flag_data[i])) ?
				Identity() :
				BinaryOp(h_reference[i - 1], h_data[i - 1]);
		} else {
			h_reference[i] = ((i == 0) || (h_flag_data[i])) ?
				h_data[i] :
				BinaryOp(h_reference[i - 1], h_data[i]);
		}
	}

	//
    // Run the timing test(s)
	//

	double b40c = TimedSegmentedScan<T, Flag, EXCLUSIVE, BinaryOp, Identity, segmented_scan::UNKNOWN>(
		h_data, h_flag_data, h_reference, num_elements, g_max_ctas, g_verbose, g_iterations);
	double thrust = TimedThrustSegmentedScan<T, Flag, EXCLUSIVE, BinaryOp, Identity>(
		h_data, h_flag_data, h_reference, num_elements);
	printf("B40C speedup: %.2f\n", b40c/thrust);
	

	// Free our allocated host memory 
	if (h_data) free(h_data);
    if (h_reference) free(h_reference);
}


/**
 * Creates an example segmented scan problem and then dispatches the problem
 * to the GPU for the given number of iterations, displaying runtime information.
 */
template<
	typename T,
	typename Flag,
	T BinaryOp(const T&, const T&),
	T Identity()>
void TestSegmentedScanVariety(size_t num_elements)
{
	if (g_inclusive) {
		TestSegmentedScan<T, Flag, false, BinaryOp, Identity>(num_elements);
	} else {
		TestSegmentedScan<T, Flag, true, BinaryOp, Identity>(num_elements);
	}
}


/******************************************************************************
 * Main
 ******************************************************************************/

int main(int argc, char** argv)
{

	CommandLineArgs args(argc, argv);
	DeviceInit(args);

	//srand(time(NULL));	
	srand(0);				// presently deterministic

    //
	// Check command line arguments
    //

	size_t num_elements = 1024;

    if (args.CheckCmdLineFlag("help")) {
		Usage();
		return 0;
	}

    g_inclusive = args.CheckCmdLineFlag("inclusive");
    args.GetCmdLineArgument("i", g_iterations);
    args.GetCmdLineArgument("n", num_elements);
    args.GetCmdLineArgument("max-ctas", g_max_ctas);
	g_verbose = args.CheckCmdLineFlag("v");

	typedef unsigned char Flag;

	// Execute test(s)
	{
		printf("\n-- UNSIGNED CHAR ----------------------------------------------\n");
		typedef unsigned char T;
		typedef Sum<T> BinaryOp;
		TestSegmentedScanVariety<T, Flag, BinaryOp::Op, BinaryOp::Identity>(num_elements * 4);
	}
	{
		printf("\n-- UNSIGNED SHORT ----------------------------------------------\n");
		typedef unsigned short T;
		typedef Sum<T> BinaryOp;
		TestSegmentedScanVariety<T, Flag, BinaryOp::Op, BinaryOp::Identity>(num_elements * 2);
	}
	{
		printf("\n-- UNSIGNED INT -----------------------------------------------\n");
		typedef unsigned int T;
		typedef Sum<T> BinaryOp;
		TestSegmentedScanVariety<T, Flag, BinaryOp::Op, BinaryOp::Identity>(num_elements);
	}
	{
		printf("\n-- UNSIGNED LONG LONG -----------------------------------------\n");
		typedef unsigned long long T;
		typedef Sum<T> BinaryOp;
		TestSegmentedScanVariety<T, Flag, BinaryOp::Op, BinaryOp::Identity>(num_elements / 2);
	}

	return 0;
}


