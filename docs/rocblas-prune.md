# rocBLAS gfx1151-only prune

The `rocm-7` stage in [../docker/Dockerfile](../docker/Dockerfile) installs
rocBLAS for **all** AMDGPU architectures listed in the "ROCm 7" preset's
`AMDGPU_TARGETS`
([../external/ollama/CMakePresets.json:85](../external/ollama/CMakePresets.json)),
because the cmake install step doesn't know which one we'll actually run on.
Then we delete everything tagged with a non-gfx1151 arch:

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

This is correct for our deployment (single hardware target, Strix Halo) but
it's the kind of step that breaks silently if a future rocBLAS version
reshuffles its file layout. This doc records the exact "before" and "after"
contents so future maintainers can sanity-check.

## Why "delete by other-arch" instead of "keep only gfx1151"

The first version of this prune used `! -name '*gfx1151*'`. That
**deleted 54 architecture-agnostic fallback files** like:

```
TensileLibrary_Type_DD_Contraction_l_Ailk_Bljk_Cijk_Dijk_fallback.dat
TensileLibrary_Type_HH_HPA_Contraction_l_Ailk_Bjlk_Cijk_Dijk_fallback.dat
... (54 total)
```

These have no `gfx<arch>` suffix and are read by rocBLAS during
`rocblas_create_handle()` / first GEMM call as part of its dispatch table.
Deleting them produced this exact crash:

```
ggml_cuda_init: initializing rocBLAS on device 0
Memory access fault by GPU node-1 ... Reason: Page not present or supervisor privilege.
```

(In the kernel log: `[gfxhub] page fault ... CPF (0x4) WALKER_ERROR=1
MAPPING_ERROR=1` - the GPU's command processor was handed a stale code
object pointer.)

Note that the **same** kernel-log message is also produced by an entirely
different host-side problem: the MES `0x83` firmware regression in
Ubuntu's `linux-firmware` package. See
[build-fixes.md Fix 4](build-fixes.md#fix-4-mes-0x83-firmware-regression-the-actual-root-cause-of-the-page-fault).
Distinguishing the two:

| Symptom check                                                        | Prune over-delete (Fix 2)   | Host MES `0x83` (Fix 4)            |
| -------------------------------------------------------------------- | --------------------------- | ---------------------------------- |
| `sudo cat /sys/kernel/debug/dri/1/amdgpu_firmware_info \| grep MES` | `MES … 0x80` or lower (OK)  | `MES … 0x83` (BROKEN)              |
| Host-only `hipcc` smoke test (no Docker)                             | passes                      | also fails identically             |
| `ls /usr/lib/ollama/rocm/rocblas/library \| grep -v gfx \| wc -l`   | 1 (only manifest)           | 55 (manifest + 54 fallbacks)       |

If both look healthy and you still see the crash, that's a third unknown
problem — file an issue with the dmesg + container logs.

## File-name taxonomy in ROCm 7.2.2 rocBLAS

After running rocBLAS install but **before** the prune, the directory
`dist/lib/ollama/rocm/rocblas/library/` contains five kinds of files:

| Pattern                                                                   | Purpose                                                                                                          | Per-arch?     |
| ------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------- | ------------- |
| `Kernels.so-NNN-<arch>.hsaco`                                             | Hand-coded assembly kernels per architecture (one or more files per arch)                                        | Yes           |
| `TensileLibrary_Type_<dtype>_Contraction_..._<arch>.{dat,co,hsaco}`       | Tensile-generated GEMM kernels per (data type x layout x arch).                                                  | Yes           |
| `TensileLibrary_Type_<dtype>_Contraction_..._fallback_<arch>.hsaco`       | Per-arch size-fallback variants of the above.                                                                    | Yes           |
| `TensileLibrary_Type_<dtype>_Contraction_..._fallback.dat`                | **Architecture-agnostic** fallback metadata (no arch suffix). Read at rocBLAS init - **must not be deleted**.    | No            |
| `TensileLibrary_lazy_<arch>.dat`                                          | Per-arch lazy-load index. rocBLAS reads this to discover which kernels exist for the active GPU at runtime.      | Yes           |
| `TensileManifest.txt`                                                     | Top-level manifest of which `*.{co,hsaco}` files are present. Plain text. Has full upstream build paths.         | No (singleton)|

There is **no** `TensileLibrary.dat` (without an `_lazy_<arch>` suffix) in
this rocBLAS version - earlier docs to that effect were wrong. The
load-bearing arch-agnostic file is the `*_fallback.dat` family.

## What survives the prune (gfx1151)

For our gfx1151 target, the surviving 151 files break down as:

| Group                                                       | Count | Notes                                              |
| ----------------------------------------------------------- | ----- | -------------------------------------------------- |
| `Kernels.so-*-gfx1151.hsaco`                                | 1     | Hand-coded kernel object for Strix Halo            |
| `TensileLibrary_Type_*_gfx1151.{co,dat,hsaco}`              | 94    | Per-dtype/layout Tensile kernels for gfx1151       |
| `TensileLibrary_Type_*_fallback_gfx1151.hsaco`              | included above | Per-arch size-fallback variants (suffix matches `*gfx1151*`) |
| `TensileLibrary_lazy_gfx1151.dat`                           | 1     | Per-arch lazy-load index                           |
| `TensileLibrary_Type_*_fallback.dat` (no arch)              | 54    | **Arch-agnostic fallback dispatch tables**         |
| `TensileManifest.txt`                                       | 1     | Singleton manifest                                 |
| **Total**                                                   | 151   |                                                    |

Pre-prune the directory has thousands of files: one full set per arch in the
"ROCm 7" preset's `AMDGPU_TARGETS`:

```
gfx942;gfx950;gfx1010;gfx1012;gfx1030;gfx1100;gfx1101;gfx1102;gfx1103;
gfx1150;gfx1151;gfx1200;gfx1201;gfx908:xnack-;gfx90a:xnack+;gfx90a:xnack-
```

## Verifying the prune after a rebuild

```bash
docker run --rm --entrypoint=/bin/bash amd-rocm-ollama:7.2.2 -c '
    set -euo pipefail
    cd /usr/lib/ollama/rocm/rocblas/library

    echo "=== file count (expect 151) ==="
    ls | wc --lines

    echo
    echo "=== arch-tagged files (should ALL be gfx1151) ==="
    ls | grep --extended-regexp "gfx[0-9]" | grep --invert-match "gfx1151" || echo "  (good: nothing)"
    echo "  gfx1151-tagged file count: $(ls | grep --count gfx1151)"

    echo
    echo "=== arch-agnostic survivors (expect 54 fallback.dat + TensileManifest.txt) ==="
    ls | grep --invert-match --extended-regexp "gfx[0-9]"
'
```

Expected:

```
=== file count (expect 151) ===
151
=== arch-tagged files (should ALL be gfx1151) ===
  (good: nothing)
  gfx1151-tagged file count: 96
=== arch-agnostic survivors (expect 54 fallback.dat + TensileManifest.txt) ===
TensileLibrary_Type_4xi8I_HPA_Contraction_l_Ailk_Bjlk_Cijk_Dijk_fallback.dat
... (54 lines) ...
TensileManifest.txt
```

## When this prune will go wrong

Watch out for these scenarios on future ROCm version bumps:

1. **AMD adds new architectures to the "ROCm 7" preset's
   `AMDGPU_TARGETS`** (e.g. `gfx1300` for a future RDNA generation). The
   `find` invocation lists arches explicitly, so any *new* arch's files
   will silently survive into the image. Symptom: image size grows
   noticeably between rebuilds. Action: extend the arch list in
   [../docker/Dockerfile](../docker/Dockerfile).
2. **AMD switches to per-arch subdirectories** like
   `library/gfx1151/...`. Then the `find -type f -name '*gfxNNN*'`
   pattern matches *no* files because the arch is in the path, not the
   filename. The prune becomes a no-op and the image is huge. Rewrite to
   `find ... -path '*gfx<other>*'`.
3. **AMD renames `*_fallback.dat` to `*_fallback_<arch>.dat`** (giving
   them an arch tag they currently lack). Then the new fallback files
   would be deleted by the arch-tagged prune. Symptom: the `Memory
   access fault` returns. Diagnose with the verification script above -
   if the "arch-agnostic survivors" count drops to 1 (just
   `TensileManifest.txt`), this is the cause.

If any of those happen, the failure mode at runtime is one of:

- `rocBLAS error: Cannot read from file ...` during the first GEMM call
- A repeat of the `Memory access fault by GPU node-1 ...` page fault from
  the original prune bug (see [build-fixes.md Fix 2](build-fixes.md#fix-2-rocblas-prune-pattern---flip-from-keep-gfx1151-to-drop-other-arches))
- A silent fallback to a slower path with no error message but visibly
  worse tokens/sec

Mitigation in all cases: comment out the `find ... -delete` step in
[../docker/Dockerfile](../docker/Dockerfile), rebuild, confirm the symptom
goes away, then reformulate the pattern.

## Why we don't just narrow `AMDGPU_TARGETS` instead

Tempting alternative: edit
[../external/ollama/CMakePresets.json](../external/ollama/CMakePresets.json)
to set `AMDGPU_TARGETS=gfx1151` only, so rocBLAS only installs gfx1151
kernels in the first place. We don't, for two reasons:

1. **Submodule hygiene.** `external/ollama` is pinned to upstream `v0.21.0`
   verbatim. Editing the submodule means carrying a local patch that has to
   be re-applied on every version bump.
2. **CMakeLists.txt auto-discovery filter.** Setting `-DAMDGPU_TARGETS=gfx1151`
   without going through the preset would trigger the auto-discovery filter at
   [../external/ollama/CMakeLists.txt:141](../external/ollama/CMakeLists.txt)
   that explicitly excludes gfx1151 (it only matches `gfx94[012]`,
   `gfx101[02]`, `gfx1030`, `gfx110[012]`, `gfx120[01]`). The "ROCm 7" preset
   explicitly bypasses this filter by setting the cache var; manually
   replicating that without using the preset is fragile.

Pruning post-install is uglier but keeps the submodule clean and survives
upstream changes to the discovery logic.
