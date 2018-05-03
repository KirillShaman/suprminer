/**
* echo512-80 cuda kernel for X16R algorithm
*
* tpruvot 2018 - GPL code
* sp 2018 (30% faster)
*/

#include "cuda_helper_alexis.h"

#define AESx(x) (x ##UL) /* SPH_C32(x) */

extern __device__ __device_builtin__ void __threadfence_block(void);

#define xor4_32(a,b,c,d) ((a ^ b) ^ (c ^ d));


#include "x11/cuda_x11_aes_alexis.cuh"

__device__
static void echo_round(const uint32_t sharedMemory[4][256], uint32_t *W, uint32_t &k0){
	// Big Sub Words
#pragma unroll 16
	for (int idx = 0; idx < 16; idx++)
		AES_2ROUND(sharedMemory, W[(idx << 2) + 0], W[(idx << 2) + 1], W[(idx << 2) + 2], W[(idx << 2) + 3], k0);

	// Shift Rows
#pragma unroll 4
	for (int i = 0; i < 4; i++){
		uint32_t t[4];
		/// 1, 5, 9, 13
		t[0] = W[i + 4];
		t[1] = W[i + 8];
		t[2] = W[i + 24];
		t[3] = W[i + 60];
		W[i + 4] = W[i + 20];
		W[i + 8] = W[i + 40];
		W[i + 24] = W[i + 56];
		W[i + 60] = W[i + 44];

		W[i + 20] = W[i + 36];
		W[i + 40] = t[1];
		W[i + 56] = t[2];
		W[i + 44] = W[i + 28];

		W[i + 28] = W[i + 12];
		W[i + 12] = t[3];
		W[i + 36] = W[i + 52];
		W[i + 52] = t[0];
	}
	// Mix Columns
#pragma unroll 4
	for (int i = 0; i < 4; i++){ // Schleife �ber je 2*uint32_t
#pragma unroll 4
		for (int idx = 0; idx < 64; idx += 16){ // Schleife �ber die elemnte
			uint32_t a[4];
			a[0] = W[idx + i];
			a[1] = W[idx + i + 4];
			a[2] = W[idx + i + 8];
			a[3] = W[idx + i + 12];

			uint32_t ab = a[0] ^ a[1];
			uint32_t bc = a[1] ^ a[2];
			uint32_t cd = a[2] ^ a[3];

			uint32_t t, t2, t3;
			t = (ab & 0x80808080);
			t2 = (bc & 0x80808080);
			t3 = (cd & 0x80808080);

			uint32_t abx = (t >> 7) * 27U ^ ((ab^t) << 1);
			uint32_t bcx = (t2 >> 7) * 27U ^ ((bc^t2) << 1);
			uint32_t cdx = (t3 >> 7) * 27U ^ ((cd^t3) << 1);

			W[idx + i] = bc ^ a[3] ^ abx;
			W[idx + i + 4] = a[0] ^ cd ^ bcx;
			W[idx + i + 8] = ab ^ a[3] ^ cdx;
			W[idx + i + 12] = ab ^ a[2] ^ (abx ^ bcx ^ cdx);
		}
	}
}


__device__ __forceinline__
void cuda_echo_round_80(const uint32_t sharedMemory[4][256], uint32_t *const __restrict__ data, const uint32_t nonce, uint32_t *hash)
{
	uint32_t h[29]; // <= 127 bytes input

#pragma unroll 8
	for (int i = 0; i < 18; i += 2)
		AS_UINT2(&h[i]) = AS_UINT2(&data[i]);
	h[18] = data[18];
	h[19] = cuda_swab32(nonce);
	h[20] = 0x80;
	h[21] = h[22] = h[23] = h[24] = h[25] = h[26] = 0;
	h[27] = 0x2000000;
	h[28] = 0x280;

	uint32_t k0 = 640; // bitlen
	uint32_t W[64];

#pragma unroll 8
	for (int i = 0; i < 32; i += 4) {
		W[i] = 512; // L
		W[i + 1] = 0; // H
		W[i + 2] = 0; // X
		W[i + 3] = 0;
	}

	uint32_t Z[16];
#pragma unroll
	for (int i = 0; i<16; i++) Z[i] = W[i];
#pragma unroll
	for (int i = 32; i<61; i++) W[i] = h[i - 32];
#pragma unroll
	for (int i = 61; i<64; i++) W[i] = 0;

	//	#pragma unroll 2
	for (int i = 0; i < 10; i++)
		echo_round(sharedMemory, W, k0);

#pragma unroll 16
	for (int i = 0; i < 16; i++) {
		Z[i] ^= h[i] ^ W[i] ^ W[i + 32];
	}

#pragma unroll 8
	for (int i = 0; i < 16; i += 2)
		AS_UINT2(&hash[i]) = AS_UINT2(&Z[i]);
}

__host__
void x16_echo512_cuda_init(int thr_id, const uint32_t threads)
{
	//	aes_cpu_init(thr_id);
}

__constant__ static uint32_t c_PaddedMessage80[20];

__host__
void x16_echo512_setBlock_80(void *endiandata)
{
	cudaMemcpyToSymbol(c_PaddedMessage80, endiandata, sizeof(c_PaddedMessage80), 0, cudaMemcpyHostToDevice);
}

__global__ __launch_bounds__(128, 5) /* will force 72 registers */
void x16_echo512_gpu_hash_80(uint32_t threads, uint32_t startNonce, uint64_t *g_hash)
{
	//__shared__ uint32_t sharedMemory[1024];
	__shared__ uint32_t sharedMemory[4][256];

	aes_gpu_init128(sharedMemory);
	//	echo_gpu_init(sharedMemory);
	//	__threadfence_block();

	const uint32_t thread = (blockDim.x * blockIdx.x + threadIdx.x);
	if (thread < threads)
	{
		uint64_t hashPosition = thread;
		uint32_t *pHash = (uint32_t*)&g_hash[hashPosition << 3];

		cuda_echo_round_80(sharedMemory, c_PaddedMessage80, startNonce + thread, pHash);
	}
}

__host__
void x16_echo512_cuda_hash_80(int thr_id, const uint32_t threads, const uint32_t startNonce, uint32_t *d_hash)
{
	const uint32_t threadsperblock = 128;

	dim3 grid((threads + threadsperblock - 1) / threadsperblock);
	dim3 block(threadsperblock);

	x16_echo512_gpu_hash_80 << <grid, block >> >(threads, startNonce, (uint64_t*)d_hash);
}
