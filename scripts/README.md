# scripts/

Operational scripts for the `amd-rocm-ollama` stack on AMD Strix Halo
(`gfx1151`):

| Script                                                 | Run as | What it does                                                                |
| ------------------------------------------------------ | ------ | --------------------------------------------------------------------------- |
| [`install-mes-firmware.sh`](install-mes-firmware.sh)   | root   | Replace Ubuntu's broken MES `0x83` firmware with a pre-regression blob      |
| [`validate.sh`](validate.sh)                           | user   | Walk the 9-layer validation ladder from `docs/validation-tests.md`          |
| [`stress-test.sh`](stress-test.sh)                     | user   | VRAM/GTT/MES stress: largest installed model, parallel reqs at full context |
| [`torture.sh`](torture.sh)                             | user   | Escalating ladder of stress configs - finds the actual breakage threshold (concurrency, sustained decode, queue saturation) |
| [`log-run.sh`](log-run.sh)                             | user   | Wrap any of the above and append a timestamped JSONL record (versions + result) to `logs/run-history.jsonl` |
| [`hip-kernel-test.cpp`](hip-kernel-test.cpp)           | n/a    | C++ source for Layer 2's host HIP smoke test (compiled by `validate.sh`)    |
| [`lib/snapshot.sh`](lib/snapshot.sh)                   | n/a    | Sourceable helper: prints a single-line JSON snapshot of system versions    |

> **Don't invoke via `sh` or `sudo sh`.** Run the scripts directly so the
> `#!/usr/bin/env bash` shebang is honoured (`./scripts/foo.sh` or
> `sudo ./scripts/foo.sh` for the firmware installer). Both scripts also
> self-promote to bash if you do invoke them via `sh`/`dash`, but it's
> cleaner not to. `validate.sh` does *not* need root - it uses
> `sudo --non-interactive` internally for the two checks that do
> (debugfs read + `rocm-smi`); run `sudo -v` once first if you don't
> want password prompts mid-run.

All are also wired into the top-level [`Makefile`](../Makefile):

```bash
make install-mes-firmware    # sudo wrapper around install-mes-firmware.sh
make validate                # run validate.sh --skip-long-ctx (fast)
make validate-full           # run validate.sh end-to-end including 200K context
make validate-logged         # validate-full, but appends a JSONL record to logs/run-history.jsonl
make mes-check               # quick: install-mes-firmware.sh --check
make stress-test             # full stress test (largest model, full ctx, ~30 min, logged)
make stress-test-quick       # smaller model + 32K ctx, concurrency=2 (~5 min, logged)
make run-history             # show last 10 entries from logs/run-history.jsonl
```

---

## `stress-test.sh`

Pushes the GPU as hard as it can without being malicious: discovers
the largest installed Ollama model, opens N parallel `/api/generate`
requests at the model's max `num_ctx`, and watches `rocm-smi` +
`dmesg` for distress signals while they run.

**What it surfaces** (in increasing severity):

1. *Soft failure*: requests time out or return 5xx → throughput problem.
2. *Mode A MES*: new `MES failed to respond` lines in `dmesg` during the
   run → kernel-side regression (see Fix 4 in `docs/build-fixes.md`).
3. *Mode B MES*: new `MES ring buffer is full` lines → **GPU is wedged**
   until reboot. Stress test exits non-zero and refuses to start again
   until you reboot.

**Plan section also shows** (pulled from Ollama's own startup config
line in `journalctl` / `docker compose logs` — see "Reading Ollama's
runtime config" below for why we go through the log instead of an API
endpoint):

- `OLLAMA_NUM_PARALLEL` — hard cap on concurrent requests per loaded
  model. **If your `--concurrency` exceeds this**, the stress test
  warns explicitly and tells you it will be measuring queueing rather
  than GPU parallelism. Bump it via `sudo systemctl edit ollama.service`.
- `OLLAMA_MAX_QUEUE`, `KEEP_ALIVE`, `FLASH_ATTENTION`, `KV_CACHE_TYPE`,
  `NEW_ENGINE`, `LOAD_TIMEOUT`, `GPU_OVERHEAD` — same source.
- Model on-disk size in GiB (so VRAM peaks have something to scale
  against).

**Recommended invocations**:

```bash
# Default plan: largest installed model, num_ctx = model max,
# concurrency = 4, requests = 8, prompt at 50% of num_ctx.
./scripts/log-run.sh -- ./scripts/stress-test.sh

# Small / fast smoke test (good for "is the GPU still working?"):
./scripts/log-run.sh -- ./scripts/stress-test.sh \
    --model llama3.2:latest --num-ctx 32768 --concurrency 2 --requests 4

# See the plan without actually firing requests:
./scripts/stress-test.sh --dry-run
```

**Output**: real-time per-request timing + a final summary block, plus
one machine-readable line `STRESS_RESULT_JSON: { ... }` that
`log-run.sh` lifts into the JSONL history.

> Run *after* a fresh reboot for the cleanest baseline. Running it on a
> GPU that's already shown MES errors will most likely make things
> worse, not better.

---

## `log-run.sh`

Generic wrapper that runs any other script and appends a single-line
JSONL record to `logs/run-history.jsonl`. Each record contains:

- `kind` (`validate` / `stress` / `other`), `started_at`, `elapsed_sec`,
  `command`, optional `label`
- `snapshot.{kernel,linux_firmware,mes_fw,rocm,ollama,gpu,gpu_arch,vram_total_gib,runtime_mode}`
  — captured from `lib/snapshot.sh` AFTER the wrapped command runs
- For `validate`: per-layer `[{layer,status,msg}]` plus
  `summary.{passed,failed,skipped,exit_code}`
- For `stress`: the full `STRESS_RESULT_JSON` block + `summary.exit_code`
- `mes_dmesg_count`: count of MES error lines in `dmesg` at record time

**Why a wrapper instead of editing `validate.sh` directly?** So we
never modify `validate.sh` while it's running (the file-rewrite race
that wedged Layer 8 in an earlier session is now a class of bug we
avoid by construction). The wrapper is parsed once at start and never
re-read.

```bash
# Wrap a normal validate run:
sudo ./scripts/log-run.sh -- ./scripts/validate.sh --skip-long-ctx

# Tag a run with context (great for "did the new BIOS help?"):
sudo ./scripts/log-run.sh --label="bios-1.0.7" -- ./scripts/validate.sh

# Show recent entries (jq makes this much nicer):
./scripts/log-run.sh show --last 5
./scripts/log-run.sh show --kind=stress --last 3

# Diff two runs by index (0 = newest):
./scripts/log-run.sh diff 0 1
```

The log file is plain JSONL — `jq`, `python3 -m json.tool`, and any
log-shipping tool will handle it. Safe to delete to reset history.

---

## `install-mes-firmware.sh`

Single-command fix for the MES `0x83` firmware regression in Ubuntu's
`linux-firmware` package. Without this fix, every GPU compute kernel on
Strix Halo page-faults with `[gfxhub] page fault ... CPF (0x4)
WALKER_ERROR=1 MAPPING_ERROR=1` and Ollama silently runs on CPU.

### Detection

```bash
./scripts/install-mes-firmware.sh --check
```

Sample output (this box, after the fix):

```
Current state
  kernel:         6.14.0-1018-oem
  linux-firmware: 20240318.git3b128b60-0ubuntu2.26
  override dir:   /lib/firmware/updates/amdgpu
    files installed: 7 / 7
  [ OK ] MES firmware running: 0x0000007c (< 0x83, safe)
  [ OK ] override is embedded in current initramfs (...)
  [ OK ] PASS: running MES firmware is 0x0000007c (< 0x83)
```

Sample output on a broken Ubuntu install (the default state right after
`apt install linux-firmware`):

```
  override dir:   /lib/firmware/updates/amdgpu
    files installed: 0 / 7
  [FAIL] MES firmware running: 0x00000083 (the BROKEN 0x83 regression)
  FAIL: running MES firmware is 0x00000083 - apply the fix:
      sudo /opt/github/MaxusAI/amd-rocm-ollama/scripts/install-mes-firmware.sh
```

`--check` exits `0` (PASS), `3` (FAIL — needs fix), or `1` (script error).

### Apply the fix

```bash
sudo ./scripts/install-mes-firmware.sh
sudo reboot
# after reboot:
./scripts/install-mes-firmware.sh --check    # expect: PASS
```

The full procedure the script automates (you can do this by hand if you
prefer):

1. **Download** `gc_11_5_1_*.bin` from upstream `linux-firmware` git
   commit [`e2c1b15108…`](https://gitlab.com/kernel-firmware/linux-firmware/-/tree/e2c1b151087b2983249e106868877bd19761b976/amdgpu)
   (2025-07-16, last commit before the `0x83` regression). Files:
   - `gc_11_5_1_imu.bin`
   - `gc_11_5_1_me.bin`
   - `gc_11_5_1_mec.bin`
   - `gc_11_5_1_mes1.bin`
   - **`gc_11_5_1_mes_2.bin`** ← the critical MES blob
   - `gc_11_5_1_pfp.bin`
   - `gc_11_5_1_rlc.bin`
2. **Compress** each to `.bin.zst` (modern Ubuntu kernels prefer the
   compressed form). The script uses `zstd --quiet --keep`.
3. **Verify md5** against the known-good values baked into the script
   (catches partial downloads or upstream tampering).
4. **Install** to `/lib/firmware/updates/amdgpu/` with `0644` perms.
   This directory has precedence over `/lib/firmware/amdgpu/` and is
   left alone by `apt upgrade linux-firmware`.
5. **Rebuild initramfs** for the running kernel
   (`update-initramfs -u -k "$(uname -r)"`) so the override is loaded
   at very early boot, before `amdgpu` initializes.
6. **Reboot.** The override is loaded; MES reports `0x80` (or `0x7c`
   from the older commit we use); Layer 2 of the validator passes.

### Other useful invocations

```bash
sudo ./scripts/install-mes-firmware.sh --no-initramfs
# Install blobs but skip update-initramfs (you'll do it yourself).

sudo ./scripts/install-mes-firmware.sh --commit <SHA>
# Use a different upstream commit. Note: this disables md5 verification
# for any unknown file, so you accept the upstream tarball as-is.

sudo ./scripts/install-mes-firmware.sh --uninstall
# Remove the overrides and rebuild initramfs. Reboot to load Ubuntu's
# stock blobs again (will re-introduce the 0x83 bug if it's still in
# the package).
```

### When does the regression come back?

| Event                                           | Override survives?    |
| ----------------------------------------------- | --------------------- |
| `apt upgrade linux-firmware`                    | yes (different dir)   |
| `apt upgrade` to a newer kernel                 | yes, but new kernel's initramfs doesn't have it - run `sudo update-initramfs -u -k <new-kver>` |
| `apt install amdgpu-dkms`                       | yes (DKMS doesn't touch `gc_11_5_1`) |
| `dpkg-reconfigure linux-firmware`               | yes                   |
| Manual `rm /lib/firmware/updates/amdgpu/gc_*`   | no (obviously)        |
| Upstream `linux-firmware` adds a `gc_11_5_1_*.bin.zst` to the same `updates/` dir in a future package version | possibly — re-run `--check` after each upgrade |

The `make mes-check` target is fast (under 1 s) and safe to add to a
post-update hook or a periodic cron.

---

## `validate.sh`

The 9-layer validation ladder from
[`docs/validation-tests.md`](../docs/validation-tests.md), as a runnable
script. Each layer prints `[PASS]` / `[FAIL]` / `[SKIP]`; a failure
auto-skips dependent layers and the script exits non-zero with a hint
about how to fix the failure.

### Common invocations

```bash
./scripts/validate.sh                  # all layers (Layer 8 takes 4-25 min)
./scripts/validate.sh --skip-long-ctx  # everything except Layer 8 (fast: ~30 s)
./scripts/validate.sh --layer 1        # only check MES firmware version
./scripts/validate.sh --layer 8        # only run the long-context test
./scripts/validate.sh --from 4         # Layer 4 onwards (skip host-side checks)
./scripts/validate.sh --mode host      # validate the host-installed Ollama
./scripts/validate.sh --mode container # validate the docker compose Ollama
./scripts/validate.sh --mode auto      # default: prefer container, fall back to host
./scripts/validate.sh --help
```

### Host vs container mode

The validator works against either an Ollama install on the **host** (e.g.
`apt install ollama` + systemd) or the **docker compose container** built
by this repo. Mode selection:

| `--mode`    | Behaviour                                                                           |
| ----------- | ----------------------------------------------------------------------------------- |
| `auto`      | Default. Picks `container` if `docker compose ps ollama` shows a running container; otherwise falls back to `host`. |
| `container` | Forces docker mode. Layer 3 checks the image; Layer 4 checks compose health; Layer 5 reads `docker compose logs`. |
| `host`      | Forces host mode. Layer 3 is skipped; Layer 4 checks `systemctl is-active ollama` + `GET /api/version`; Layer 5 reads `journalctl --unit=ollama` and falls back to `/api/ps` size_vram inspection. |

Layers 0-2 (kernel cmdline, MES firmware, HIP smoke) and Layers 6-8 (HTTP
inference smoke + long-context) are mode-agnostic - they hit the host
kernel or the API on `:HOST_PORT` and don't care which Ollama is serving.

**What Layer 5 will catch in either mode:**

| Verdict             | What it means                                                                            |
| ------------------- | ---------------------------------------------------------------------------------------- |
| `PASS_ROCM_GFX1151` | The goal: `library=ROCm compute=gfx1151`                                                 |
| `PASS_ROCM_OTHER`   | ROCm but a different gfx target (still GPU; unusual for this hardware)                   |
| `FAIL_CPU`          | Silent fallback to `library=cpu` - GPU init failed (almost always MES `0x83` regression) |
| `FAIL_VULKAN`       | `library=Vulkan` - Ollama was built with Vulkan support, not ROCm. Wrong build for this stack. |
| `FAIL_OTHER_LIB`    | `library=cuda/oneapi/metal` - completely wrong build                                     |

> **Note on dual host+container conflicts.** If both the host
> `ollama.service` and the compose `ollama-rocm` container are configured
> to bind `0.0.0.0:11434`, only one will start. Stop one before
> validating: `sudo systemctl stop ollama` (host) or `make down`
> (container). With `--mode auto` the validator will pick whichever is
> actually serving on the port.

> **Host-mode Layer 5 failure -> almost always Fix 4 (MES firmware).**
> When the host's `rocm/` runner faults during init, Ollama's
> auto-selector silently falls back to Vulkan or CPU. So `make
> validate --mode host` may report `FAIL_VULKAN` or `FAIL_CPU` when
> the actual fault is the host kernel/firmware - the MES `0x83`
> regression documented in
> [`../docs/build-fixes.md` Fix 4](../docs/build-fixes.md#fix-4-mes-0x83-firmware-regression-the-actual-root-cause-of-the-page-fault).
> The Layer 5 hint block recommends `make mes-check` first.
>
> **No GPU env vars or `User=root` needed.** Ollama 0.21.0 prefers
> ROCm over Vulkan on its own when the `rocm/` runner is healthy.
> Earlier versions of these notes recommended (a) switching to
> `User=root` and (b) setting `OLLAMA_ROCM=1` / `GGML_USE_ROCM=1` /
> `*_VISIBLE_DEVICES`. **Both have been retracted** after controlled
> A/B tests on the box this stack was developed on showed neither
> makes any difference. The minimal sustainable systemd override is:
>
> ```ini
> [Service]
> Environment="OLLAMA_HOST=0.0.0.0:11434"      # bind LAN, not just localhost
> Environment="OLLAMA_DEBUG=2"                 # for the validator + journalctl debugging
> Environment="OLLAMA_MODELS=/usr/share/ollama/.ollama/models"
> ```
>
> See
> [`../docs/build-fixes.md` Fix 5 -> "What we got wrong"](../docs/build-fixes.md#what-we-got-wrong)
> for the audit trail.
>
> The `/proc/<pid>/environ` and `/proc/<pid>/status` reads need a
> sudo-cached credential - if you haven't run `sudo -v` recently, the
> hint will print `(run 'sudo -v' first to read)` next to the
> ungatherable lines. That's a soft warning, not a failure.

Exit codes:

| Code | Meaning                                                    |
| ---- | ---------------------------------------------------------- |
| 0    | all selected layers passed                                 |
| 1    | one or more layers failed                                  |
| 2    | bad invocation (unknown flag etc.)                         |

### What each layer checks

| Layer | What                                                    | Container mode      | Host mode                | Blocks next? |
| ----- | ------------------------------------------------------- | ------------------- | ------------------------ | ------------ |
| 0     | Host kernel cmdline (no `amd_iommu=off`)                | same                | same                     | informational |
| 1     | Host MES firmware version (must be `< 0x83`)            | same                | same                     | yes - 2..8   |
| 2     | Host HIP smoke test (`hipMemcpy` + kernel launch)       | same                | same                     | informational |
| 3     | `amd-rocm-ollama:7.2.2` image present                   | check               | SKIP                     | yes - 4..8   |
| 4     | Ollama runtime up (+ host: process user/group)          | compose health      | systemctl + `/api/version` + `running as: user/group` | yes - 5..8 |
| 5     | Ollama bootstrap discovery shows `library=ROCm`         | `docker compose logs` | `journalctl` + `/api/ps` size_vram | yes - 6..8 |
| 6     | Small-model inference (default `llama3.2:latest`)       | hits HTTP API       | hits HTTP API            | informational |
| 7     | VRAM total ≥ 50 GiB (256K headroom budget)              | same                | same                     | informational |
| 8     | Long-context inference (~200K tokens, default e4b)      | hits HTTP API       | hits HTTP API            | headline     |

### Tunables (env vars)

```bash
HOST_PORT=11434                ./scripts/validate.sh
COMPOSE_SERVICE=ollama         ./scripts/validate.sh   # docker compose service name
COMPOSE_FILE=./docker-compose.yml ./scripts/validate.sh
IMAGE_TAG=amd-rocm-ollama:7.2.2   ./scripts/validate.sh --layer 3
SMOKE_MODEL=gemma4:e4b-it-q4_K_M  ./scripts/validate.sh --layer 6
LONG_CTX_MODEL=gemma4:31b-it-q4_K_M LONG_CTX_TOKENS=200000 ./scripts/validate.sh --layer 8
DRI_INDEX=1                    ./scripts/validate.sh --layer 1   # which /sys/kernel/debug/dri/N/
MODE=auto                      ./scripts/validate.sh   # auto|container|host (same as --mode)
```

`SERVICE` is still accepted as an alias for `COMPOSE_SERVICE` for
backward compatibility.

### Sample run (everything healthy on this box)

```text
$ ./scripts/validate.sh --skip-long-ctx
amd-rocm-ollama validation ladder
  repo:       /opt/github/MaxusAI/amd-rocm-ollama
  port:       11434
  service:    ollama

===== Layer 0: Host kernel cmdline (no amd_iommu=off) =====
  cmdline: BOOT_IMAGE=/boot/vmlinuz-6.14.0-1018-oem ro quiet splash thunderbolt.host_reset=0 amd_iommu=on iommu=pt amdgpu.cwsr_enable=1 ttm.pages_limit=25165824 vt.handoff=7
  [PASS] no amd_iommu=off; iommu state OK

===== Layer 1: Host MES firmware version (the gate) =====
  MES feature version: 1, firmware version: 0x0000007c
  [PASS] MES firmware version 0x0000007c (< 0x83) is safe

===== Layer 2: Host HIP smoke test (hipMemcpy + kernel launch) =====
  compiling /tmp/hip-kernel-validate.cpp for gfx1151...
  running /tmp/hip-kernel-validate...
  output: out=12345
  [PASS] HIP kernel returned out=12345

===== Layer 3: Container image built =====
  [PASS] amd-rocm-ollama:7.2.2 image present (22.1 GB)

===== Layer 4: Container running and healthy =====
  status: Up 41 minutes (healthy)
  [PASS] container is up and healthy

===== Layer 5: Ollama GPU discovery (library=ROCm, not cpu) =====
  ... msg="inference compute" id=0 library=ROCm compute=gfx1151 ... total="192.0 GiB"
  [PASS] library=ROCm + compute=gfx1151

===== Layer 6: Small-model inference smoke test (llama3.2:latest) =====
  content: Hello there friend!
  decode rate: 103.0 tok/s
  [PASS] small-model generated non-empty text (103.0 tok/s)

===== Layer 7: VRAM headroom for 256K context (informational) =====
  VRAM total=96.0 GiB  free=95.6 GiB
  [PASS] VRAM total 96.0 GiB is sufficient for 256K context

===== Layer 8: Long-context inference =====
  [SKIP] skipped via --skip-long-ctx

===== summary =====
  7 passed  0 failed  1 skipped
```

### Sample run with the firmware bug present (what to look for)

```text
===== Layer 1: Host MES firmware version (the gate) =====
  MES feature version: 1, firmware version: 0x00000083
  [FAIL] MES firmware version is 0x00000083 (BROKEN; the 0x83 regression)
         Run scripts/install-mes-firmware.sh as root, then sudo update-initramfs -u -k $(uname -r) && reboot

===== Layer 2: Host HIP smoke test (hipMemcpy + kernel launch) =====
  [SKIP] Layer 1 (MES firmware) failed; HIP test will fault the same way

... layers 3..8 skip ...

  4 passed  1 failed  4 skipped
Validation FAILED. See docs/validation-tests.md for the per-layer fix.
```

---

## Adding the validator to CI / cron

Both scripts are designed to be safe to run repeatedly and have
machine-friendly exit codes. Examples:

```bash
# Post-apt-upgrade hook (drop into /etc/apt/apt.conf.d/99-mes-check):
DPkg::Post-Invoke { "/opt/github/MaxusAI/amd-rocm-ollama/scripts/install-mes-firmware.sh --check >/dev/null 2>&1 || logger -t mes-check 'MES firmware regressed - re-run install-mes-firmware.sh'"; };

# Daily systemd timer (rough):
ExecStart=/opt/github/MaxusAI/amd-rocm-ollama/scripts/validate.sh --skip-long-ctx
```

Be aware that Layer 2 compiles a tiny HIP program at every run (~3 s);
Layer 6 requires the small smoke model to be present in the model store;
Layer 8 takes 4-25 minutes depending on the model size.

---

## Reading Ollama's runtime config (why the log scan?)

`validate.sh` Layer 4 and `stress-test.sh`'s plan section both display
the daemon's effective config — `OLLAMA_NUM_PARALLEL`, `MAX_QUEUE`,
`KEEP_ALIVE`, `FLASH_ATTENTION`, `KV_CACHE_TYPE`, `NEW_ENGINE`,
`LOAD_TIMEOUT`, `GPU_OVERHEAD`. These determine how much concurrent
load Ollama will accept, but they are surprisingly hard to obtain:

| Source                       | What you get                                       |
| ---------------------------- | -------------------------------------------------- |
| Ollama HTTP API              | Nothing. `/api/config`, `/api/info`, `/api/server`, `/api/runtime`, `/api/env` all 404 on 0.21.0. |
| `/proc/<pid>/environ`        | Only the **explicitly-set** vars (e.g. `OLLAMA_HOST`, `OLLAMA_DEBUG`). Anything that fell back to a default — including `NUM_PARALLEL=1`, `MAX_QUEUE=512`, `KEEP_ALIVE=5m0s` — is invisible. |
| `journalctl` / `docker logs` | The structured line `msg="server config" env="map[KEY1:VAL1 ...]"` logged once per `ollama serve` boot. **Has everything**, including defaults. |

`lib/snapshot.sh` parses that log line with a small bracket-balancing
walker (so `OLLAMA_ORIGINS` with its embedded list-of-URLs survives).
The result is cached to
`$XDG_RUNTIME_DIR/ollama-cfg-<InvocationID>.json`, keyed on the systemd
InvocationID so it auto-invalidates on every Ollama restart and
subsequent calls are instant. The cold-cache scan is timeout-protected
(45 s) because chatty `OLLAMA_DEBUG=2` instances produce huge journals.

**Practical implication for stress testing**: if your `--concurrency`
exceeds `OLLAMA_NUM_PARALLEL`, the stress test is mostly measuring
queue throughput, not GPU parallelism. The plan section warns about
this explicitly and includes the `systemctl edit` snippet to fix it.

---

## Reading Ollama's runtime *state* (the env vars are not the truth)

The daemon-level env vars above describe **intent** — they govern how
Ollama starts up. They do *not* describe what the inner llama.cpp
runner actually decided to do for the model that's currently loaded.
Two of them are routinely misread:

| Env var                  | What you might assume          | What actually happens                                                                                                                                                                          |
| ------------------------ | ------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `OLLAMA_FLASH_ATTENTION` | `false` ⇒ FA is off            | The runner defaults to `flash_attn = auto` and **enables FA at model load** for every supported model on a ROCm/CUDA backend. Look for `Flash Attention was auto, set to enabled` in the log. |
| `OLLAMA_KV_CACHE_TYPE`   | `q8_0` ⇒ KV cache is quantized | The Ollama daemon **gates KV quantization on `OLLAMA_FLASH_ATTENTION=1`** (the env var, not the runner's auto-decision). With `OLLAMA_FLASH_ATTENTION=false`, `OLLAMA_KV_CACHE_TYPE=q8_0` is silently ignored and the runner allocates `K(f16) + V(f16)` — twice the VRAM. |

To see the truth, both `validate.sh` (Layer 4) and `stress-test.sh`
(Summary block) now also surface the runtime state from the most
recent model load:

```text
ollama runtime state (what the runner ACTUALLY did at last model load):
  library / compute    = ROCm / gfx1151
  last model loaded    = sha256-dde5aa3
  flash attention      = enabled    (runner saw: requested=auto)
  kv cache             = 14336 MiB total  K(f16) + V(f16) over 28 layers, 131072 cells
  compute buffers      = 408 MiB device + 262 MiB host pinned
  DRIFT: OLLAMA_KV_CACHE_TYPE=q8_0 is IGNORED because OLLAMA_FLASH_ATTENTION=false.
    Ollama gates KV quantization on the env var (the runner auto-enabling FA does not count).
    Add  Environment=OLLAMA_FLASH_ATTENTION=1  to the systemd override and restart ollama.
```

The data is extracted from a small set of marker lines in the journal:

```text
... msg="inference compute" id=0 library=ROCm compute=gfx1151 name=ROCm0 ...
... msg="starting runner" cmd="/usr/local/bin/ollama runner --model PATH ..."
llama_context: flash_attn    = auto
llama_kv_cache: size = 14336.00 MiB (131072 cells, 28 layers, 1/1 seqs), K (f16): 7168.00 MiB, V (f16): 7168.00 MiB
llama_context: Flash Attention was auto, set to enabled
llama_context:      ROCm0 compute buffer size =   408.01 MiB
llama_context:  ROCm_Host compute buffer size =   262.01 MiB
```

These are per-model-load, so the block is empty until any
`/api/generate` request loads a model. If the block reads
`(no model loaded since last restart -- send any /api/generate
request to populate runner-level info)`, just fire one quick
generate and rerun the validator.

### Gotcha: zombie `curl` clients hold ref-counts open

If you cancel `stress-test.sh` or `torture.sh` mid-run (Ctrl-C, or by
backgrounding them in the IDE and never collecting them), the `curl`
processes those scripts spawned to talk to `/api/generate` may keep
running. From Ollama's scheduler point of view, **those are still
in-flight requests**, and the runner they're attached to keeps a
non-zero ref-count. That manifests as:

- `/api/ps` keeps showing the model as loaded long after you
  thought the test ended.
- Loading any other model that needs to evict this one
  **hangs indefinitely** with no clean error - eventually the new
  request's curl times out with an empty body. The journal shows:
  ```text
  sched.go:265 msg="waiting for pending requests to complete and unload to occur"
                                                                    refCount=2
  ```
- Subsequent stress/torture runs against the same model run with
  unexpectedly low parallelism (the orphaned curls take slots).

The fix is mechanical:

```bash
pgrep --list-full --full 'curl.*api/generate'
sudo pkill --signal=KILL --full 'curl.*api/generate'
```

This is documented as Mode 3 in
[`../docs/break-modes.md`](../docs/break-modes.md#mode-3-eviction-deadlock-when-ref-counts-wont-drop).

---

**To fully enable q8_0 KV cache** (the recommended config for fitting
≥128K context on the 96 GiB iGPU split), the systemd override needs
both:

```ini
[Service]
Environment="OLLAMA_FLASH_ATTENTION=1"
Environment="OLLAMA_KV_CACHE_TYPE=q8_0"
```

Then `sudo systemctl daemon-reload && sudo systemctl restart ollama`
and reload any currently-loaded model (per-model-load decision).
After that, `validate.sh` Layer 4 should report
`kv cache = ... K(q8_0) + V(q8_0) ...` and the DRIFT line will
disappear.
