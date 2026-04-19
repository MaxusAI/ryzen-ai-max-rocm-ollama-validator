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

> **Quick verification:** `make validate` runs the 9-layer test ladder
> automatically (host kernel, MES firmware, HIP smoke, container health,
> Ollama GPU discovery, small inference). `make validate-full` adds the
> ~200K-token prefill at the end. See
> [`docs/validation-tests.md`](docs/validation-tests.md) for what each
> layer means and how to fix failures.
>
> **Hit a `Memory access fault by GPU` or `library=cpu`?** Run
> `make mes-check` first — odds are it's the MES `0x83` firmware
> regression. Fix is one command: `make install-mes-firmware && sudo reboot`.

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

### 1. Replace Ubuntu's broken MES firmware on Strix Halo

**Single most important host-side fix.** The `linux-firmware` package
shipping with current Ubuntu Noble (`20240318.git3b128b60-0ubuntu2.x`)
includes an updated MES (Micro Engine Scheduler) firmware blob for
`gfx11_5_1` (Strix Halo) at version `0x83`. That version mismatches the
Linux KFD driver's expectation of the compute virtual-address layout, so
**every compute kernel — host or container, with or without the IOMMU on
— faults at the first dispatch**:

```
amdgpu 0000:c6:00.0: amdgpu: [gfxhub] page fault ...
GCVM_L2_PROTECTION_FAULT_STATUS:0x00800932
Faulty UTCL2 client ID: CPF (0x4)  WALKER_ERROR: 0x1  MAPPING_ERROR: 0x1
```

Container side, this surfaces as `Memory access fault by GPU node-1`
followed by Ollama silently falling back to
`library=cpu  total_vram="0 B"`. Confirmed by AMD engineers in
[ROCm/ROCm#5724](https://github.com/ROCm/ROCm/issues/5724),
[#6118](https://github.com/ROCm/ROCm/issues/6118),
[#6146](https://github.com/ROCm/ROCm/issues/6146), and
[Ubuntu bug 2129150](https://bugs.launchpad.net/bugs/2129150).

**Detection:**

```bash
sudo cat /sys/kernel/debug/dri/1/amdgpu_firmware_info | grep '^MES feature'
```

| Output                                        | Verdict                |
| --------------------------------------------- | ---------------------- |
| `MES feature version: 1, firmware version: 0x00000083` | **BROKEN — apply the fix below** |
| `MES feature version: 1, firmware version: 0x00000080` (or lower) | OK                     |

**Fix:** one command, then reboot:

```bash
make install-mes-firmware    # equivalent to: sudo ./scripts/install-mes-firmware.sh
sudo reboot
make mes-check               # verify; expects: MES firmware running: 0x00000080 (or lower)
```

The script downloads the pre-regression `gc_11_5_1_*` blobs from upstream
`linux-firmware` git commit `e2c1b15108…` (2025-07-16, the last commit
before the `0x83` update), verifies their md5 against known-good values,
installs them as `/lib/firmware/updates/amdgpu/` overrides (this
directory has precedence over `/lib/firmware/amdgpu/` and survives
`apt upgrade linux-firmware`), and rebuilds the running kernel's
initramfs so the override loads at very early boot. It is idempotent;
re-running with the same firmware commit is a no-op.

If you'd rather do it by hand (or use a different upstream commit), the
full procedure plus all script options are documented in
[`scripts/README.md`](scripts/README.md). The diagnostic story and list
of false trails that *almost* looked like fixes (IOMMU, CWSR,
`amdgpu-dkms`) is in
[`docs/build-fixes.md` Fix 4](docs/build-fixes.md#fix-4-mes-0x83-firmware-regression-the-actual-root-cause-of-the-page-fault).
For the layered post-install test ladder, see
[`docs/validation-tests.md`](docs/validation-tests.md) or just
`make validate`.

> **`0x83` won't be the last MES regression.** The MES subsystem has a
> track record of breakage across multiple firmware *and* kernel
> revisions on RDNA3+ (`gfx11_5_1` includes `gfx1151`). There is even
> a *separate*, kernel-side MES bug (`MES failed to respond to
> msg=MISC (WAIT_REG_MEM)`, bisected to upstream commit `e356d321d024`,
> mainline since 6.10) that surfaces with otherwise-good firmware.
> When the next regression lands, see
> [`docs/build-fixes.md` Fix 4 "Future-proofing"](docs/build-fixes.md#future-proofing-this-is-the-current-known-good-combination-not-a-permanent-one)
> for the playbook (rollback procedure, alternative firmware revisions,
> tracker links). Run `./scripts/install-mes-firmware.sh --list-known`
> for the live table of community-tested versions.

### 2. Kernel cmdline baseline (recommended)

Not strictly required (Fix 1 above is what unblocks GPU compute), but the
AMD-recommended baseline for compute on a UMA APU. It removes one
variable from any future debugging.

```bash
cat /proc/cmdline | tr ' ' '\n' | grep --extended-regexp 'iommu|amdgpu'
```

If you see `amd_iommu=off` or `amdgpu.cwsr_enable=0`, fix
`/etc/default/grub`:

```bash
sudo --edit /etc/default/grub
# Recommended GRUB_CMDLINE_LINUX_DEFAULT for this box:
#   "quiet splash thunderbolt.host_reset=0 amd_iommu=on iommu=pt"
sudo update-grub
sudo reboot
```

Why `iommu=pt` and not just `amd_iommu=on`: passthrough mode for kernel-
managed DMA is the AMD-recommended setting for compute on UMA APUs (lower
overhead, no IOMMU page walks for already-pinned kernel buffers, but full
GTT support for user pages).

After both fixes are in place, run the host smoke test from
[`docs/validation-tests.md`](docs/validation-tests.md#layer-2--host-hip-smoke-test-hipmemcpy--kernel-launch).
It should print `out=12345` and exit `0`.

### 3. Stop the host `ollama` systemd service

The host has Ubuntu's bundled `ollama` systemd service. It collides with this
container on port `11434` and on the model store at `/usr/share/ollama/.ollama`.
Stop and disable it:

```bash
sudo systemctl stop ollama
sudo systemctl disable ollama
sudo ss --tcp --listening --numeric --processes | grep 11434   # should be empty
```

### 4. Container runtime sanity

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

This is **almost always the buggy `0x83` MES firmware** in Ubuntu's
`linux-firmware` package. The container's ROCm install is fine — this is
a host firmware issue. Confirm with:

```bash
sudo cat /sys/kernel/debug/dri/1/amdgpu_firmware_info | grep '^MES feature'
# BROKEN:  MES feature version: 1, firmware version: 0x00000083
# OK:      MES feature version: 1, firmware version: 0x00000080  (or lower)
```

Re-do [Prerequisites § 1](#1-replace-ubuntus-broken-mes-firmware-on-strix-halo)
and reboot. Far less likely (and not a complete fix on its own): the
host kernel cmdline has `amd_iommu=off`; see
[Prerequisites § 2](#2-kernel-cmdline-baseline-recommended).
Full diagnostic story:
[`docs/build-fixes.md` Fix 4](docs/build-fixes.md#fix-4-mes-0x83-firmware-regression-the-actual-root-cause-of-the-page-fault).

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

### Host-installed Ollama runs on Vulkan or CPU instead of ROCm

> **Container users can skip this** — the compose image is built with
> the ROCm backend only.

**Symptom.** The official installer succeeds, the API answers, but
inference runs on Vulkan or CPU:

```text
... library=Vulkan compute=0.0 ...      # FAIL_VULKAN
... library=cpu ...                     # FAIL_CPU
```

**Almost always the actual cause: [Fix 4 (MES `0x83` firmware
regression)](docs/build-fixes.md#fix-4-mes-0x83-firmware-regression-the-actual-root-cause-of-the-page-fault).**
When the `rocm` runner can't initialise (because the GPU page-faults
on every compute kernel), Ollama's auto-selector falls back to Vulkan
or CPU. The fallback masks the real failure - it looks like a
backend-selection bug but it's a host kernel/firmware bug. Diagnose
in this order:

```bash
make mes-check                   # 1. Is the MES firmware safe?
                                 #    If "BROKEN: 0x83", fix it:
make install-mes-firmware        # 2. Install pre-regression firmware
sudo reboot                      # 3. Reload the kernel + firmware
make validate --mode host        # 4. Re-validate; Layer 5 should PASS
```

**You almost certainly do NOT need a systemd override to "force ROCm".**
On a healthy host (Fix 4 applied, Vulkan packages installed or not, no
weird env vars set anywhere), Ollama 0.21.0 picks ROCm by itself. The
`subprocess` line in `journalctl --unit=ollama` proves it:

```text
LD_LIBRARY_PATH=/usr/local/lib/ollama:/usr/local/lib/ollama/rocm     # <-- Ollama added this
ROCR_VISIBLE_DEVICES=0                                                # <-- Ollama added this
...
load_backend: loaded ROCm backend from /usr/local/lib/ollama/rocm/libggml-hip.so
```

**The actual minimal `systemctl edit ollama.service` for this stack** -
purely operational, no GPU-related env vars at all:

```ini
[Service]
Environment="OLLAMA_HOST=0.0.0.0:11434"            # let LAN clients (e.g. OpenWebUI) reach it
Environment="OLLAMA_DEBUG=2"                       # verbose logs for the validator
Environment="OLLAMA_MODELS=/usr/share/ollama/.ollama/models"   # explicit; matches default
```

Verified working on the test box with `User=ollama`, no `OLLAMA_ROCM`,
no `*_VISIBLE_DEVICES`, no `GGML_USE_ROCM`, no nothing else - and
`make validate --mode host` passes Layer 5 with `library=ROCm
compute=gfx1151`.

**`User=ollama Group=ollama`** (the install-script default) is fine.
`/dev/kfd` and `/dev/dri/renderD128` are mode `0666` on this hardware
and the systemd unit inherits `render`/`video` via `initgroups(3)`. If
Layer 5 fails *after* Fix 4 is verified safe, check the live process
picked up the supplementary groups (the install script's
`usermod -aG render,video ollama` only takes effect on a fresh exec,
not on `systemctl restart` of an `Restart=always` unit):

```bash
sudo cat /proc/$(pgrep --exact ollama)/status | grep --extended-regexp '^(Uid|Gid|Groups):'
# Healthy:
#   Uid:    997 997 997 997
#   Gid:    984 984 984 984
#   Groups: 44 984 992          # <-- video=44, ollama=984, render=992

# If 'Groups:' is empty, force a fresh exec:
sudo systemctl daemon-reload
sudo systemctl stop ollama.service
sudo systemctl start ollama.service
```

> **Note on retracted advice.** Earlier versions of this section
> recommended (a) switching to `User=root` and (b) setting
> `OLLAMA_ROCM=1` + `GGML_USE_ROCM=1` + `*_VISIBLE_DEVICES`. **Both
> were wrong** — controlled A/B tests on this box (drop each, see if
> anything breaks) show neither makes any difference once Fix 4 is in
> place. Full audit trail:
> [`docs/build-fixes.md` Fix 5 → "What we got wrong"](docs/build-fixes.md#what-we-got-wrong).

Full diagnostic story:
[`docs/build-fixes.md` Fix 5](docs/build-fixes.md#fix-5-minimal-systemd-override-for-the-host-install-and-what-wasnt-actually-needed).

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
