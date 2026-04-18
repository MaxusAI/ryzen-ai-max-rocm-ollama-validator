# amd-rocm-ollama

Docker stack that builds [ollama](https://github.com/ollama/ollama) **v0.21.0** from
source against **ROCm 7.2.2** with native **gfx1151 (Strix Halo)** support, and serves
**Gemma 4** with up to a **256K** context window on an AMD Ryzen AI MAX+ 395 / Radeon
8060S APU.

- No Vulkan, no CUDA, no NVIDIA paths.
- Mounts the host model store at `/usr/share/ollama/.ollama` so existing pulls
  (e.g. `gemma4:31b-it-q4_K_M`) work immediately.
- Runtime image keeps the full ROCm SDK so `rocminfo` / `rocm-smi` work inside
  the container for live debugging.
- Aggressive `gfx1151`-only rocBLAS pruning keeps image size manageable.

---

## Hardware tested

| Item                | Value                                                       |
| ------------------- | ----------------------------------------------------------- |
| GPU                 | AMD Ryzen AI MAX+ 395 / Radeon 8060S (Strix Halo APU)       |
| ISA                 | `gfx1151` (RDNA 3.5)                                        |
| GPU VRAM (UMA)      | 96 GiB (BIOS UMA split)                                     |
| System RAM          | 31 GiB                                                      |
| ROCk module         | 6.16.13 / HSA Runtime 1.18                                  |
| Base image          | `rocm/dev-ubuntu-24.04:7.2.2-complete`                      |
| ollama              | `v0.21.0` (git submodule at `external/ollama`)              |
| Go (auto)           | `1.24.1` from `external/ollama/go.mod`                      |

---

## Prerequisites (one-time, on host)

### 1. Kernel cmdline must enable the AMD IOMMU

**This is mandatory on Strix Halo.** The iGPU's GTT (Graphics Translation
Table) needs the AMD IOMMU to translate host virtual addresses into
GPU-visible physical pages. With `amd_iommu=off` on the kernel cmdline,
*every* `hipMemcpy` host→device produces a `[gfxhub] page fault
... GCVM_L2_PROTECTION_FAULT_STATUS:0x00800932` (UTCL2 client `CPF`,
`WALKER_ERROR=1`, `MAPPING_ERROR=1`). ROCm appears to load fine
(`rocminfo` shows `gfx1151`, `rocblas_create_handle` succeeds), but the
first GPU memory access faults and Ollama silently falls back to CPU
(`vram-based default context: total_vram="0 B"`).

Check current state:

```bash
cat /proc/cmdline | tr ' ' '\n' | grep --extended-regexp 'iommu|amdgpu'
```

If you see `amd_iommu=off`, fix `/etc/default/grub`:

```bash
sudo --edit /etc/default/grub
# In GRUB_CMDLINE_LINUX_DEFAULT:
#   - REMOVE: amd_iommu=off
#   - ADD:    iommu=pt
# Recommended baseline for this box:
# GRUB_CMDLINE_LINUX_DEFAULT="quiet splash thunderbolt.host_reset=0 iommu=pt"

sudo update-grub
sudo reboot
```

After reboot, verify a single `hipMemcpy` works:

```bash
hipcc --offload-arch=gfx1151 -x c++ - -o /tmp/hip-smoke <<'EOF'
#include <hip/hip_runtime.h>
int main() {
    int *d, h = 42; hipMalloc(&d, 4);
    if (hipMemcpy(d, &h, 4, hipMemcpyHostToDevice) != hipSuccess) return 1;
    return hipDeviceSynchronize() == hipSuccess ? 0 : 2;
}
EOF
/tmp/hip-smoke && echo "GPU compute path healthy"
```

If that exits 0, ROCm is healthy and the container will see
`total_vram="96 GiB"` instead of `"0 B"`. See
[`docs/build-fixes.md`](docs/build-fixes.md#fix-3-host-amd_iommuoff-blocks-all-gpu-memory-access)
for the full diagnostic story.

### 2. Stop the host `ollama` systemd service

The host has Ubuntu's bundled `ollama` systemd service. It collides with this
container on port `11434` and on the model store at `/usr/share/ollama/.ollama`.
Stop and disable it:

```bash
sudo systemctl stop ollama
sudo systemctl disable ollama
sudo ss --tcp --listening --numeric --processes | grep 11434   # should be empty
```

### 3. Container runtime sanity

Confirm the user is in the `docker` group, the host has `/dev/kfd` and `/dev/dri`,
and the AMDGPU kernel module is loaded:

```bash
groups | grep --quiet docker || sudo usermod --append --groups docker "$USER"
ls /dev/kfd /dev/dri
lsmod | grep amdgpu
rocminfo | grep --extended-regexp 'Marketing Name|Name:[[:space:]]+gfx'
```

The base image must already be present:

```bash
docker pull rocm/dev-ubuntu-24.04:7.2.2-complete
```

> **Re-enabling the host ollama later:** the container runs as `root`, so any
> models/manifests it pulls become root-owned in `/usr/share/ollama/.ollama`.
> Before re-enabling the host service:
>
> ```bash
> sudo chown --recursive ollama:ollama /usr/share/ollama/.ollama
> sudo systemctl enable --now ollama
> ```

---

## Build & run

```bash
make submodules    # init external/ollama at v0.21.0
make build         # docker compose build (slow first time: ~10-25 min)
make up            # docker compose up --detach
make logs          # confirm ROCm discovery: 'discovered N AMD GPUs ... gfx1151'
make gpu-check     # rocminfo + rocm-smi from inside the container
```

API smoke test:

```bash
curl http://localhost:11434/api/tags                    # list installed models
curl http://localhost:11434/api/generate -d '{
  "model":"gemma4:31b-it-q4_K_M",
  "prompt":"Write a haiku about Strix Halo",
  "stream":false,
  "options":{"num_ctx":262144}
}'
```

`docker compose exec ollama ollama ps` should report `100% GPU` for the loaded model.

---

## Setting the 256K context

There is intentionally no derived "gemma4-256k" Modelfile - context length is set
by the caller per request:

| Client          | How                                                          |
| --------------- | ------------------------------------------------------------ |
| OpenWebUI       | Chat or model settings → Advanced Params → Context Length    |
| Raw API         | `options.num_ctx: 262144` in the JSON body                   |
| `ollama run`    | `/set parameter num_ctx 262144`                              |
| Server-wide     | Set `OLLAMA_CONTEXT_LENGTH=262144` in `docker-compose.yml`   |

The default `OLLAMA_CONTEXT_LENGTH=0` lets ollama auto-pick `4k`/`32k`/`256k`
based on detected VRAM (see
[external/ollama/envconfig/config.go:326](external/ollama/envconfig/config.go))
- this is left at default so smaller models like `llama3.2` aren't unnecessarily
inflated.

---

## OpenWebUI integration

This stack does **not** include OpenWebUI - run it separately and point it at
the ollama port:

- **OpenWebUI on the same host (native install):**
  set `OLLAMA_BASE_URL=http://localhost:11434`.

- **OpenWebUI in another docker compose stack:**

  ```yaml
  services:
    open-webui:
      image: ghcr.io/open-webui/open-webui:main
      extra_hosts:
        - "host.docker.internal:host-gateway"
      environment:
        OLLAMA_BASE_URL: "http://host.docker.internal:11434"
  ```

---

## KV-cache memory math (informational, 96 GiB VRAM confirmed)

`rocminfo` reports the gfx1151 agent's Pool 1 at `100663296 KB` ≈ **96 GiB** of
GPU-private COARSE GRAINED memory (the BIOS UMA split). Weights and KV cache
load entirely into that pool.

For `gemma4:31b-it-q4_K_M` at `num_ctx=262144`:

| Component                                                 | Estimated size  |
| --------------------------------------------------------- | --------------- |
| Weights (Q4_K_M)                                          | ~19.9 GiB       |
| KV cache @ q8_0 + flash-attn @ 256K (sliding window)      | ~6 - 10 GiB     |
| KV cache @ f16, no FA, @ 256K (worst-case fallback)       | ~12 - 20 GiB    |
| Activations + runtime overhead                            | ~2 - 3 GiB      |
| **Total worst case**                                      | **~43 GiB**     |

Headroom: ~50+ GiB free even in the FA-off fallback. You can push `num_ctx` to
512K with the 31B model and still have ~30 GiB free, or load two medium models
concurrently by raising `OLLAMA_MAX_LOADED_MODELS` to `2`.

---

## Flash attention reality check (gfx1151 + Gemma 4)

`OLLAMA_FLASH_ATTENTION=1` and `OLLAMA_KV_CACHE_TYPE=q8_0` are set in compose.
On gfx1151 + Gemma 4 there are three possible runtime outcomes - `make test-fa`
classifies which one you're in by greping the server log:

| Branch | What happens                                                                                                       | Action                                                                  |
| ------ | ------------------------------------------------------------------------------------------------------------------ | ----------------------------------------------------------------------- |
| (a)    | FA works, KV-q8_0 takes effect. Log: `enabling flash attention` + `kv cache type: q8_0`. Best case, fastest.       | Nothing - this is the goal.                                             |
| (b)    | FA rejected at load time. Log: `flash attention enabled but not supported by gpu`. KV silently downgrades to f16.  | Nothing - 96 GiB VRAM absorbs the 12-20 GiB f16 KV easily.              |
| (c)    | FA accepted but the 512-dim MMA kernels abort at runtime. Runner crashes; healthcheck reports unhealthy.           | Set `OLLAMA_FLASH_ATTENTION: "0"` in compose, `make restart`, retry.    |

Why this is uncertain: ROCm devices unconditionally pass the device-level FA
check in
[external/ollama/ml/device.go:485](external/ollama/ml/device.go), the
Gemma-4-specific FA gate at
[external/ollama/llm/server.go:213-223](external/ollama/llm/server.go) only
fires for CUDA, the 512×512 MMA kernels exist in v0.21.0 (see
[`0036-backport-kernels-for-gemma4.patch`](external/ollama/llama/patches/0036-backport-kernels-for-gemma4.patch)),
and the HIP build globs them in via
[ml/backend/ggml/ggml/src/ggml-hip/CMakeLists.txt:60-62](external/ollama/ml/backend/ggml/ggml/src/ggml-hip/CMakeLists.txt).
The rocWMMA FA path is **not** used here - it's gated to CDNA/RDNA4 in
[fattn-wmma-f16.cuh:9-22](external/ollama/ml/backend/ggml/ggml/src/ggml-cuda/fattn-wmma-f16.cuh)
and gfx1151 is RDNA 3.5.

---

## Troubleshooting

### `total_vram="0 B"` and Ollama runs on CPU even though `rocminfo` works

Symptom in `make logs`:

```
ggml_cuda_init: found 1 ROCm devices:
ggml_cuda_init: initializing rocBLAS on device 0
Memory access fault by GPU node-1 ... Reason: Page not present or supervisor privilege.
... level=INFO source=types.go msg="inference compute" id=cpu library=cpu ...
... level=INFO msg="vram-based default context" total_vram="0 B"
```

And in `dmesg`:

```
amdgpu: [gfxhub] page fault (src_id:0 ring:153 vmid:8 ...)
GCVM_L2_PROTECTION_FAULT_STATUS:0x00800932
Faulty UTCL2 client ID: CPF (0x4)
WALKER_ERROR: 0x1, MAPPING_ERROR: 0x1, PERMISSION_FAULTS: 0x3
```

This is `amd_iommu=off` on the kernel cmdline. The container's ROCm install
is fine - this is a host kernel/grub setup issue. Re-do
[Prerequisites § 1](#1-kernel-cmdline-must-enable-the-amd-iommu) and reboot.
Full diagnostic story:
[`docs/build-fixes.md` Fix 3](docs/build-fixes.md#fix-3-host-amd_iommuoff-blocks-all-gpu-memory-access).

### Container starts but `rocminfo` shows no GPU agent

```bash
make gpu-check                  # rocminfo + rocm-smi from inside the container
make logs | grep --extended-regexp 'discovered|rocm|hip|gfx'
```

If `rocminfo` inside the container shows no agent but works on the host, you
likely have a permission issue on `/dev/kfd` or `/dev/dri/renderD128`. Confirm
your host's `render` and `video` group ids and update `group_add:` in
[docker-compose.yml](docker-compose.yml):

```bash
getent group render video           # find the numeric ids
```

### `Error: HSA_STATUS_ERROR` or random hangs during generation

Strix Halo + ROCm 7.2 is generally stable, but if you see SDMA-related hangs
add this to compose `environment:` and restart:

```yaml
HSA_ENABLE_SDMA: "0"
```

### `rocBLAS error: Cannot read TensileLibrary*.dat` / page fault during init

The prune step in [docker/Dockerfile](docker/Dockerfile) deleted too much.
The current safe pattern *deletes by other-arch name* (gfx908, gfx90a, gfx942,
gfx950, gfx10xx, gfx11xx≠1151, gfx12xx) so anything **without** an arch tag
survives. This preserves:

- `*gfx1151*` per-arch lazy index + code objects (HSA-CO and `.dat`)
- `TensileLibrary_Type_*_fallback.dat` (54 arch-agnostic fallback files
  that rocBLAS reads at init - deleting these triggers the page fault above)
- `TensileManifest.txt`

If you see "Cannot read" with a specific filename, add a `! -name 'pattern'`
exclusion. See [`docs/rocblas-prune.md`](docs/rocblas-prune.md).

### Out of VRAM at 256K

You shouldn't hit this on this hardware (worst case ≈ 43 GiB of 96 GiB VRAM),
but if you do:

- Drop `num_ctx` to `131072` (128K) - same model, half the KV cache.
- Switch to `gemma4:e4b-it-q4_K_M` at full 256K.
- Confirm the BIOS UMA split is at the expected 96 GiB:
  `rocminfo | grep --before-context 5 'POOL 1' | head -n 30`.

### Need to rebuild the C++ backends from scratch

```bash
make clean-image                # remove the built image
docker builder prune --filter type=exec.cachemount   # drop the ccache mount
make build
```

---

## Repo layout

```text
.
├── docker/
│   ├── Dockerfile          # multi-stage: base/cpu/rocm-7/build/runtime
│   └── entrypoint.sh       # logs ROCm discovery, then exec ollama
├── docker-compose.yml      # single ollama service; KFD/DRI; FA env; healthcheck
├── external/
│   └── ollama/             # git submodule pinned to v0.21.0
├── docs/                   # maintainer notes (see docs/README.md)
│   ├── README.md
│   ├── build-fixes.md      # first-build failures and the fixes applied
│   └── rocblas-prune.md    # what the gfx1151-only rocBLAS prune actually keeps
├── Makefile                # convenience targets (make help)
├── .dockerignore
├── .gitignore
├── .gitmodules
└── README.md
```

For maintainer-level background (why specific Dockerfile choices were made,
how to verify the rocBLAS prune still works after a ROCm bump, etc.) see
[docs/](docs/).

---

## Out of scope

- No OpenWebUI service in this compose stack.
- No Vulkan, CUDA, or NVIDIA paths.
- No automatic model pulling - the host already has the models mounted.
- No `GGML_HIP_ROCWMMA_FATTN` (RDNA 3.5 isn't on the supported path).
- No multi-arch (linux/amd64 only - Strix Halo is x86_64).
- No `HSA_OVERRIDE_GFX_VERSION` workaround - gfx1151 is native in the
  v0.21.0 ROCm 7 preset
  ([CMakePresets.json:85](external/ollama/CMakePresets.json)).
