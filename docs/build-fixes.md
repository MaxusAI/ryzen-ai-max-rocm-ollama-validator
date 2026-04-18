# Build fixes

A record of changes made to the original plan / Dockerfile in response to
problems hit during the first real `make build`. Keep this list short - if a
fix becomes "obvious", roll its rationale into a code comment in
[../docker/Dockerfile](../docker/Dockerfile) and remove the entry here.

---

## Fix 1: `CMAKE_PREFIX_PATH=/opt/rocm` in the `base` stage

**Symptom** (CPU stage configure):

```
-- Looking for a HIP compiler - /opt/rocm-7.2.2/lib/llvm/bin/clang++
CMake Error at CMakeLists.txt:140 (find_package):
  By not providing "Findhip.cmake" in CMAKE_MODULE_PATH this project has
  asked CMake to find a package configuration file provided by "hip", but
  CMake did not find one.

  Could not find a package configuration file provided by "hip" with any of
  the following names:

    hipConfig.cmake
    hip-config.cmake
```

**Root cause.** Two things conspired:

1. The `rocm/dev-ubuntu-24.04:7.2.2-complete` base image puts a HIP-capable
   `clang++` at `/opt/rocm-7.2.2/lib/llvm/bin/clang++`. CMake's `check_language(HIP)`
   in [external/ollama/CMakeLists.txt:135](../external/ollama/CMakeLists.txt)
   auto-discovers that compiler regardless of which preset you're configuring.
2. As soon as `CMAKE_HIP_COMPILER` is set, line 140 calls
   `find_package(hip REQUIRED)`. The `hip-config.cmake` files exist at
   `/opt/rocm/lib/cmake/hip/` in the image, but they're **not** auto-registered
   in CMake's package registry on Ubuntu (`apt` doesn't install a `rocm-cmake`
   metapackage the way RHEL/AlmaLinux's `dnf` does). Without
   `CMAKE_PREFIX_PATH=/opt/rocm`, CMake never looks there.

The upstream Dockerfile gets away with this because it builds on the
`rocm/dev-almalinux-8:${ROCMVERSION}-complete` image, which does register
`/opt/rocm/lib/cmake` via the `rocm-cmake` rpm.

**Fix.** Add `ENV CMAKE_PREFIX_PATH=/opt/rocm` to the `base` stage in
[../docker/Dockerfile](../docker/Dockerfile):

```dockerfile
ENV CMAKE_GENERATOR=Ninja
ENV LDFLAGS=-s
ENV CMAKE_PREFIX_PATH=/opt/rocm
WORKDIR /src
```

This makes both the `cpu` and `rocm-7` stages happy:

- The `cpu` stage now configures HIP successfully but only **builds** `ggml-cpu`
  (the build preset declares `targets: ["ggml-cpu"]` in
  [../external/ollama/CMakePresets.json:128](../external/ollama/CMakePresets.json)),
  so the HIP backend is parsed but never compiled in this stage. The
  `cmake --install build --component CPU --strip` step only copies CPU artifacts.
- The `rocm-7` stage was already setting `PATH=/opt/rocm/bin:$PATH`, but PATH
  is irrelevant to `find_package`. Setting `CMAKE_PREFIX_PATH` is what actually
  makes the package lookup deterministic across both stages.

**Alternative considered.** Disabling HIP detection in the `cpu` stage
(`CMAKE_DISABLE_FIND_PACKAGE_hip=TRUE` plus a stub for `check_language(HIP)`)
would also work, but it would diverge from upstream behavior and require
keeping the override in sync with future CMakeLists.txt changes. Setting
`CMAKE_PREFIX_PATH` is one line and matches what the AlmaLinux base does
implicitly.

---

## Fix 2: rocBLAS prune pattern - flip from "keep gfx1151" to "drop other arches"

**Original (broken) plan:**

```dockerfile
RUN find dist/lib/ollama/rocm/rocblas/library -type f \
        ! -name '*gfx1151*' \
        ! -name 'TensileLibrary.dat' \
        ! -name 'TensileManifest*' \
        -delete || true
```

**Symptom this caused:**

```
ggml_cuda_init: found 1 ROCm devices:
ggml_cuda_init: initializing rocBLAS on device 0
Memory access fault by GPU node-1 ... Reason: Page not present or supervisor privilege.
```

**Root cause.** The "keep only `*gfx1151*` + manifest" pattern deleted 54
architecture-agnostic fallback `.dat` files like
`TensileLibrary_Type_DD_Contraction_l_Ailk_Bljk_Cijk_Dijk_fallback.dat` (no
`gfx<arch>` suffix). rocBLAS reads those at `rocblas_create_handle()` /
first kernel call as part of its kernel catalog. With the files gone, the
rocBLAS dispatch table points at non-existent code-object addresses, the
GPU command processor walks a stale page table entry, and the amdgpu
kernel driver reports a `[gfxhub] page fault ... CPF (0x4) WALKER_ERROR=1
MAPPING_ERROR=1`. (See Fix 3 for a different cause of the *same* error
message - it took two debugging passes to disentangle.)

**Fix.** Flip the prune from "keep what we recognize" to "delete what we
recognize as wrong-arch", so anything *without* an arch tag survives by
default:

```dockerfile
RUN find dist/lib/ollama/rocm/rocblas/library -type f \
        \( \
            -name '*gfx908*'  -o -name '*gfx90a*'  -o \
            -name '*gfx942*'  -o -name '*gfx950*'  -o \
            -name '*gfx1010*' -o -name '*gfx1012*' -o \
            -name '*gfx1030*' -o -name '*gfx1100*' -o \
            -name '*gfx1101*' -o -name '*gfx1102*' -o \
            -name '*gfx1103*' -o -name '*gfx1150*' -o \
            -name '*gfx1200*' -o -name '*gfx1201*' \
        \) \
        -delete
```

Arch list mirrors the `ROCm 7` preset's `AMDGPU_TARGETS` in
[external/ollama/CMakePresets.json:85](../external/ollama/CMakePresets.json),
minus `gfx1151`.

**Result.** After the second build:

| Metric                       | Old (broken) prune  | New (working) prune |
| ---------------------------- | ------------------- | ------------------- |
| Files in `rocblas/library/`  | 97                  | 151                 |
| Arch-tagged files            | 96 (all gfx1151)    | 96 (all gfx1151)    |
| Arch-agnostic fallback dats  | 0                   | 54                  |
| `TensileManifest.txt`        | yes                 | yes                 |

**Verification:**

```bash
docker run --rm --entrypoint=/bin/bash amd-rocm-ollama:7.2.2 -c \
    'ls /usr/lib/ollama/rocm/rocblas/library/ | grep -v "gfx[0-9]" | wc -l'
# expect: 55  (54 *_fallback.dat + TensileManifest.txt)
```

See [rocblas-prune.md](rocblas-prune.md) for the full file-name taxonomy.

---

## Fix 3: host `amd_iommu=off` blocks all GPU memory access

**This was the real reason `make up` followed by `make logs` showed
`total_vram="0 B"` and CPU-only inference, even after Fix 2.**

**Symptom (container side):**

```
ggml_cuda_init: found 1 ROCm devices:
  Device 0: Radeon 8060S Graphics, gfx1151 (0x1151), VMM: no, Wave Size: 32
ggml_cuda_init: initializing rocBLAS on device 0
Memory access fault by GPU node-1 (Agent handle: 0x...) on address 0x... .
   Reason: Page not present or supervisor privilege.
... level=INFO source=runner.go msg="failure during GPU discovery" error="runner crashed"
... level=INFO source=types.go msg="inference compute" id=cpu library=cpu ...
... level=INFO msg="vram-based default context" total_vram="0 B" default_num_ctx=4096
```

**Symptom (host kernel log):**

```
amdgpu 0000:c6:00.0: amdgpu: [gfxhub] page fault (src_id:0 ring:153 vmid:8 pasid:32775)
amdgpu: GCVM_L2_PROTECTION_FAULT_STATUS:0x00800932
amdgpu:   Faulty UTCL2 client ID: CPF (0x4)
amdgpu:   WALKER_ERROR: 0x1
amdgpu:   MAPPING_ERROR: 0x1
amdgpu:   PERMISSION_FAULTS: 0x3
```

The fault repeats across every test process (Ollama runner, raw `hipMemcpy`
test on the host, `rocblas-bench`, etc.) at the **first** host→device DMA.

**Diagnostic ladder used to isolate the root cause** (each step ruled out
something so the next step is justified):

1. `rocminfo` and `rocm-smi` inside the container both report the gfx1151
   agent correctly. So HSA topology + KFD are healthy.
2. `rocblas_create_handle()` alone succeeds inside the container (small
   `hipcc` test case). So rocBLAS init *can* start.
3. `hipMemcpy(d_buf, h_buf, 64, hipMemcpyHostToDevice)` faults inside the
   container. So the failure is at the moment the GPU first walks a host
   page.
4. The same `hipMemcpy` test compiled and run **directly on the host**
   (no Docker, no namespaces) faults identically. So this is host-level,
   not container/cgroups/seccomp.
5. `rocm-smi` shows GPU at 0% utilization with no other clients. So this
   isn't contention.
6. `dmesg` shows `[gfxhub] page fault ... WALKER_ERROR=1 MAPPING_ERROR=1`
   on every test process - the GPU's page-table walker can't find a valid
   mapping for the host page it was asked to DMA from.
7. `cat /proc/cmdline` reveals **`amd_iommu=off`**.

`amd_iommu=off` disables the AMD IOMMU. On Strix Halo (and any APU using a
unified memory architecture for GPU compute), the iGPU's GTT relies on the
IOMMU to translate host-allocated user pages into addresses the GPU's
command processor can read. Disable the IOMMU and the GPU sees an empty
page-table entry on every H2D DMA - exactly the
`MAPPING_ERROR=1, WALKER_ERROR=1` we saw.

**Fix.** Edit `/etc/default/grub` on the host:

```bash
# /etc/default/grub - before:
GRUB_CMDLINE_LINUX_DEFAULT="quiet splash thunderbolt.host_reset=0 amd_iommu=off amdgpu.cwsr_enable=0 ttm.pages_limit=25165824"

# /etc/default/grub - after (recommended baseline for this box):
GRUB_CMDLINE_LINUX_DEFAULT="quiet splash thunderbolt.host_reset=0 iommu=pt"
```

Then:

```bash
sudo update-grub
sudo reboot
# Verify after reboot:
cat /proc/cmdline | tr ' ' '\n' | grep iommu     # expect: iommu=pt
hipcc --offload-arch=gfx1151 -x c++ - -o /tmp/hip-smoke <<'EOF'
#include <hip/hip_runtime.h>
int main() {
    int *d, h = 42; hipMalloc(&d, 4);
    if (hipMemcpy(d, &h, 4, hipMemcpyHostToDevice) != hipSuccess) return 1;
    return hipDeviceSynchronize() == hipSuccess ? 0 : 2;
}
EOF
/tmp/hip-smoke && echo OK
```

`OK` means GPU compute is healthy and `make up && make logs` will now show
`inference compute ... library=ROCm ... total="96 GiB"` instead of
`library=cpu ... total_vram="0 B"`.

**Why `iommu=pt` and not `amd_iommu=on`.** Both turn the IOMMU on, but
`iommu=pt` puts it in passthrough mode for kernel-managed DMA, which is
the AMD-recommended setting for GPU compute on UMA APUs (lower overhead,
no IOMMU page walks for already-pinned kernel buffers, but full GTT
support for user pages).

**Why this isn't the container's problem to fix.** Kernel cmdline,
`/etc/default/grub`, and the IOMMU are all host-kernel concerns. A
container can request `--privileged`, mount `/dev/kfd`, etc., but it
cannot turn the IOMMU back on. This is documented in the README's
prerequisites section as item #1 - it's the single most important
host-side requirement for this stack to work.

---

## Build numbers (first successful build)

For sanity-checking future builds against:

| Metric                          | Value                                                                |
| ------------------------------- | -------------------------------------------------------------------- |
| Total wall time (cold build)    | ~10 minutes (mostly `rocm-7` configure+install)                      |
| `rocm-7` install step           | 579 s (largest single step; rocBLAS install dominates)               |
| Final image size                | 23.8 GB                                                              |
| Final rocBLAS file count        | 151 files (96 gfx1151-tagged + 54 arch-agnostic fallback + manifest) |
| ggml CPU variants installed     | 7 (x64, sse42, sandybridge, haswell, skylakex, icelake, alderlake)   |
| Image SHA (after Fix 2 reprune) | `49f71ef903b5`                                                       |

The 23.8 GB total is dominated by the `rocm/dev-ubuntu-24.04:7.2.2-complete`
runtime base layer (~22 GB on its own). That's the trade-off picked in the
plan: keep the full ROCm SDK in the runtime stage so `rocminfo` and `rocm-smi`
work inside the container for live debugging. A scratch/ubuntu-minimal runtime
would shave this down to ~3 GB but lose those tools.
