#include <cuda.h>
#include <cuda_runtime.h>
#include <cassert>
#include <c10/cuda/CUDAGuard.h>

#include <torch/extension.h>

// error handler
// from https://leimao.github.io/blog/Proper-CUDA-Error-Checking

#define CHECK_LAST_CUDA_ERROR() check(__FILE__, __LINE__)
void check(const char* file, const int line)
{
    cudaError_t err = cudaGetLastError();

    if (err != cudaSuccess) {
        std::cerr << "CUDA Error at: " << file << ":" << line << std::endl;
        std::cerr << cudaGetErrorString(err) << std::endl;
    }
}

#define ACCESSOR(x, n, type) x.packed_accessor32<type, n, torch::RestrictPtrTraits>()

#ifdef __CUDA_ARCH__
#if __CUDA_ARCH__ < 800
__device__ __forceinline__ void atomicAdd(c10::Half* address, c10::Half val) {
    unsigned int *address_as_ui = reinterpret_cast<unsigned int *>(reinterpret_cast<char *>(address) - (reinterpret_cast<size_t>(address) & 2));
    unsigned int old = *address_as_ui;
    unsigned int assumed;

    do {
        assumed = old;
        unsigned short hsum = reinterpret_cast<size_t>(address) & 2 ? (old >> 16) : (old & 0xffff);
        hsum += val;
        old = reinterpret_cast<size_t>(address) & 2
                 ? (old & 0xffff) | (hsum << 16)
                 : (old & 0xffff0000) | hsum;
        old = atomicCAS(address_as_ui, assumed, old);

    } while (assumed != old);
}
#endif
#endif

// type alias

template <typename scalar_t, int dims>
using PackedAccessor = torch::PackedTensorAccessor32<scalar_t, dims, torch::RestrictPtrTraits>;

// helper functions

__host__ __device__ int cdiv(int numer, int denom) {
    return (numer + denom - 1) / denom;
}

__host__ __device__ int next_multiple_of(int num, int multiple_of) {
    return cdiv(num, multiple_of) * multiple_of;
}

__host__ __device__ int next_pow_2(int n) {
    int i = 1;
    while(i < n)
        i *= 2;
    return i;
}

bool divisible_by(int num, int denom) {
    return (num % denom) == 0;
}

// constants

__constant__ float NULL_FLOAT_VALUE = -3.14159e5;

// mma

template<typename scalar_t, int tmpl_N_thread, int tmpl_M_thread>
struct mma_warp_tile {
    static constexpr int N_thread = tmpl_N_thread;
    static constexpr int M_thread = tmpl_M_thread;

    // Thread layout within a warp:
    static constexpr int N_warp = 8;
    static constexpr int M_warp = 4;
    static_assert(N_warp * M_warp == 32);

    // Warp layout within a block:
    static constexpr int N_block = 2;
    static constexpr int M_block = 4;
    static_assert(N_block * M_block * N_warp * M_warp == 256); // blockDim.x

    // Dimensions of the tile, in threads:
    static constexpr int N_tile = N_warp * N_block * N_thread;
    static constexpr int M_tile = M_warp * M_block * M_thread;

    static constexpr float MASK_VALUE = -1e8;

    // Registers:
    float A_frag[N_thread];            // N x 1 fragment
    float B_frag[M_thread];            // 1 x M fragment
    float C_frag[N_thread * M_thread]; // N x M fragment


    int warp_x;   // x offset of the warp within the block tile
    int warp_y;   // y offset of the warp within the block tile
    int thread_x; // x offset of the thread within the warp tile
    int thread_y; // y offset of the thread within the warp tile

    __device__ mma_warp_tile() {
        int warp_id = threadIdx.x / 32;
        warp_x = (warp_id % M_block);
        warp_y = (warp_id / M_block);

        int lane_id = threadIdx.x % 32;
        thread_x = warp_x * M_warp * M_thread + lane_id % M_warp;
        thread_y = warp_y * N_warp * N_thread + lane_id / M_warp;
    }

    // Initialize C to all zeros

    __device__ void zero() {
        for (int i = 0; i < N_thread * M_thread; i++) {
            C_frag[i] = 0.f;
        }
    }

    // Performs C = A * B + C

    __device__ void mma(
        const scalar_t* A_sm_ptr,
        const scalar_t* B_sm_ptr,
        int k,
        bool has_mask
    ) {
        // Load a N x 1 fragment of A from shared memory to registers:
        #pragma unroll
        for (int i = 0; i < N_thread; i++) {
            A_frag[i] = A_sm_ptr[i * N_warp + thread_y + k * N_tile];
        }

        // Load a 1 x M fragment of B from shared memory to registers:
        #pragma unroll
        for (int i = 0; i < M_thread; i++) {
            B_frag[i] = B_sm_ptr[i * M_warp + thread_x + k * M_tile];
        }

        // Compute:
        #pragma unroll
        for (int j = 0; j < M_thread ; j++) {

            bool is_masked_out = has_mask && (B_sm_ptr[j * M_warp + thread_x] == NULL_FLOAT_VALUE);

            #pragma unroll
            for (int i = 0; i < N_thread; i++) {
                if (is_masked_out) {
                    C_frag[i * M_thread + j] = MASK_VALUE;
                } else {
                    C_frag[i * M_thread + j] += A_frag[i] * B_frag[j];
                }
            }
        }
    }

    // Performs C = transpose(A) * B + C

    __device__ void mma_transpose_a(
        const scalar_t* A_sm_ptr,
        const scalar_t* B_sm_ptr,
        int k,
        bool has_mask
    ) {
        // Load a N x 1 fragment of transpose(A) from shared memory to registers:
        #pragma unroll
        for (int i = 0; i < N_thread; i++) {
            A_frag[i] = A_sm_ptr[(i * N_warp + thread_y) * M_tile + k];
        }

        // Load a 1 x M fragment of B from shared memory to registers:
        #pragma unroll
        for (int i = 0; i < M_thread; i++) {
            B_frag[i] = B_sm_ptr[i * M_warp + thread_x + k * M_tile];
        }

        // Compute:
        #pragma unroll
        for (int j = 0; j < M_thread ; j++) {

            bool is_masked_out = has_mask && (B_sm_ptr[j * M_warp + thread_x] == NULL_FLOAT_VALUE);

            #pragma unroll
            for (int i = 0; i < N_thread; i++) {
                if (is_masked_out) {
                    C_frag[i * M_thread + j] = MASK_VALUE;
                } else {
                    C_frag[i * M_thread + j] += A_frag[i] * B_frag[j];
                }
            }
        }
    }

    // Perform a pointwise operation, specified by the given lambda, on C

    template<typename F>
    __device__ void pointwise(F&& op) {
        #pragma unroll
        for (int i = 0; i < N_thread * M_thread; i++) {
            C_frag[i] = op(C_frag[i]);
        }
    }

    template<typename F>
    __device__ void pointwise(int tile_y, int tile_x, F&& op) {
        #pragma unroll
        for (int i = 0; i < N_thread * M_thread; i++) {
            int global_row = tile_y * N_tile + (i / M_thread) * N_warp + thread_y;
            int global_col = tile_x * M_tile + (i % M_thread) * M_warp + thread_x;

            C_frag[i] = op(C_frag[i], global_row, global_col);
        }
    }

    // copy from shared memory to registers in C

    __device__ void load(scalar_t* C_sm_ptr) {
        #pragma unroll
        for (int i = 0; i < N_thread; i++) {
            #pragma unroll
            for (int j = 0; j < M_thread ; j++) {
                C_frag[i * M_thread + j]
                    = C_sm_ptr[(thread_y + i * N_warp) * M_tile + j * M_warp + thread_x];
            }
        }
    }

    // copy from registers to shared memory

    __device__ void store(scalar_t* C_sm_ptr) {
        #pragma unroll
        for (int i = 0; i < N_thread; i++) {
            #pragma unroll
            for (int j = 0; j < M_thread ; j++) {
                C_sm_ptr[(thread_y + i * N_warp) * M_tile + j * M_warp + thread_x]
                    = C_frag[i * M_thread + j];
            }
        }
    }

    __device__ void store_transpose(scalar_t* C_sm_ptr) {
        #pragma unroll
        for (int i = 0; i < N_thread; i++) {
            #pragma unroll
            for (int j = 0; j < M_thread ; j++) {
                C_sm_ptr[thread_y + i * N_warp + (j * M_warp + thread_x) * N_tile]
                    = C_frag[i * M_thread + j];
            }
        }
    }

    // atomic add from registers go global memory

    template<typename accessor>
    __device__ void atomic_add(accessor gmem, int tile_x, int tile_y, int max_x, int max_y) {
        #pragma unroll
        for (int i = 0; i < N_thread; i++) {
            #pragma unroll
            for (int j = 0; j < M_thread ; j++) {
                int gmem_y = thread_y + i * N_warp + tile_y * N_tile;
                int gmem_x = thread_x + j * M_warp + tile_x * M_tile;

                if (gmem_y >= max_y || gmem_x >= max_x)
                    continue;

                atomicAdd((scalar_t*) &gmem[gmem_y][gmem_x], C_frag[i * M_thread + j]);
            }
        }
    }
};

template<typename scalar_t>
struct out_mma_warp_tile {
    // How much data is processed by a single thread:
    static constexpr int N_thread = 4;
    static constexpr int M_thread = 4;

    // Thread layout within a warp:
    static constexpr int N_warp = 8;
    static constexpr int M_warp = 4;
    static_assert(N_warp * M_warp == 32);

    // Warp layout within a block:
    static constexpr int N_block = 2;
    static constexpr int M_block = 4;
    static_assert(N_block * M_block * N_warp * M_warp == 256); // blockDim.x

    // Dimensions of the tile, in threads:
    static constexpr int N_tile = N_warp * N_block * N_thread;
    static constexpr int M_tile = M_warp * M_block * M_thread;

    static constexpr float EPS = 1e-10;

    // Registers:
    float A_frag[N_thread];            // N x 1 fragment
    float B_frag[M_thread];            // 1 x M fragment
    float L_frag[N_thread];            // N x 1 fragment
    float C_frag[N_thread * M_thread]; // N x M fragment

    int warp_x;   // x offset of the warp within the block tile
    int warp_y;   // y offset of the warp within the block tile
    int thread_x; // x offset of the thread within the warp tile
    int thread_y; // y offset of the thread within the warp tile

    __device__ out_mma_warp_tile() {
        int warp_id = threadIdx.x / 32;
        warp_x = (warp_id % M_block);
        warp_y = (warp_id / M_block);

        int lane_id = threadIdx.x % 32;
        thread_x = warp_x * M_warp * M_thread + lane_id % M_warp;
        thread_y = warp_y * N_warp * N_thread + lane_id / M_warp;
    }

    // Initialize C to all zeros
    __device__ void zero() {
        #pragma unroll
        for (int i = 0; i < N_thread; i++) {
            L_frag[i] = 0.f;
        }

        #pragma unroll
        for (int i = 0; i < N_thread * M_thread; i++) {
            C_frag[i] = 0.f;
        }
    }

    // Performs C = A * B + C
    __device__ void mma(
        const scalar_t* A_sm_ptr,
        const scalar_t* B_sm_ptr,
        int k
    ) {
        // Load a N x 1 fragment of A from shared memory to registers:
        #pragma unroll
        for (int i = 0; i < N_thread; i++) {
            A_frag[i] = A_sm_ptr[i * N_warp + thread_y + k * N_tile];
        }

        // Load a 1 x M fragment of B from shared memory to registers:
        #pragma unroll
        for (int i = 0; i < M_thread; i++) {
            B_frag[i] = B_sm_ptr[i * M_warp + thread_x + k * M_tile];
        }

        // Compute:
        #pragma unroll
        for (int i = 0; i < N_thread; i++) {
            L_frag[i] += A_frag[i];

            #pragma unroll
            for (int j = 0; j < M_thread ; j++) {
                C_frag[i * M_thread + j] += A_frag[i] * B_frag[j];
            }
        }
    }

    // Perform a pointwise operation, specified by the given lambda, on C
    template<typename F>
    __device__ void pointwise(F&& op) {
        #pragma unroll
        for (int i = 0; i < N_thread * M_thread; i++) {
            C_frag[i] = op(C_frag[i], i);
        }
    }

    // Copy C from registers to shared memory
    __device__ void store(scalar_t* C_sm_ptr) {
        #pragma unroll
        for (int i = 0; i < N_thread; i++) {
            float inv_rowsum = 1.f / max(L_frag[i], EPS);

            #pragma unroll
            for (int j = 0; j < M_thread ; j++) {
                C_sm_ptr[(thread_y + i * N_warp) * M_tile + j * M_warp + thread_x]
                  = C_frag[i * M_thread + j] * inv_rowsum;
            }
        }
    }

    template<typename accessor>
    __device__ void store(accessor gmem, int tile_y, int max_y) {
        #pragma unroll
        for (int i = 0; i < N_thread; i++) {
            float inv_rowsum = 1.f / max(L_frag[i], EPS);

            #pragma unroll
            for (int j = 0; j < M_thread ; j++) {
                int gmem_y = thread_y + i * N_warp + tile_y * N_tile;
                int gmem_x = thread_x + j * M_warp;

                if (gmem_y >= max_y)
                    continue;

                gmem[gmem_y][gmem_x] = C_frag[i * M_thread + j] * inv_rowsum;
            }
        }
    }

    template<typename accessor>
    __device__ void store_rowsum(accessor gmem, int tile_y, int max_y) {
        #pragma unroll
        for (int i = 0; i < N_thread; i++) {
            int gmem_idx = tile_y * N_tile + i * N_warp + thread_y;

            if (gmem_idx >= max_y)
                continue;

            gmem[gmem_idx] = L_frag[i];
        }
    }

    __device__ void store_transpose(scalar_t* C_sm_ptr) {
        #pragma unroll
        for (int i = 0; i < N_thread; i++) {
            float inv_rowsum = 1.f / max(L_frag[i], EPS);

            #pragma unroll
            for (int j = 0; j < M_thread ; j++) {
                C_sm_ptr[thread_y + i * N_warp + (j * M_warp + thread_x) * N_tile]
                    = C_frag[i * M_thread + j] * inv_rowsum;
            }
        }
    }
};
// shared memory fragment

template<typename T>
struct smem_fragment {
    T* smem;
    int N;
    int M;

    __device__ smem_fragment(char* shared_base, int N, int M)
      : smem(reinterpret_cast<T*>(shared_base)), N(N), M(M) { }

    __device__ void load(const T* gmem) {
        for (int i = threadIdx.x; i < N * M; i += blockDim.x) {
            smem[i] = gmem[i];
        }
    }

    template<typename accessor>
    __device__ void load(accessor gmem, int tile_y, int max_y) {
        for (int i = threadIdx.x; i < N * M; i += blockDim.x) {
            int x = i % M;
            int y = i / M;
            int gmem_y = y + tile_y * N;

            if (gmem_y >= max_y)
                continue;

            smem[i] = gmem[gmem_y][x];
        }
    }

    template<typename accessor>
    __device__ void load_transpose(accessor gmem, int tile_y, int max_y) {
        for (int i = threadIdx.x; i < N * M; i += blockDim.x) {
            int y = i % M;
            int x = i / M;
            int gmem_y = x + tile_y * N;

            if (gmem_y >= max_y)
                continue;

            smem[y * N + x] = gmem[gmem_y][y];
        }
    }

    template<typename accessor, typename accessor_mask>
    __device__ void load_transpose(accessor gmem, int tile_y, bool has_mask, accessor_mask mask, int max_y) {
        if (!has_mask)
            return load_transpose(gmem, tile_y, max_y);

        for (int i = threadIdx.x; i < N * M; i += blockDim.x) {
            int y = i % M;
            int x = i / M;
            int gmem_y = x + tile_y * N;

            if (y == 0 && !mask[gmem_y]) {
                smem[y * N + x] = NULL_FLOAT_VALUE;
                continue;
            }

            if (gmem_y >= max_y)
                continue;

            smem[y * N + x] = gmem[gmem_y][y];
        }
    }

    template<typename accessor>
    __device__ void store(accessor gmem, int tile_y, int max_y) {
        for (int i = threadIdx.x; i < N * M; i += blockDim.x) {
            int x = i % M;
            int y = i / M;
            int gmem_y = y + tile_y * N;

            if (gmem_y >= max_y) {
                continue;
            }

            gmem[gmem_y][x] = smem[i];
        }
    }

    __device__ unsigned size() {
        return N * M;
    }

    __device__ char* next() {
        return reinterpret_cast<char*>(smem + size());
    }
};

// forward kernel

template<typename scalar_t>
__global__ void forward_kernel(
    const PackedAccessor<scalar_t, 4> Q,
    const PackedAccessor<scalar_t, 4> K,
    const PackedAccessor<scalar_t, 4> V,
          PackedAccessor<scalar_t, 4> O,
          PackedAccessor<scalar_t, 3> L,
    const PackedAccessor<bool, 2> mask,
    const PackedAccessor<scalar_t, 3> attn_bias,
    const float scale,
    const bool causal,
    const bool has_mask,
    const bool has_attn_bias,
    const bool need_store_rowsum
) {

    const int q_seq_len = Q.size(2);
    const int k_seq_len = K.size(2);
    const int qk_seq_len_diff = k_seq_len - q_seq_len;  // for calculating causality when query and key lengths differ

    const int D = Q.size(3);
    const int E = V.size(3);


    const int batch = blockIdx.y / Q.size(1);
    const int heads = blockIdx.y % Q.size(1);

    // shortcut accessor

    auto Q_ = Q[batch][heads];
    auto K_ = K[batch][heads];
    auto V_ = V[batch][heads];
    auto O_ = O[batch][heads];
    auto L_ = L[batch][heads];
    auto attn_bias_ = attn_bias[heads];

    // mma

    mma_warp_tile<scalar_t, 4, 4> QK_mma;
    out_mma_warp_tile<scalar_t> out_mma;

    // tiles

    const int num_col_tiles = cdiv(k_seq_len, QK_mma.M_tile);
    const int tile_y = blockIdx.x;

    // shared memory

    extern __shared__ char _shared_mem[];

    smem_fragment<scalar_t> Q_sm{_shared_mem, QK_mma.N_tile, D};
    smem_fragment<scalar_t> A_sm{Q_sm.next(), QK_mma.N_tile, QK_mma.M_tile};
    smem_fragment<scalar_t> K_sm{A_sm.next(), QK_mma.M_tile, D};
    smem_fragment<scalar_t> V_sm{A_sm.next(), QK_mma.M_tile, E};

    // helper variables

    int global_row, global_col;
    float bias;

    // start loop

    out_mma.zero();

    Q_sm.load_transpose(Q_, tile_y, q_seq_len);

    for (int tile_x = 0; tile_x < num_col_tiles; tile_x++) {
        if (causal && (QK_mma.M_tile * tile_x - qk_seq_len_diff) >= (QK_mma.N_tile * (tile_y + 1)))
            continue;

        K_sm.load_transpose(K_, tile_x, has_mask, mask[batch], k_seq_len);

        __syncthreads();

        QK_mma.zero();

        for (int d = 0; d < D; d++) {
            QK_mma.mma(Q_sm.smem, K_sm.smem, d, has_mask);
        }

        QK_mma.pointwise(tile_y, tile_x, [&](float el, int global_row, int global_col) {

            if (global_row >= q_seq_len ||
                global_col >= k_seq_len ||
                causal && (global_row < (global_col - qk_seq_len_diff)))
                return 0.f;

            bias = has_attn_bias ? (float) attn_bias_[global_row][global_col] : 0.f;

            return __expf((scale * el + bias) - scale); 
        });

        QK_mma.store_transpose(A_sm.smem);

        __syncthreads();

        V_sm.load(V_, tile_x, k_seq_len);

        __syncthreads();

        for (int d = 0; d < QK_mma.M_tile; d++) {
            out_mma.mma(A_sm.smem, V_sm.smem, d);
        }

        __syncthreads();
    }

    out_mma.store(O_, tile_y, q_seq_len);

    if (need_store_rowsum)
        out_mma.store_rowsum(L_, tile_y, q_seq_len);
}

// forwards c++ function

std::vector<at::Tensor> flash_cosine_sim_attention_forward(
    torch::Tensor Q,
    torch::Tensor K,
    torch::Tensor V,
    torch::Tensor mask,
    torch::Tensor attn_bias,
    float scale,
    bool causal,
    bool need_store_rowsum
) {
    auto query_device = device_of(Q);
    const at::cuda::OptionalCUDAGuard device_guard(query_device);

    const int batch = Q.size(0);
    const int heads = Q.size(1);
    const int N = Q.size(2);
    const int M = K.size(2);
    const int D = Q.size(3);
    const int E = V.size(3);

    auto options = torch::TensorOptions().device(query_device).dtype(Q.scalar_type());

    auto O = at::empty({batch, heads, N, E}, options);
    auto L = at::empty({batch, heads, need_store_rowsum ? N : 0}, options);

    const dim3 threads_per_block(256);

    const int max_feature_dimension = max(D, E);

    const bool has_attn_bias = !!attn_bias.numel();
    const bool has_mask = !!mask.numel();

    AT_DISPATCH_FLOATING_TYPES_AND_HALF(Q.scalar_type(), "forward_cosine_sim_attention_backward", ([&] {

        using mma_warp_tile_klass = mma_warp_tile<scalar_t, 4, 4>;

        const dim3 blocks(cdiv(N, mma_warp_tile_klass::N_tile), batch * heads);

        const unsigned shared_mem_size = (mma_warp_tile_klass::N_tile * max_feature_dimension +
                                          mma_warp_tile_klass::M_tile * max_feature_dimension +
                                          mma_warp_tile_klass::N_tile * mma_warp_tile_klass::M_tile) * sizeof(scalar_t);

        forward_kernel<scalar_t><<<blocks, threads_per_block, shared_mem_size>>>(
            ACCESSOR(Q, 4, scalar_t),
            ACCESSOR(K, 4, scalar_t),
            ACCESSOR(V, 4, scalar_t),
            ACCESSOR(O, 4, scalar_t),
            ACCESSOR(L, 3, scalar_t),
            ACCESSOR(mask, 2, bool),
            ACCESSOR(attn_bias, 3, scalar_t),
            scale,
            causal,
            has_mask,
            has_attn_bias,
            need_store_rowsum
        );
    }));

    // handle error

    cudaDeviceSynchronize();

    CHECK_LAST_CUDA_ERROR();

    return { O, L };
}

// backward kernel

// backwards preprocess

// 1. do_scaled = do / rowsum
// 2. delta = rowsum(do_scaled * o)

// done by @ptillet at https://github.com/openai/triton/blob/master/python/tutorials/06-fused-attention.py

template <typename scalar_t>
__global__ void backward_preprocess(
    const PackedAccessor<scalar_t, 4> d_out,
    const PackedAccessor<scalar_t, 4> o,
    const PackedAccessor<scalar_t, 3> l,
          PackedAccessor<scalar_t, 4> d_out_scaled,
          PackedAccessor<scalar_t, 4> delta
) {
    const int heads = o.size(1);
    const int v_dim = o.size(3);

    const int batch_idx = blockIdx.x / heads;
    const int head_idx = blockIdx.x % heads;
    const int seq_idx = blockIdx.y;
    const int dim_idx = threadIdx.x;

    const int warp_id = threadIdx.x / 32;
    const int lane_id = threadIdx.x & 31;

    const unsigned mask = __ballot_sync(0xFFFFFFFFU, dim_idx < v_dim);

    float val = 0.0f;

    extern __shared__ char _shared_mem_preprocess[];

    scalar_t* sm_delta  = reinterpret_cast<scalar_t*>(&_shared_mem_preprocess);
    scalar_t* sm_do     = reinterpret_cast<scalar_t*>(&sm_delta[cdiv(v_dim, 32)]);
    scalar_t* sm_rowsum = reinterpret_cast<scalar_t*>(&sm_do[v_dim]);

    auto do_ = d_out[batch_idx][head_idx][seq_idx];
    auto o_ = o[batch_idx][head_idx][seq_idx];
    auto l_ = l[batch_idx][head_idx];
    auto do_scaled_ = d_out_scaled[batch_idx][head_idx][seq_idx];
    auto delta_ = delta[batch_idx][head_idx][seq_idx];

    // load rowsum into shared memory

    if (dim_idx == 0)
        sm_rowsum[0] = l_[seq_idx];

    __syncthreads();

    // load do into shared memory

    if (dim_idx < v_dim)
        sm_do[dim_idx] = do_[dim_idx] / max(sm_rowsum[0], 1e-10);

    __syncthreads();

    // store do_scaled to gmem

    if (dim_idx < v_dim)
        do_scaled_[dim_idx] = sm_do[dim_idx];

    // load do_scaled * o into registers

    if (dim_idx < v_dim)
        val = sm_do[dim_idx] * o_[dim_idx];

    // warp shuffle reduce

    for (int offset = 16; offset > 0; offset >>= 1) {
        val += __shfl_down_sync(mask, val, offset);
    }

    if (lane_id == 0)
        sm_delta[warp_id] = val;

    __syncthreads();

    if (warp_id == 0) {
        // use shared memory to reduce further across warps
        if (dim_idx < (blockDim.x / 32)) {
            val = sm_delta[lane_id];
        } else{
            val = 0;
        }

        for (int offset = 16; offset > 0; offset >>= 1) {
            val += __shfl_down_sync(mask, val, offset);
        }

        // write out reduced rowsum(do_scaled * o)

        if (dim_idx == 0) {
            delta_[0] = val;
        }
    }
}

// main backward kernel

template <typename scalar_t>
__global__ void backward_kernel(
    const PackedAccessor<scalar_t, 4> q,
    const PackedAccessor<scalar_t, 4> k,
    const PackedAccessor<scalar_t, 4> v,
    const PackedAccessor<bool, 2> mask,
    const PackedAccessor<scalar_t, 3> attn_bias,
          PackedAccessor<scalar_t, 4> dq,
          PackedAccessor<scalar_t, 4> dk,
          PackedAccessor<scalar_t, 4> dv,
          PackedAccessor<scalar_t, 3> d_attn_bias,
    const PackedAccessor<scalar_t, 4> d_out_scaled,
    const PackedAccessor<scalar_t, 4> delta,
    const float scale,
    const bool causal,
    const bool has_mask,
    const bool has_attn_bias,
    const bool attn_bias_requires_grad
) {

    // dimensions

    const int head = q.size(1);

    const int batch_idx = blockIdx.x / head;
    const int head_idx = blockIdx.x % head;

    const int q_seq_len = q.size(2);
    const int k_seq_len = k.size(2);
    const int qk_seq_len_diff = k_seq_len - q_seq_len;

    const int k_dim = k.size(3);
    const int v_dim = v.size(3);

    // shortcut accessors

    auto q_ = q[batch_idx][head_idx];
    auto k_ = k[batch_idx][head_idx];
    auto v_ = v[batch_idx][head_idx];
    auto dq_ = dq[batch_idx][head_idx];
    auto dk_ = dk[batch_idx][head_idx];
    auto dv_ = dv[batch_idx][head_idx];
    auto ds_ = d_attn_bias[head_idx];
    auto delta_ = delta[batch_idx][head_idx];
    auto do_ = d_out_scaled[batch_idx][head_idx];
    auto mask_ = mask[batch_idx];

    // handle attention bias

    auto attn_bias_ = has_attn_bias ? attn_bias[head_idx] : attn_bias[0];

    // some variables

    int col_tiles_offset, row_tiles_offset;
    int global_col, global_row;
    bool should_calculate_attn, should_calculate_row, should_calculate_col;
    scalar_t bias;

    // mma

    mma_warp_tile<scalar_t, 4, 4> mma;
    out_mma_warp_tile<scalar_t> out_mma;

    // tiles

    const int num_col_tiles = cdiv(k_seq_len, mma.M_tile);
    const int num_row_tiles = cdiv(q_seq_len, mma.N_tile);

    // shared memory

    extern __shared__ char _shared_mem_backward[];

    smem_fragment<scalar_t> sm_q {_shared_mem_backward, mma.N_tile, k_dim};
    smem_fragment<scalar_t> sm_attn {_shared_mem_backward, mma.N_tile, mma.M_tile};
    smem_fragment<scalar_t> sm_k {sm_q.next(), mma.M_tile, k_dim};
    smem_fragment<scalar_t> sm_v {sm_k.next(), mma.M_tile, v_dim};
    smem_fragment<scalar_t> sm_delta {sm_v.next(), mma.N_tile, 1};
    smem_fragment<scalar_t> sm_do {sm_delta.next(), mma.N_tile, v_dim};

    // loop over columns

    for (int tile_y = 0; tile_y < num_col_tiles; tile_y++) {

        // load keys and values into shared memory

        sm_k.load_transpose(k_, tile_y, has_mask, mask_, k_seq_len);

        sm_v.load_transpose(v_, tile_y, k_seq_len);

        // loop over rows

        for (int tile_x = 0; tile_x < num_row_tiles; tile_x++) {

            if (causal && (mma.M_tile * tile_x - qk_seq_len_diff) >= (mma.N_tile * (tile_y + 1)))
                continue;

            // load queries and scaled do into shared memories

            sm_q.load_transpose(q_, tile_x, q_seq_len);

            sm_do.load(do_, tile_x, q_seq_len);

            // load precomputed D = rowsum(do_scaled * o)

            sm_delta.load(delta_, tile_x, q_seq_len);

            __syncthreads();

            // accumulate qk similarities

            mma.zero();

            for (int d = 0; d < k_dim; d++) {
                mma.mma(sm_q.smem, sm_k.smem, d, has_mask);
            }

            // calculate attention

            mma.pointwise(tile_y, tile_x, [&](float el, int global_row, int global_col) {

                if (global_row >= q_seq_len ||
                    global_col >= k_seq_len ||
                    causal && (global_row < (global_col - qk_seq_len_diff)))
                    return 0.f;

                bias = has_attn_bias ? (float) attn_bias_[global_row][global_col] : 0.f;

                return __expf((scale * el + bias) - scale);

            });

            mma.store(sm_attn.smem);

            __syncthreads();

            mma.zero();

            // accumulate dv to global mem

            for (int d = 0; d < v_dim; d++) {
                mma.mma(sm_attn.smem, sm_do.smem, d, false);
            }

            __syncthreads();

            // atomic add to dv for now

            mma.atomic_add(dv_, 0, tile_y, v_dim, k_seq_len);

            // calculate dp

            mma.zero();

            for (int d = 0; d < v_dim; d++) {
                mma.mma_transpose_a(sm_do.smem, sm_v.smem, d, false);
            }

            // calculate dS
            // just do things manually out in the open, as the operation is not very reusable

            #pragma unroll
            for (int i = 0; i < mma.N_thread; i++) {
                int global_row = tile_y * mma.N_tile + i * mma.N_warp + mma.thread_y;

                scalar_t row_val = sm_delta.smem[tile_y * mma.N_tile + i * mma.N_warp + mma.thread_y];

                #pragma unroll
                for (int j = 0; j < mma.M_thread ; j++) {
                    int global_col = tile_x * mma.M_tile + j * mma.M_warp + mma.thread_x;

                    if (global_row >= q_seq_len ||
                        global_col >= k_seq_len ||
                        causal && (global_row < (global_col - qk_seq_len_diff)))
                        continue;

                    mma.C_frag[i * mma.M_thread + j] -= row_val;
                    mma.C_frag[i * mma.M_thread + j] *= sm_attn.smem[(mma.thread_y + i * mma.N_warp) * mma.M_tile + j * mma.M_warp + mma.thread_x];
                }
            }

            // store to ds_ if attention bias requires gradients

            if (attn_bias_requires_grad)
                mma.atomic_add(ds_, tile_x, tile_y, q_seq_len, k_seq_len);

            // scale

            mma.pointwise([&](scalar_t el) {
                return el * scale;
            });

            mma.store(sm_attn.smem);

            __syncthreads();

            // calculate dk

            mma.zero();

            for (int d = 0; d < k_dim; d++) {
                mma.mma(sm_attn.smem, sm_k.smem, d, false);
            }

            mma.atomic_add(dk_, 0, tile_y, k_dim, k_seq_len);

            // calculate dq

            for (int d = 0; d < k_dim; d++) {
                mma.mma_transpose_a(sm_attn.smem, sm_q.smem, d, false);
            }

            mma.atomic_add(dq_, 0, tile_x, k_dim, q_seq_len);

            __syncthreads();
        }
    }
}

// backwards c++ function

std::vector<torch::Tensor> flash_cosine_sim_attention_backward(
    torch::Tensor d_out,
    torch::Tensor o,
    torch::Tensor l,
    torch::Tensor q,
    torch::Tensor k,
    torch::Tensor v,
    torch::Tensor mask,
    torch::Tensor attn_bias,
    float scale,
    bool causal,
    bool attn_bias_requires_grad
) {
    auto query_device = device_of(q);

    const at::cuda::OptionalCUDAGuard device_guard(query_device);

    const int batch = q.size(0);
    const int heads = q.size(1);
    const int seq   = q.size(2);
    const int k_dim = k.size(3);
    const int v_dim = v.size(3);

    const bool has_attn_bias = !!attn_bias.numel();
    const bool has_mask = !!mask.numel();

    auto options = torch::TensorOptions().device(query_device).dtype(q.scalar_type());

    // setup dq, dk, dv

    auto d_out_scaled = at::empty_like(d_out, options);
    auto delta = at::empty({batch, heads, seq, 1}, options);

    auto dq = at::zeros_like(q, options);
    auto dk = at::zeros_like(k, options);
    auto dv = at::zeros_like(v, options);

    auto db = (has_attn_bias && attn_bias_requires_grad) ? at::zeros_like(attn_bias) : at::empty({attn_bias.size(0), 0, 0}, options);

    // setup backwards preprocess call

    const dim3 backwards_preprocess_threads_per_block(next_multiple_of(v_dim, 32));

    const dim3 backwards_preprocess_blocks(batch * heads, seq);

    // setup backwards call

    const dim3 backwards_threads_per_block(256);
    const dim3 backwards_blocks(batch * heads);


    AT_DISPATCH_FLOATING_TYPES_AND_HALF(q.scalar_type(), "forward_cosine_sim_attention_backward", ([&] {

        using mma_warp_tile_klass = mma_warp_tile<scalar_t, 4, 4>;

        const int N_tile = mma_warp_tile_klass::N_tile;
        const int M_tile = mma_warp_tile_klass::M_tile;

        const unsigned backwards_preprocess_shared_mem_size = (cdiv(v_dim, 32) + v_dim + 1) * sizeof(scalar_t);

        const unsigned backwards_shared_mem_size = (  (N_tile + M_tile) * k_dim +      // q, k
                                                      (N_tile + M_tile) * v_dim +      // v, do
                                                      N_tile                           // delta
                                                    ) * sizeof(scalar_t);

        backward_preprocess<scalar_t><<<backwards_preprocess_blocks, backwards_preprocess_threads_per_block, backwards_preprocess_shared_mem_size>>>(
            ACCESSOR(d_out, 4, scalar_t),
            ACCESSOR(o, 4, scalar_t),
            ACCESSOR(l, 3, scalar_t),
            ACCESSOR(d_out_scaled, 4, scalar_t),
            ACCESSOR(delta, 4, scalar_t)
        );

        backward_kernel<scalar_t><<<backwards_blocks, backwards_threads_per_block, backwards_shared_mem_size>>>(
            ACCESSOR(q, 4, scalar_t),
            ACCESSOR(k, 4, scalar_t),
            ACCESSOR(v, 4, scalar_t),
            ACCESSOR(mask, 2, bool),
            ACCESSOR(attn_bias, 3, scalar_t),
            ACCESSOR(dq, 4, scalar_t),
            ACCESSOR(dk, 4, scalar_t),
            ACCESSOR(dv, 4, scalar_t),
            ACCESSOR(db, 3, scalar_t),
            ACCESSOR(d_out_scaled, 4, scalar_t),
            ACCESSOR(delta, 4, scalar_t),
            scale,
            causal,
            has_mask,
            has_attn_bias,
            attn_bias_requires_grad
        );
    }));

    cudaDeviceSynchronize();

    // handle error

    CHECK_LAST_CUDA_ERROR();

    return {dq, dk, dv, db};
}

// bind

PYBIND11_MODULE(TORCH_EXTENSION_NAME, m) {
    m.def("forward", &flash_cosine_sim_attention_forward, "Flash Cosine-Sim Attention Forward");
    m.def("backward", &flash_cosine_sim_attention_backward, "Flash Cosine-Sim Attention Backward");
}
