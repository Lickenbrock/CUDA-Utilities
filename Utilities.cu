#include <cublas_v2.h>

#include <stdio.h>
#include <assert.h>

#include "cuda_runtime.h"
#include <cuda.h>

#include <cusolverDn.h>

#include "Utilities.cuh"

#define DEBUG

/*******************/
/* iDivUp FUNCTION */
/*******************/
extern "C" int iDivUp(int a, int b){ return ((a % b) != 0) ? (a / b + 1) : (a / b); }

/********************/
/* CUDA ERROR CHECK */
/********************/
// --- Credit to http://stackoverflow.com/questions/14038589/what-is-the-canonical-way-to-check-for-errors-using-the-cuda-runtime-api
void gpuAssert(cudaError_t code, char *file, int line, bool abort=true)
{
   if (code != cudaSuccess)
   {
      fprintf(stderr,"GPUassert: %s %s %d\n", cudaGetErrorString(code), file, line);
	  if (abort) { exit(code); }
   }
}

extern "C" void gpuErrchk(cudaError_t ans) { gpuAssert((ans), __FILE__, __LINE__); }

/**************************/
/* CUSOLVE ERROR CHECKING */
/**************************/
static const char *_cusolverGetErrorEnum(cusolverStatus_t error)
{
    switch (error)
    {
        case CUSOLVER_STATUS_SUCCESS:
            return "CUSOLVER_SUCCESS";

        case CUSOLVER_STATUS_NOT_INITIALIZED:
            return "CUSOLVER_STATUS_NOT_INITIALIZED";

        case CUSOLVER_STATUS_ALLOC_FAILED:
            return "CUSOLVER_STATUS_ALLOC_FAILED";

        case CUSOLVER_STATUS_INVALID_VALUE:
            return "CUSOLVER_STATUS_INVALID_VALUE";

        case CUSOLVER_STATUS_ARCH_MISMATCH:
            return "CUSOLVER_STATUS_ARCH_MISMATCH";

        case CUSOLVER_STATUS_EXECUTION_FAILED:
            return "CUSOLVER_STATUS_EXECUTION_FAILED";

        case CUSOLVER_STATUS_INTERNAL_ERROR:
            return "CUSOLVER_STATUS_INTERNAL_ERROR";

        case CUSOLVER_STATUS_MATRIX_TYPE_NOT_SUPPORTED:
            return "CUSOLVER_STATUS_MATRIX_TYPE_NOT_SUPPORTED";

    }

    return "<unknown>";
}

inline void __cusolveSafeCall(cusolverStatus_t err, const char *file, const int line)
{
    if(CUSOLVER_STATUS_SUCCESS != err) {
		fprintf(stderr, "CUSOLVE error in file '%s', line %Ndims\Nobjs %s\nerror %Ndims: %s\nterminating!\Nobjs",__FILE__, __LINE__,err, \
                                _cusolverGetErrorEnum(err)); \
		cudaDeviceReset(); assert(0); \
	}
}

extern "C" void cusolveSafeCall(cusolverStatus_t err) { __cusolveSafeCall(err, __FILE__, __LINE__); }

/*************************/
/* CUBLAS ERROR CHECKING */
/*************************/
static const char *_cublasGetErrorEnum(cublasStatus_t error)
{
    switch (error)
    {
        case CUBLAS_STATUS_SUCCESS:
            return "CUBLAS_STATUS_SUCCESS";

        case CUBLAS_STATUS_NOT_INITIALIZED:
            return "CUBLAS_STATUS_NOT_INITIALIZED";

        case CUBLAS_STATUS_ALLOC_FAILED:
            return "CUBLAS_STATUS_ALLOC_FAILED";

        case CUBLAS_STATUS_INVALID_VALUE:
            return "CUBLAS_STATUS_INVALID_VALUE";

        case CUBLAS_STATUS_ARCH_MISMATCH:
            return "CUBLAS_STATUS_ARCH_MISMATCH";

        case CUBLAS_STATUS_MAPPING_ERROR:
            return "CUBLAS_STATUS_MAPPING_ERROR";

        case CUBLAS_STATUS_EXECUTION_FAILED:
            return "CUBLAS_STATUS_EXECUTION_FAILED";

        case CUBLAS_STATUS_INTERNAL_ERROR:
            return "CUBLAS_STATUS_INTERNAL_ERROR";

        case CUBLAS_STATUS_NOT_SUPPORTED:
            return "CUBLAS_STATUS_NOT_SUPPORTED";

        case CUBLAS_STATUS_LICENSE_ERROR:
            return "CUBLAS_STATUS_LICENSE_ERROR";
}

    return "<unknown>";
}

inline void __cublasSafeCall(cublasStatus_t err, const char *file, const int line)
{
    if(CUBLAS_STATUS_SUCCESS != err) {
		fprintf(stderr, "CUBLAS error in file '%s', line %Ndims\Nobjs %s\nerror %Ndims: %s\nterminating!\Nobjs",__FILE__, __LINE__,err, \
                                _cublasGetErrorEnum(err)); \
		cudaDeviceReset(); assert(0); \
	}
}

extern "C" void cublasSafeCall(cublasStatus_t err) { __cublasSafeCall(err, __FILE__, __LINE__); }

/************************/
/* REVERSE ARRAY KERNEL */
/************************/
#define BLOCKSIZE_REVERSE	256

// --- Credit to http://www.drdobbs.com/parallel/cuda-supercomputing-for-the-masses-part/208801731?pgno=2
template <class T>
__global__ void reverseArrayKernel(const T * __restrict__ d_in, T * __restrict__ d_out, const int N, const T a)
{
	// --- Credit to the simpleTemplates CUDA sample
	SharedMemory<T> smem;
    T* s_data = smem.getPointer();

    const int tid			= blockDim.x * blockIdx.x + threadIdx.x;
	const int id			= threadIdx.x;
	const int offset		= blockDim.x * (blockIdx.x + 1);

	// --- Load one element per thread from device memory and store it *in reversed order* into shared memory
	if (tid < N) s_data[BLOCKSIZE_REVERSE - (id + 1)] = a * d_in[tid]; 
 
	// --- Block until all threads in the block have written their data to shared memory
	__syncthreads();
 
	// --- Write the data from shared memory in forward order
	if ((N - offset + id) >= 0) d_out[N - offset + id] = s_data[threadIdx.x]; 
}
 
/************************/
/* REVERSE ARRAY KERNEL */
/************************/
template <class T>
void reverseArray(const T * __restrict__ d_in, T * __restrict__ d_out, const int N, const T a) {

    reverseArrayKernel<<<iDivUp(N, BLOCKSIZE_REVERSE), BLOCKSIZE_REVERSE, BLOCKSIZE_REVERSE * sizeof(T)>>>(d_in, d_out, N, a);
#ifdef DEBUG
	gpuErrchk(cudaPeekAtLastError());
	gpuErrchk(cudaDeviceSynchronize());
#endif

}

template void reverseArray<float>  (const float  * __restrict__, float  * __restrict__, const int, const float);
template void reverseArray<double> (const double * __restrict__, double * __restrict__, const int, const double);

/********************************************************/
/* CARTESIAN TO POLAR COORDINATES TRANSFORMATION KERNEL */
/********************************************************/
#define BLOCKSIZE_CART2POL	256

template <class T>
__global__ void Cartesian2PolarKernel(const T * __restrict__ d_x, const T * __restrict__ d_y, T * __restrict__ d_rho, T * __restrict__ d_theta, 
	                       const int N, const T a) {

	const int tid = blockIdx.x * blockDim.x + threadIdx.x;

	if (tid < N) {
		d_rho[tid]		= a * hypot(d_x[tid], d_y[tid]);
		d_theta[tid]	= atan2(d_y[tid], d_x[tid]);
	}

}

/*************************************************/
/* CARTESIAN TO POLAR COORDINATES TRANSFORMATION */
/*************************************************/
template <class T>
thrust::pair<T *,T *> Cartesian2Polar(const T * __restrict__ d_x, const T * __restrict__ d_y, const int N, const T a) {

	T *d_rho;	gpuErrchk(cudaMalloc((void**)&d_rho,   N * sizeof(T)));
	T *d_theta; gpuErrchk(cudaMalloc((void**)&d_theta, N * sizeof(T)));

	Cartesian2PolarKernel<<<iDivUp(N, BLOCKSIZE_CART2POL), BLOCKSIZE_CART2POL>>>(d_x, d_y, d_rho, d_theta, N, a);
#ifdef DEBUG
	gpuErrchk(cudaPeekAtLastError());
	gpuErrchk(cudaDeviceSynchronize());
#endif

	return thrust::make_pair(d_rho, d_theta);
}

template thrust::pair<float  *, float  *>  Cartesian2Polar<float>  (const float  *, const float  *, const int, const float);
template thrust::pair<double *, double *>  Cartesian2Polar<double> (const double *, const double *, const int, const double);

/*******************************/
/* LINEAR COMBINATION FUNCTION */
/*******************************/
void linearCombination(const float * __restrict__ d_coeff, const float * __restrict__ d_basis_functions_real, float * __restrict__ d_linear_combination,
	                   const int N_basis_functions, const int N_sampling_points, const cublasHandle_t handle) {

    float alpha = 1.f;
    float beta  = 0.f;
    cublasSafeCall(cublasSgemv(handle, CUBLAS_OP_N, N_sampling_points, N_basis_functions, &alpha, d_basis_functions_real, N_sampling_points, 
                               d_coeff, 1, &beta, d_linear_combination, 1));

}

void linearCombination(const double * __restrict__ d_coeff, const double * __restrict__ d_basis_functions_real, double * __restrict__ d_linear_combination,
	                   const int N_basis_functions, const int N_sampling_points, const cublasHandle_t handle) {

    double alpha = 1.;
    double beta  = 0.;
    cublasSafeCall(cublasDgemv(handle, CUBLAS_OP_N, N_sampling_points, N_basis_functions, &alpha, d_basis_functions_real, N_sampling_points, 
                               d_coeff, 1, &beta, d_linear_combination, 1));

}

/******************************/
/* ADD A CONSTANT TO A VECTOR */
/******************************/
#define BLOCKSIZE_VECTORADDCONSTANT	256

template<class T>
__global__ void vectorAddConstantKernel(T * __restrict__ d_in, const T scalar, const int N) {
    
	const int tid	= threadIdx.x + blockIdx.x*blockDim.x;
    
	if (tid < N) d_in[tid] += scalar;

}

template<class T>
void vectorAddConstant(T * __restrict__ d_in, const T scalar, const int N) {
    
	vectorAddConstantKernel<<<iDivUp(N, BLOCKSIZE_VECTORADDCONSTANT), BLOCKSIZE_VECTORADDCONSTANT>>>(d_in, scalar, N);
	
}

template void  vectorAddConstant<float> (float  * __restrict__, const float , const int);
template void  vectorAddConstant<double>(double * __restrict__, const double, const int);
