# docs/

Engineering notes for `amd-rocm-ollama`. These are background articles for
maintainers, not user-facing setup docs (see the top-level
[../README.md](../README.md) for that).

| File                                                       | Topic                                                                      |
| ---------------------------------------------------------- | -------------------------------------------------------------------------- |
| [build-fixes.md](build-fixes.md)                           | Build/runtime failures and the fixes applied (CMake HIP, rocBLAS prune, host IOMMU) |
| [rocblas-prune.md](rocblas-prune.md)                       | What the gfx1151-only rocBLAS prune actually keeps and why                 |

**Start here:** if you're hitting `total_vram="0 B"` and CPU-only inference
on a freshly-built image, jump to
[build-fixes.md Fix 3](build-fixes.md#fix-3-host-amd_iommuoff-blocks-all-gpu-memory-access)
- it's almost certainly a host-side `amd_iommu=off` on the kernel cmdline,
not anything wrong with the container.
