// scripts/hip-kernel-test.cpp - minimal HIP smoke test for AMD Strix Halo
// (gfx1151). Used by Layer 2 of the validation ladder
// (../docs/validation-tests.md) to confirm that the GPU can actually
// execute compute kernels and copy memory back to the host.
//
// Build & run (host, with ROCm installed; -o is the only documented
// form of hipcc's output flag):
//   hipcc --offload-arch=gfx1151 \
//       scripts/hip-kernel-test.cpp \
//       -o /tmp/hip-kernel-test
//   /tmp/hip-kernel-test
//   echo "exit=$?"
//
// Build & run (inside the container, after bind-mounting the repo at
// /work via 'docker compose run --volume $PWD:/work ollama bash'):
//   hipcc --offload-arch=gfx1151 \
//       /work/scripts/hip-kernel-test.cpp \
//       -o /tmp/hip-kernel-test \
//       && /tmp/hip-kernel-test; echo "exit=$?"
//
// Expected output:
//   out=12345
//   exit=0
//
// Failure modes:
//   exit=1   noop kernel launch / sync failed (firmware or scheduler issue)
//   exit=2   hipMalloc failed (no VRAM visible to runtime)
//   exit=3   write_kernel sync failed (page fault during dispatch -
//            classic MES 0x83 firmware regression symptom)
//   exit=4   hipMemcpy device->host failed (DMA path broken)
//   exit=9   kernel ran but wrote the wrong value (very unusual)
//
// If exit is 1 or 3 and dmesg shows '[gfxhub] page fault ... CPF (0x4)
// WALKER_ERROR=1 MAPPING_ERROR=1', that's the MES 0x83 firmware
// regression - run scripts/install-mes-firmware.sh.

#include <iostream>
#include <hip/hip_runtime.h>

__global__ void noop_kernel() { }
__global__ void write_kernel(int *p) { p[0] = 12345; }

int main() {
    noop_kernel<<<1, 1>>>();
    if (hipDeviceSynchronize() != hipSuccess) return 1;

    int *d = nullptr;
    if (hipMalloc(&d, 4) != hipSuccess) return 2;

    write_kernel<<<1, 1>>>(d);
    if (hipDeviceSynchronize() != hipSuccess) return 3;

    int out = 0;
    if (hipMemcpy(&out, d, 4, hipMemcpyDeviceToHost) != hipSuccess) return 4;

    std::cout << "out=" << out << std::endl;
    return out == 12345 ? 0 : 9;
}
