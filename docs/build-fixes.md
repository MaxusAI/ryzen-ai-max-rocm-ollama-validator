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

## Fix 3: IOMMU baseline (NOT the actual page-fault fix - see Fix 4)

> **Heads up.** This fix was an early misdiagnosis. The page-fault
> story narrated below *is* real, but `amd_iommu=off` was **not** what
> actually caused it on this hardware. The true root cause is the
> linux-firmware MES `0x83` regression, documented in
> [Fix 4](#fix-4-mes-0x83-firmware-regression-the-actual-root-cause-of-the-page-fault).
> Switching to `iommu=pt` is still the AMD-recommended baseline for
> compute on UMA APUs (lower IOMMU overhead, full GTT support for user
> pages), so we keep this section as a recommended host setting - but
> it is **not** the cure for `total_vram="0 B"` / `Memory access fault
> by GPU node-1`.

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
cannot turn the IOMMU back on.

---

## Fix 4: MES `0x83` firmware regression (the actual root cause of the page fault)

**This is what really caused the `Memory access fault by GPU node-1` /
`total_vram="0 B"` symptoms documented in Fix 3 above.** Discovered after
the IOMMU change had no effect - the same fault reproduced even with
`iommu=pt`, even with `amdgpu.cwsr_enable=1`, and even with
`amdgpu-dkms` removed.

**Root cause.** Ubuntu Noble's `linux-firmware` package
(`20240318.git3b128b60-0ubuntu2.x`) ships an updated MES (Micro Engine
Scheduler) firmware blob at `/lib/firmware/amdgpu/gc_11_5_1_mes_2.bin`
with feature version **`0x83`**. That version mismatches the Linux KFD
driver's expectation of how compute kernels' virtual address ranges are
laid out, so **every compute kernel on `gfx1151` page-faults at the
first dispatch** - on the host, in the container, with a HIP one-liner,
with `rocblas-bench`, with everything.

**Symptoms** (all three together = MES `0x83`):

```text
# Container side:
Memory access fault by GPU node-1 (Agent handle: 0x...)
   Reason: Page not present or supervisor privilege.
... source=runner.go msg="failure during GPU discovery" error="runner crashed"
... source=types.go msg="inference compute" id=cpu library=cpu ...
... msg="vram-based default context" total_vram="0 B" default_num_ctx=4096

# Host kernel log (dmesg):
amdgpu 0000:c6:00.0: amdgpu: [gfxhub] page fault (src_id:0 ring:153 vmid:8 pasid:32775)
amdgpu: GCVM_L2_PROTECTION_FAULT_STATUS:0x00800932
amdgpu:   Faulty UTCL2 client ID: CPF (0x4)
amdgpu:   WALKER_ERROR: 0x1
amdgpu:   MAPPING_ERROR: 0x1
amdgpu:   PERMISSION_FAULTS: 0x3

# Detection on the host:
$ sudo cat /sys/kernel/debug/dri/1/amdgpu_firmware_info | grep '^MES feature'
MES feature version: 1, firmware version: 0x00000083    # <-- broken
```

**Confirmed by AMD engineers** in
[ROCm/ROCm#5724](https://github.com/ROCm/ROCm/issues/5724),
[#6118](https://github.com/ROCm/ROCm/issues/6118),
[#6146](https://github.com/ROCm/ROCm/issues/6146), and
[Ubuntu bug 2129150](https://bugs.launchpad.net/bugs/2129150).

**Fix.** Install the pre-regression `gc_11_5_1_*` firmware blobs from
upstream `linux-firmware` git as overrides in
`/lib/firmware/updates/amdgpu/` (this directory has precedence over
`/lib/firmware/amdgpu/` and survives `apt upgrade linux-firmware`),
then rebuild the running kernel's initramfs so the override loads at
very early boot. Automated:

```bash
sudo ./scripts/install-mes-firmware.sh    # or: make install-mes-firmware
sudo reboot
./scripts/install-mes-firmware.sh --check # or: make mes-check
# expect: MES firmware running: 0x00000080 (or lower) - this box reports 0x7c
```

The script downloads from upstream commit
[`e2c1b15108…`](https://gitlab.com/kernel-firmware/linux-firmware/-/tree/e2c1b151087b2983249e106868877bd19761b976/amdgpu)
(2025-07-16, last commit before the `0x83` update), verifies md5 against
known-good values baked into the script, installs to
`/lib/firmware/updates/amdgpu/`, and rebuilds the initramfs. It is
idempotent. Full operational details in
[`../scripts/README.md`](../scripts/README.md).

**False trails** that *almost* looked like the fix:

| Suspected cause              | Why it looked plausible                                     | Why it was wrong                                |
| ---------------------------- | ----------------------------------------------------------- | ----------------------------------------------- |
| `amd_iommu=off`              | Page faults during H2D DMA - IOMMU is the obvious suspect    | Same fault with `iommu=pt`                      |
| `amdgpu.cwsr_enable=0`       | Compute Wave Save/Restore disabled = scheduler edge cases    | Same fault with `amdgpu.cwsr_enable=1`          |
| `amdgpu-dkms` shadowing OEM driver | DKMS rebuild often miscompiles for OEM kernels         | Same fault after removing DKMS                  |
| rocBLAS prune over-deletion (Fix 2) | Could cause kernel-not-found errors                  | Different symptom: would NOT page-fault         |
| Container --privileged / cgroups | Container-only failures often look like permission issues | Same fault outside any container               |

**Verification after the fix:** [`docs/validation-tests.md`](validation-tests.md)
Layer 1 (firmware version) and Layer 2 (HIP smoke test) - both pass
together if and only if the MES override is correctly loaded.

### Future-proofing: this is the *current* known-good combination, not a permanent one

The MES subsystem on RDNA3+ AMD GPUs has a track record of regressions
across **multiple firmware revisions** *and* **multiple kernel
revisions**. The `0x83` firmware regression we hit is one example. It
will not be the last. This section captures what we know so the next
person hitting "compute used to work, now it doesn't" has a starting
playbook.

**Known MES firmware revisions seen in the wild on `gfx1151`** (also
available live via `./scripts/install-mes-firmware.sh --list-known`):

| MES ver | Status | Notes |
| ------- | ------ | ----- |
| `0x74` | OK on older kernels | Reported in the [Framework AI 300 thread](https://community.frame.work/t/amd-gpu-mes-timeouts-causing-system-hangs-on-framework-laptop-13-amd-ai-300-series/71364), kernel 6.13 era |
| `0x7c` | OK (this repo's box) | Whatever shipped before commit `e2c1b151…` was applied; verified passing Layers 1-9 |
| `0x80` | OK (this script's pinned default) | kernel-firmware commit [`e2c1b151087b…`](https://gitlab.com/kernel-firmware/linux-firmware/-/tree/e2c1b151087b2983249e106868877bd19761b976/amdgpu) (2025-07-16) |
| `0x83` | **BROKEN** on Ubuntu Noble | Page-faults every compute kernel, see top of Fix 4 |

**Separate, kernel-side MES bugs exist in parallel.** Even with
`0x80`/`0x7c` firmware in place, three related fault modes show up in
`dmesg` on certain kernels - all from the same MES subsystem, all
distinct from the `0x83` firmware page-fault story above:

```text
# Mode A: timeout (workload usually still completes)
amdgpu 0000:c1:00.0: amdgpu: MES failed to respond to msg=MISC (WAIT_REG_MEM)
[drm:amdgpu_mes_reg_write_reg_wait [amdgpu]] *ERROR* failed to reg_write_reg_wait

# Mode B: ring buffer fills up (GPU wedged until reboot)
amdgpu 0000:c4:00.0: amdgpu: MES failed to respond to msg=MISC (WAIT_REG_MEM)
amdgpu 0000:c4:00.0: amdgpu: failed to reg_write_reg_wait
... (many of the above) ...
amdgpu 0000:c4:00.0: amdgpu: MES ring buffer is full.
amdgpu 0000:c4:00.0: amdgpu: MES ring buffer is full.
```

Mode A was **bisected to upstream commit `e356d321d024` ("drm/amdgpu:
cleanup MES11 command submission")**, in mainline since 6.10. Original
report and bisect:
[Spinics msg110461](https://www.spinics.net/lists/amd-gfx/msg110461.html),
Deucher follow-up:
[Spinics msg110519](https://www.spinics.net/lists/amd-gfx/msg110519.html).
A fix series from Alex Deucher in March 2026 sets
`SEM_WAIT_FAIL_TIMER_CNTL` to a non-zero value across SDMA versions to
prevent indefinite waits:
[freedesktop.org/archives/amd-gfx/2026-March/141006](https://lists.freedesktop.org/archives/amd-gfx/2026-March/141006.html),
[141012](https://lists.freedesktop.org/archives/amd-gfx/2026-March/141012.html).

Mode B is the **escalated form**: once enough timed-out submissions
pile up, the MES ring buffer fills and the GPU stays unrecoverable
until reboot. Tracked at
[drm/amd work_items/4749](https://gitlab.freedesktop.org/drm/amd/-/work_items/4749)
on Linux 6.18 + `linux-firmware-20260110`. **Important data point:
that report is on `gc_11_5_0` (Phoenix iGPU), not our `gc_11_5_1`
(Strix Halo) - which means this is the shared MES subsystem, not a
chip-specific issue.** Strix Halo will hit the same fault if the
upstream conditions are met.

The Framework community is tracking the same family on their AI 300
hardware (kernel 6.19.8 + `amd-gpu-firmware-20260309` reproducing the
Mode A timeout):
[Framework forum thread](https://community.frame.work/t/amd-gpu-mes-timeouts-causing-system-hangs-on-framework-laptop-13-amd-ai-300-series/71364).

`scripts/validate.sh` Layer 1 now scans `dmesg` for all three
patterns. Mode A is reported as a `warn` only (workload may still
complete). Mode B (`MES ring buffer is full`) gets an additional hard
warning telling the user to reboot, since Layers 5-8 will fail until
they do.

**Playbook for "the next regression"** (when a future `apt upgrade
linux-firmware` ships e.g. `0x90` and compute breaks again):

1. **Confirm it's the firmware**, not the kernel-side bug. Run
   `./scripts/validate.sh --layer 1`. The firmware-version line tells
   you what's loaded; the dmesg sub-check tells you whether the
   kernel-side `WAIT_REG_MEM` bug is also active. Two different fault
   modes need two different responses.
2. **Roll back to the pinned `0x80`** with
   `sudo ./scripts/install-mes-firmware.sh && sudo reboot`. The script
   installs into `/lib/firmware/updates/amdgpu/` which has precedence
   over the package directory, so `apt upgrade linux-firmware` won't
   undo the override.
3. **If `0x80` *also* regresses on a newer kernel**, browse upstream
   firmware history for an even older known-good commit:
   <https://gitlab.com/kernel-firmware/linux-firmware/-/commits/main/amdgpu>
   Look for commits that touched `amdgpu/gc_11_5_1_mes_2.bin`. Then:
   - Run `sudo ./scripts/install-mes-firmware.sh --commit <SHA>` once
     to download with the new commit.
   - The script will refuse to install with mismatched md5s (safety
     check). md5 the downloaded `.bin.zst` files and update the
     `KNOWN_MD5` table at the top of `scripts/install-mes-firmware.sh`.
   - Re-run the install. Then add a row to the table above so the next
     person doesn't have to re-discover this.
4. **For the kernel-side `WAIT_REG_MEM` bug (Mode A above)**, options
   in decreasing-pain order: (a) wait for the Deucher SDMA patch
   series to land in your distro kernel, (b) carry the patches as a
   local kernel build, (c) downgrade the kernel below 6.10, (d) live
   with periodic `rmmod amdgpu && modprobe amdgpu` to clear the stuck
   queue. There is no firmware-only workaround for this one.
5. **For `MES ring buffer is full` (Mode B)**, recovery requires a
   **reboot** - `rmmod` won't always clear it once the ring is full.
   To reduce recurrence: avoid running multiple long-running compute
   workloads concurrently while the underlying bug is unfixed, and
   subscribe to [drm/amd work_items/4749](https://gitlab.freedesktop.org/drm/amd/-/work_items/4749)
   for upstream progress. The validator's Layer 1 dmesg scan will
   flag this state on the next run so you don't waste time re-running
   layers against a wedged GPU.
6. **Where to file**: ROCm tracker for symptoms hitting compute
   (<https://github.com/ROCm/ROCm/issues>); `amd-gfx` mailing list for
   kernel-side fault modes
   (<https://lists.freedesktop.org/mailman/listinfo/amd-gfx>);
   freedesktop GitLab `drm/amd` for kernel-driver issues
   (<https://gitlab.freedesktop.org/drm/amd/-/issues>); distro-specific
   firmware bugs at the distro tracker (Ubuntu:
   <https://bugs.launchpad.net/ubuntu/+source/linux-firmware>).
   Include: `uname -r`, `dpkg -s linux-firmware | grep Version`,
   `sudo cat /sys/kernel/debug/dri/$DRI_INDEX/amdgpu_firmware_info`,
   and the relevant `dmesg` excerpt.

**What does NOT help on `gfx1151` for either MES fault mode** (already
ruled out - don't relitigate without new evidence):
`amd_iommu=off`, `iommu=pt`, `amdgpu.cwsr_enable=0/1`, removing
`amdgpu-dkms`, switching `User=ollama` -> `User=root`, setting
`OLLAMA_ROCM=1` / `GGML_USE_ROCM=1` / `*_VISIBLE_DEVICES`, container
`--privileged`, larger `--shm-size`. See [Fix 3](#fix-3-iommu-baseline-not-the-actual-page-fault-fix---see-fix-4)
and [Fix 5 "What we got wrong"](#what-we-got-wrong) for the audit
trail on each.

---

## Fix 5: minimal systemd override for the host install (and what wasn't actually needed)

> **Container users can skip this.** The container runs as root and
> joins the `video`/`render` groups via `docker-compose.yml`'s
> `group_add:`, so this section is purely a host-install note.

> **Heads up — this section has been rewritten *twice* after direct
> observation on the test box disproved earlier theories.** First we
> claimed `User=root` was required (wrong). Then we claimed
> `OLLAMA_ROCM=1` and friends were required to avoid Vulkan
> auto-selection (also wrong). The actual minimal override is much
> smaller. See "What we got wrong" at the bottom for the audit trail —
> it's preserved deliberately so the next "obvious" theory can be
> checked against the same evidence.

**Symptom.** `curl -fsSL https://ollama.com/install.sh | sh` succeeds
("AMD GPU ready."), `ollama serve` starts, the API answers, but every
inference runs on **CPU** (or under Vulkan, depending on which userspace
is present). With `OLLAMA_DEBUG=2`, the server log shows one of:

```text
# Variant A - silently falls back to CPU
... level=INFO source=types.go msg="inference compute" id=cpu library=cpu ...

# Variant B - falls back to Vulkan instead of ROCm (if Vulkan packages installed)
... msg="inference compute" id=00000000-c600-... library=Vulkan compute=0.0 ...

# Often preceded by:
... msg="failure during GPU discovery" error="..."
ggml_cuda_init: initializing rocBLAS on device 0 -> error: ...
```

`./scripts/validate.sh --mode host` will flag this in Layer 5 with the
specific verdicts `FAIL_CPU` or `FAIL_VULKAN`.

**The minimum the host install needs.** Once the host kernel is
healthy ([Fix 3](#fix-3-iommu-baseline-not-the-actual-page-fault-fix---see-fix-4)
+ [Fix 4](#fix-4-mes-0x83-firmware-regression-the-actual-root-cause-of-the-page-fault)),
`curl https://ollama.com/install.sh | sh` followed by `ollama pull
some-model` followed by `ollama run some-model` works. **No systemd
override is required to get ROCm.** We verified this on the test box
with the override stripped down to just operational settings:

```ini
# /etc/systemd/system/ollama.service.d/override.conf
[Service]
Environment="OLLAMA_HOST=0.0.0.0:11434"           # bind LAN, not just localhost
Environment="OLLAMA_DEBUG=2"                      # verbose logs for the validator
Environment="OLLAMA_MODELS=/usr/share/ollama/.ollama/models"   # explicit, default is the same path
```

That's it. Three operational `Environment=` lines, no `User=` change,
no `OLLAMA_ROCM=1`, no `*_VISIBLE_DEVICES`, no `GGML_USE_ROCM=1`, no
nothing else. The discovery log proves the auto-selection works
correctly on its own:

```text
load_backend: loaded ROCm backend from /usr/local/lib/ollama/rocm/libggml-hip.so
... msg="inference compute" id=0 ... library=ROCm compute=gfx1151 name=ROCm0 description="Radeon 8060S Graphics" ...
```

Why each operational override exists (none of these change which GPU
backend gets picked):

| Env var | Why it's in the override | What happens without it |
| ------- | ------------------------ | ----------------------- |
| `OLLAMA_HOST=0.0.0.0:11434` | Lets OpenWebUI / other LAN hosts hit the API | Default binds `127.0.0.1:11434`, only reachable from the same host |
| `OLLAMA_DEBUG=2`            | Surface the GPU discovery + runner-selection lines for the validator and for `journalctl --unit=ollama` debugging | `journalctl` only shows INFO-level summaries; harder to diagnose backend selection |
| `OLLAMA_MODELS=/usr/share/ollama/.ollama/models` | Explicit; matches the install script's default. Useful when running as a non-`ollama` user later. | Default is the same path so this is currently a no-op, but cheap insurance |

**What Ollama 0.21.0 does on its own.** From the actual subprocess
launch line in `journalctl --unit=ollama`
(`source=server.go:445 msg=subprocess`):

```text
LD_LIBRARY_PATH=/usr/local/lib/ollama:/usr/local/lib/ollama/rocm
OLLAMA_LIBRARY_PATH=/usr/local/lib/ollama:/usr/local/lib/ollama/rocm
ROCR_VISIBLE_DEVICES=0
```

Ollama detects `gfx1151` via the `discover/amdgpu.go` walker, decides
to use the `rocm/` runner subdirectory, and **automatically prepends
it to `LD_LIBRARY_PATH`** and **automatically sets
`ROCR_VISIBLE_DEVICES=0`** for the inference subprocess. None of these
need to be set by hand. Setting them in the systemd unit is harmless
(they'd just be redundant), but it isn't required.

**If `make validate --mode host` reports Layer 5 `FAIL_CPU` or
`FAIL_VULKAN`,** the cause is *not* this section. Walk the layers in
order:

1. **Layer 0 (`amd_iommu=off`)**: if present, see
   [Fix 3](#fix-3-iommu-baseline-not-the-actual-page-fault-fix---see-fix-4).
2. **Layer 1 (MES firmware version `0x83`)**: this is **almost always
   the actual culprit** when the `rocm` runner can't initialise and
   the auto-selector falls back to Vulkan or CPU. See
   [Fix 4](#fix-4-mes-0x83-firmware-regression-the-actual-root-cause-of-the-page-fault).
   Run `make mes-check` and `make install-mes-firmware` if needed.
3. **Layer 2 (host HIP smoke test)**: independent confirmation that
   GPU compute works. If the smoke test passes but Ollama still picks
   CPU/Vulkan, you've found something we haven't seen yet - file an
   issue with the `journalctl` output around the
   `source=server.go:445 msg=subprocess` line.

`User=ollama Group=ollama` (the install-script default) is fine -
leave it alone. On a healthy Strix Halo box `/dev/kfd` and
`/dev/dri/renderD128` are mode `0666` (world-rw) and the systemd unit
inherits the `render`/`video` supplementary groups via `initgroups(3)`,
so the `ollama` user has every permission it needs. To verify on your
own box:

```bash
sudo cat /proc/$(pgrep --exact ollama)/status | grep --extended-regexp '^(Uid|Gid|Groups):'
# Healthy:
#   Uid:    997 997 997 997
#   Gid:    984 984 984 984
#   Groups: 44 984 992              # <-- video=44, ollama=984, render=992
```

If `Groups:` is empty *and* `id ollama` shows the user is in those
groups in `/etc/group`, the running daemon was launched before the
install script's `usermod -aG` took effect. A `restart` won't fix
it (`Restart=always` keeps the same exec context). Force a fresh
exec:

```bash
sudo systemctl daemon-reload
sudo systemctl stop ollama.service
sudo systemctl start ollama.service
```

**Why the container avoids host issues entirely.** `docker-compose.yml`
builds its image from `external/ollama` with **only** the ROCm backend
(the `rocm-7` CMake preset + `gfx1151` arch target), so there's no
Vulkan runner to even consider. The compose service runs as root,
mounts `/dev/kfd` and `/dev/dri` directly, and adds the host
`video`/`render` group ids via `group_add:`. Container mode is
deterministic; host mode relies on Ollama's auto-selector which is
also fine but slightly more failure-modes-per-square-inch.

---

### What we got wrong

This section has been rewritten **twice**. The audit trail is kept
deliberately - both wrong theories looked obviously correct at the
time, and both were disproved by the same kind of "remove it and see
if anything actually breaks" test.

**Wrong theory #1: "`User=ollama` doesn't reliably get GPU access on
Strix Halo, you must switch to `User=root`."** Disproved by removing
`User=root` from the override and re-validating:

```text
$ sudo cat /proc/$(pgrep ollama)/status | grep -E '^(Uid|Gid|Groups):'
Uid:    997     997     997     997      <-- ollama (NOT root)
Groups: 44 984 992                       <-- video, ollama, render
$ make validate --mode host -- --layer 5
[PASS] library=ROCm + compute=gfx1151    <-- works fine as User=ollama
```

The original investigation flipped both `User=root` and added a
batch of `OLLAMA_ROCM=1` / `*_VISIBLE_DEVICES=0` env vars at the
same time. We attributed the fix to `User=root`, but a controlled
A/B (drop `User=root`, keep the env vars) showed `User=root` made no
observable difference.

**Wrong theory #2: "the official tarball ships both `rocm/` and
`vulkan/` runners, so you must set `OLLAMA_ROCM=1` and friends to
stop the auto-selector picking Vulkan."** Disproved by also
commenting out *every* runner-selection env var and re-validating:

```text
# /proc/<ollama-pid>/environ contains exactly:
OLLAMA_HOST=0.0.0.0:11434
OLLAMA_DEBUG=2
OLLAMA_MODELS=/usr/share/ollama/.ollama/models
# (nothing else - no OLLAMA_ROCM, no GGML_USE_ROCM, no *_VISIBLE_DEVICES)

$ dpkg -l | grep --extended-regexp 'libvulkan1|mesa-vulkan'
ii  libvulkan1:amd64           ...    <-- Vulkan IS installed
ii  mesa-vulkan-drivers:amd64  ...

$ sudo journalctl --unit=ollama -n 100 | grep load_backend
load_backend: loaded ROCm backend from /usr/local/lib/ollama/rocm/libggml-hip.so

$ make validate --mode host -- --layer 5
[PASS] library=ROCm + compute=gfx1151    <-- still ROCm, no env vars
```

Ollama 0.21.0 prefers ROCm > Vulkan > CPU on its own when both ROCm
and Vulkan runners are present and a ROCm-capable GPU is detected.
There's no need to override anything to "force" that ordering.

**Pattern these two wrongs share.** Both times we observed *(some
config change)* + *(restart)* + *(now it works)* and concluded the
config change caused the fix. The actual cause of "now it works" was
the restart picking up the **already-applied [Fix 4](#fix-4-mes-0x83-firmware-regression-the-actual-root-cause-of-the-page-fault)**
(MES firmware override loaded into the running kernel after a
reboot). The config changes were correlated noise. The lesson:
**when something stops failing, A/B-test by removing the change you
think fixed it before writing it up as the fix.** That's how both
of these errors were caught.

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
