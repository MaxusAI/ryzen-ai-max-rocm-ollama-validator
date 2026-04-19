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
| Base image          | `rocm/dev-ubuntu-24.04:7.2.2-complete` (container build)    |
| Host ROCm           | `7.2.1` (curl-installed for the host-Ollama path; one minor below the container)|
| ollama              | `v0.21.0` (git submodule at `external/ollama`)              |
| Go (auto)           | `1.24.1` from `external/ollama/go.mod`                      |

The host ROCm trails the container by one patch (7.2.1 vs 7.2.2); both
produce working `gfx1151` runners. Container is the recommended path
(version pinned in the Dockerfile, reproducible across hosts).

---

## Prerequisites (one-time, on host)

### 1. Replace Ubuntu's broken MES firmware on Strix Halo

**Single most important host-side fix.** Ubuntu Noble's current
`linux-firmware` ships an MES (Micro Engine Scheduler) blob at version
`0x83` for `gfx11_5_1` (Strix Halo). It mismatches the KFD driver's
compute VA layout and **every compute kernel — host or container —
faults at the first dispatch** with `[gfxhub] page fault … CPF (0x4)
WALKER_ERROR=1 MAPPING_ERROR=1`. Container side it surfaces as
`Memory access fault by GPU node-1` followed by Ollama silently
falling back to `library=cpu  total_vram="0 B"`.

**Detect:**

```bash
sudo cat /sys/kernel/debug/dri/1/amdgpu_firmware_info | grep '^MES feature'
# OK:      MES feature version: 1, firmware version: 0x00000080  (or lower)
# BROKEN:  MES feature version: 1, firmware version: 0x00000083
```

**Fix** (one command, then reboot):

```bash
make install-mes-firmware    # = sudo ./scripts/install-mes-firmware.sh
sudo reboot
make mes-check               # expect: PASS, MES firmware < 0x83
```

The installer downloads pre-regression `gc_11_5_1_*` blobs from
upstream `linux-firmware` git, md5-verifies them, drops them in
`/lib/firmware/updates/amdgpu/` (precedence over the package dir,
survives `apt upgrade linux-firmware`), and rebuilds initramfs.
Idempotent. Manual procedure, alternative upstream commits, and
`--check` / `--uninstall` flags are in
[`scripts/README.md`](scripts/README.md). Full diagnostic story
(false trails, AMD/Ubuntu tracker links, kernel-side MES bugs,
playbook for the next regression) is in
[`docs/build-fixes.md` Fix 4](docs/build-fixes.md#fix-4-mes-0x83-firmware-regression-the-actual-root-cause-of-the-page-fault).
Run `./scripts/install-mes-firmware.sh --list-known` for the live
table of community-tested versions.

### 2. Kernel cmdline baseline (recommended)

Not strictly required for compute (§1 is what unblocks GPU dispatch),
but the AMD-recommended baseline for a UMA APU. Removes one variable
from future debugging.

```bash
cat /proc/cmdline | tr ' ' '\n' | grep --extended-regexp 'iommu|amdgpu'
# Recommended GRUB_CMDLINE_LINUX_DEFAULT:
#   "quiet splash thunderbolt.host_reset=0 amd_iommu=on iommu=pt"
```

If you see `amd_iommu=off` or `amdgpu.cwsr_enable=0`, fix
`/etc/default/grub`, run `sudo update-grub`, and reboot. Background on
why `iommu=pt` (passthrough) is preferred on UMA APUs is in
[`docs/validation-tests.md` Layer 0](docs/validation-tests.md#layer-0--host-kernel-cmdline)
and [`docs/build-fixes.md` Fix 3](docs/build-fixes.md#fix-3-iommu-baseline-not-the-actual-page-fault-fix---see-fix-4).

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

`OLLAMA_CONTEXT_LENGTH` is intentionally **not** set in `docker-compose.yml`.
The default (`0`) lets ollama auto-pick `4k`/`32k`/`256k` based on detected
VRAM (see [external/ollama/envconfig/config.go:326](external/ollama/envconfig/config.go))
so smaller models like `llama3.2` aren't unnecessarily inflated. Set context
per request, not server-wide.

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

`rocminfo` reports Pool 1 at ~96 GiB on this BIOS UMA split. For
`gemma4:31b-it-q4_K_M` at `num_ctx=262144` the worst case (FA off,
KV f16) is ~43 GiB total: ~20 GiB weights + ~12-20 GiB KV f16 + ~2-3
GiB overhead. With FA on + KV q8_0 it drops to ~30 GiB. Either way
50+ GiB free, enough for 512K context on the 31B model or two medium
models concurrently (`OLLAMA_MAX_LOADED_MODELS=2`). Full operating
envelope and limit modes:
[`docs/break-modes.md`](docs/break-modes.md).

---

## Flash attention reality check (gfx1151 + Gemma 4)

`OLLAMA_FLASH_ATTENTION=1` and `OLLAMA_KV_CACHE_TYPE=q8_0` are set in
compose. On gfx1151 + Gemma 4 there are three possible runtime outcomes;
`make test-fa` classifies which one you're in by greping the server log:

| Branch | What happens                                                                                                  | Action                                                                  |
| ------ | ------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------- |
| (a)    | FA works, KV-q8_0 takes effect. Log: `enabling flash attention` + `kv cache type: q8_0`. Fastest.             | Nothing — this is the goal.                                             |
| (b)    | FA rejected at load. Log: `flash attention enabled but not supported by gpu`. KV silently downgrades to f16.  | Nothing — 96 GiB VRAM absorbs the 12-20 GiB f16 KV easily.              |
| (c)    | FA accepted but the 512-dim MMA kernels abort at runtime. Runner crashes; healthcheck reports unhealthy.      | Set `OLLAMA_FLASH_ATTENTION: "0"` in compose, `make restart`, retry.    |

Why the outcome is uncertain (gating in `external/ollama/ml/device.go`,
`llm/server.go`, the Gemma-4 patches in
`external/ollama/llama/patches/0036-backport-kernels-for-gemma4.patch`,
and the rocWMMA path being CDNA/RDNA4-only): see
[`scripts/README.md` → "Reading Ollama's runtime config & state"](scripts/README.md#reading-ollamas-runtime-config--state).

---

## Troubleshooting

### `total_vram="0 B"` and Ollama runs on CPU even though `rocminfo` works

Symptom in `make logs`: `Memory access fault by GPU node-1`,
`library=cpu`, `total_vram="0 B"`. In `dmesg`: `[gfxhub] page fault …
CPF (0x4) WALKER_ERROR=1 MAPPING_ERROR=1`.

This is **almost always the buggy `0x83` MES firmware** on the host
(the container's ROCm install is fine). Re-do
[Prerequisites § 1](#1-replace-ubuntus-broken-mes-firmware-on-strix-halo)
and reboot. A distant secondary cause is `amd_iommu=off` on the host
cmdline (see [Prerequisites § 2](#2-kernel-cmdline-baseline-recommended)).
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

> **Container users can skip this** — the compose image is ROCm-only.

The official `curl ... | sh` installer succeeds and the API answers,
but inference reports `library=Vulkan` or `library=cpu`. **Almost
always the actual cause is the MES `0x83` regression** ([Fix
4](docs/build-fixes.md#fix-4-mes-0x83-firmware-regression-the-actual-root-cause-of-the-page-fault)):
when the `rocm/` runner page-faults during init, Ollama's
auto-selector silently falls back. Diagnose in order:

```bash
make mes-check                              # 1. firmware safe?
make install-mes-firmware && sudo reboot    # 2. fix it if not
./scripts/validate.sh --mode host           # 3. re-validate; Layer 5 should PASS
```

The minimal sustainable systemd override is purely operational —
`OLLAMA_HOST`, `OLLAMA_DEBUG`, `OLLAMA_MODELS`. **No `User=root`
change, no `OLLAMA_ROCM=1`, no `*_VISIBLE_DEVICES` are needed**;
Ollama 0.21.0 picks ROCm on its own when the runner is healthy. Full
story including the override snippet, the user/group story, and the
audit trail of two retracted theories:
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
│   ├── Dockerfile                # multi-stage: base / build / runtime (ROCm 7.2.2 + ollama)
│   └── entrypoint.sh             # logs ROCm + ENV discovery, then execs ollama
├── docker-compose.yml            # single ollama service; KFD/DRI; FA env; healthcheck
├── docs/                         # maintainer notes (see docs/README.md for index)
│   ├── break-modes.md            #   what fails first under load: VRAM/GTT/MES
│   ├── build-fixes.md            #   first-build failures + fixes applied
│   ├── rocblas-prune.md          #   what the gfx1151-only rocBLAS prune keeps
│   └── validation-tests.md       #   per-layer spec for the 9-layer validate ladder
├── external/ollama/              # git submodule pinned to v0.21.0 (.gitmodules)
├── logs/                         # gitignored: per-machine JSONL run history
├── scripts/                      # see scripts/README.md
│   ├── lib/                      #   sourceable bash + python helpers (api, dmesg, pretty, snapshot, parse_*)
│   ├── hip-kernel-test.cpp       #   tiny HIP smoke kernel built by validate Layer 2
│   ├── install-mes-firmware.sh   #   roll back the broken 0x83 MES blob
│   ├── log-run.sh                #   JSONL wrapper around any test run
│   ├── stress-test.sh            #   VRAM/GTT/MES stress
│   ├── torture.sh                #   escalating torture ladder
│   └── validate.sh               #   9-layer validation ladder
├── Makefile                      # `make help` for the full target list
└── README.md
```

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
