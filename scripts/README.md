# scripts/

Operational scripts for the `amd-rocm-ollama` stack on AMD Strix Halo
(`gfx1151`).

| Script                                                 | Run as | What it does                                                                |
| ------------------------------------------------------ | ------ | --------------------------------------------------------------------------- |
| [`install-mes-firmware.sh`](install-mes-firmware.sh)   | root   | Replace Ubuntu's broken MES `0x83` firmware with a pre-regression blob      |
| [`validate.sh`](validate.sh)                           | user   | Walk the 9-layer validation ladder from `docs/validation-tests.md`          |
| [`stress-test.sh`](stress-test.sh)                     | user   | VRAM/GTT/MES stress: largest installed model, parallel reqs at full context |
| [`torture.sh`](torture.sh)                             | user   | Escalating ladder of stress configs — finds the actual breakage threshold  |
| [`log-run.sh`](log-run.sh)                             | user   | Wrap any of the above + append a timestamped JSONL record to `logs/run-history.jsonl` |
| [`hip-kernel-test.cpp`](hip-kernel-test.cpp)           | n/a    | C++ source for Layer 2's host HIP smoke test (compiled by `validate.sh`)    |
| [`lib/`](lib/)                                         | n/a    | Sourceable bash helpers (`api.sh`, `dmesg.sh`, `pretty.sh`, `snapshot.sh`) + Python parsers (`parse_*.py`) |

> **Don't invoke via `sh` / `sudo sh`.** Run scripts directly so the
> `#!/usr/bin/env bash` shebang is honoured (`./scripts/foo.sh` or
> `sudo ./scripts/foo.sh` for the firmware installer). All scripts also
> self-promote to bash if you do, but it's cleaner not to. `validate.sh`
> does *not* need root — it uses `sudo --non-interactive` for the two
> checks that do (debugfs read + `rocm-smi`); run `sudo -v` once first
> if you don't want password prompts mid-run.

All are also wired into the top-level [`Makefile`](../Makefile):

```bash
make install-mes-firmware    # sudo wrapper around install-mes-firmware.sh
make mes-check               # quick: install-mes-firmware.sh --check
make validate                # validate.sh --skip-long-ctx (fast)
make validate-full           # validate.sh end-to-end including 200K context
make validate-logged         # validate-full + JSONL record
make stress-test             # full stress: largest model, full ctx, ~30 min, logged
make stress-test-quick       # smaller model + 32K ctx, concurrency=2 (~5 min, logged)
make run-history             # show last 10 entries from logs/run-history.jsonl
```

Every script supports `--help` for the full flag reference; the sections
below describe only what isn't obvious from `--help` and what each
script is for.

---

## `install-mes-firmware.sh`

Single-command fix for the MES `0x83` firmware regression in Ubuntu's
`linux-firmware` package. Without this fix, every GPU compute kernel
on Strix Halo page-faults with `[gfxhub] page fault … CPF (0x4)
WALKER_ERROR=1 MAPPING_ERROR=1` and Ollama silently runs on CPU.

```bash
./scripts/install-mes-firmware.sh --check       # exit 0 = PASS, 3 = FAIL (needs fix)
sudo ./scripts/install-mes-firmware.sh          # apply
sudo reboot
./scripts/install-mes-firmware.sh --check       # verify
```

What it does, automated: download `gc_11_5_1_*.bin` from upstream
`linux-firmware` git commit
[`e2c1b15108…`](https://gitlab.com/kernel-firmware/linux-firmware/-/tree/e2c1b151087b2983249e106868877bd19761b976/amdgpu)
(2025-07-16, last commit before the regression), `zstd`-compress, md5-
verify against the values baked into the script, install to
`/lib/firmware/updates/amdgpu/` (precedence over the package dir,
survives `apt upgrade linux-firmware`), and `update-initramfs -u -k
"$(uname -r)"`. Idempotent — safe to re-run.

Other useful flags: `--no-initramfs`, `--commit <SHA>` (different
upstream commit; disables md5 verification), `--uninstall`,
`--list-known` (community-tested MES versions). Run with `--help` for
the full set. Diagnostic story:
[`../docs/build-fixes.md` Fix 4](../docs/build-fixes.md#fix-4-mes-0x83-firmware-regression-the-actual-root-cause-of-the-page-fault).

### When does the regression come back?

| Event                                           | Override survives?    |
| ----------------------------------------------- | --------------------- |
| `apt upgrade linux-firmware`                    | yes (different dir)   |
| `apt upgrade` to a newer kernel                 | yes, but new kernel's initramfs needs rebuilding: `sudo update-initramfs -u -k <new-kver>` |
| `apt install amdgpu-dkms`                       | yes (DKMS doesn't touch `gc_11_5_1`) |
| Manual `rm /lib/firmware/updates/amdgpu/gc_*`   | no                    |

`make mes-check` is fast (under 1 s) and safe to drop into a post-
update apt hook or a periodic cron.

---

## `validate.sh`

The 9-layer validation ladder from
[`../docs/validation-tests.md`](../docs/validation-tests.md), as a
runnable script. Each layer prints `[PASS]` / `[FAIL]` / `[SKIP]`; a
failure auto-skips dependent layers. Exit codes: `0` all PASS, `1` one
or more FAIL, `2` bad invocation.

Sample outputs (success and failure) are in
[`../docs/validation-tests.md`](../docs/validation-tests.md). This
section documents only the script-specific behaviour.

### Mode selection (host vs container)

| `--mode`    | Behaviour                                                                           |
| ----------- | ----------------------------------------------------------------------------------- |
| `auto`      | Default. Picks `container` if `docker compose ps ollama` shows it running; otherwise falls back to `host`. |
| `container` | Force docker mode. Layer 3 checks the image; Layer 4 checks compose health; Layer 5 reads `docker compose logs`. |
| `host`      | Force host mode. Layer 3 is skipped; Layer 4 checks `systemctl is-active ollama` + `/api/version`; Layer 5 reads `journalctl --unit=ollama` + `/api/ps` size_vram. |

Layers 0-2 (kernel cmdline, MES firmware, HIP smoke) and Layers 6-8
(HTTP inference + long context) are mode-agnostic — they hit the host
kernel or `:HOST_PORT` directly.

### Layer 5 verdicts

| Verdict             | Meaning                                                                                  |
| ------------------- | ---------------------------------------------------------------------------------------- |
| `PASS_ROCM_GFX1151` | The goal: `library=ROCm compute=gfx1151`                                                 |
| `PASS_ROCM_OTHER`   | ROCm but a different gfx target (still GPU; unusual for this hardware)                   |
| `FAIL_CPU`          | Silent fallback to `library=cpu` — almost always the MES `0x83` regression               |
| `FAIL_VULKAN`       | `library=Vulkan` — wrong build for this stack                                            |
| `FAIL_OTHER_LIB`    | `library=cuda/oneapi/metal` — completely wrong build                                     |

> **Host-mode `FAIL_CPU` / `FAIL_VULKAN` is almost always Fix 4 (MES
> firmware), not a backend-selection bug.** When the `rocm/` runner
> can't initialise, Ollama silently falls back. The Layer 5 hint
> recommends `make mes-check` first. No GPU env vars or `User=root`
> are needed; the minimal sustainable systemd override is purely
> operational. Full audit (including two retracted theories):
> [`../docs/build-fixes.md` Fix 5](../docs/build-fixes.md#fix-5-minimal-systemd-override-for-the-host-install-and-what-wasnt-actually-needed).

### Tunables (env vars)

```bash
HOST_PORT=11434                     # API port to probe
COMPOSE_SERVICE=ollama              # docker compose service name (alias: SERVICE)
COMPOSE_FILE=./docker-compose.yml
IMAGE_TAG=amd-rocm-ollama:7.2.2     # Layer 3 image tag
SMOKE_MODEL=gemma4:e4b-it-q4_K_M    # Layer 6 model
LONG_CTX_MODEL=...  LONG_CTX_TOKENS=200000   # Layer 8
DRI_INDEX=1                         # which /sys/kernel/debug/dri/N/
MODE=auto                           # auto|container|host (alias for --mode)
```

> **Dual host+container conflict.** If both the host `ollama.service`
> and the compose container bind `0.0.0.0:11434`, only one starts.
> Stop one before validating: `sudo systemctl stop ollama` (host) or
> `make down` (container). With `--mode auto` the validator picks
> whichever is actually serving on the port.

---

## `stress-test.sh`

Pushes the GPU as hard as possible without being malicious: discovers
the largest installed Ollama model, opens N parallel `/api/generate`
requests at the model's max `num_ctx`, and watches `rocm-smi` +
`dmesg` for distress signals while they run.

```bash
./scripts/log-run.sh -- ./scripts/stress-test.sh        # default plan, logged
./scripts/stress-test.sh --dry-run                      # show plan, no requests
./scripts/stress-test.sh --help                         # all flags
```

What it surfaces, in increasing severity: (1) request timeouts/5xx
(throughput problem); (2) new `MES failed to respond` lines in dmesg
during the run (kernel-side Mode A regression); (3) new `MES ring
buffer is full` lines (Mode B — **GPU wedged until reboot**, script
exits non-zero and refuses to start again).

The plan section also displays Ollama's effective config
(`OLLAMA_NUM_PARALLEL`, `MAX_QUEUE`, `KEEP_ALIVE`, `FLASH_ATTENTION`,
`KV_CACHE_TYPE`, etc.) parsed from the `server config` log line. **If
your `--concurrency` exceeds `OLLAMA_NUM_PARALLEL`, the script warns
explicitly** that it will be measuring queueing rather than GPU
parallelism. Bump it via `sudo systemctl edit ollama.service`.

Output: real-time per-request timing + a final summary block + one
machine-readable line `STRESS_RESULT_JSON: { ... }` that `log-run.sh`
lifts into the JSONL history.

> Run *after* a fresh reboot for the cleanest baseline. Running it on
> a GPU that's already shown MES errors will most likely make things
> worse, not better.

---

## `log-run.sh`

Generic wrapper that runs any other script and appends a single-line
JSONL record to `logs/run-history.jsonl`. Each record has versions
(kernel, `linux-firmware`, MES firmware, ROCm, Ollama, GPU, runtime
mode), wall-time, command, optional `--label`, per-layer / per-stress
result, and `mes_dmesg_count` at record time.

```bash
sudo ./scripts/log-run.sh -- ./scripts/validate.sh --skip-long-ctx
sudo ./scripts/log-run.sh --label="bios-1.0.7" -- ./scripts/validate.sh
./scripts/log-run.sh show --last 5
./scripts/log-run.sh show --kind=stress --last 3
./scripts/log-run.sh diff 0 1            # newest vs second-newest
./scripts/log-run.sh --help
```

Why a wrapper instead of editing `validate.sh` directly: so we never
modify `validate.sh` while it's running (the file-rewrite race that
wedged Layer 8 in an earlier session is a class of bug we avoid by
construction). The log file is plain JSONL — `jq`, `python3 -m
json.tool`, and any log-shipping tool will handle it. Safe to delete
to reset history.

---

## Reading Ollama's runtime config & state

Two related sources of truth that are surprisingly hard to obtain
because Ollama exposes neither via HTTP API:

- **Daemon config** (`OLLAMA_NUM_PARALLEL`, `MAX_QUEUE`, `KEEP_ALIVE`,
  `FLASH_ATTENTION`, `KV_CACHE_TYPE`, …) — extracted from the `msg=
  "server config" env="map[…]"` line that `ollama serve` logs once at
  boot. `lib/snapshot.sh` parses it with a bracket-balancing walker
  (so `OLLAMA_ORIGINS` survives) and caches the result keyed on
  systemd InvocationID. Surfaced by `validate.sh` Layer 4 and the
  `stress-test.sh` plan section.

- **Runner state** (the actual decisions `llama.cpp` made for the
  currently-loaded model: flash-attn enabled? KV cache type and size?
  compute buffers?) — extracted from per-load runner log lines.
  Surfaced by `validate.sh` Layer 4 and the `stress-test.sh` summary.

The runner-state block also detects a frequent **drift**: setting
`OLLAMA_KV_CACHE_TYPE=q8_0` is silently ignored unless
`OLLAMA_FLASH_ATTENTION=1` is *also* set in the daemon env (the
runner auto-enabling FA does not count). Layer 4 calls this out and
prints the systemd snippet to fix it.

Implementation notes (regexes, Python parsers, cache invalidation,
why we go through the journal instead of an API endpoint) are in
[`lib/snapshot.sh`](lib/snapshot.sh) and the two extracted parsers
[`lib/parse_server_config.py`](lib/parse_server_config.py) /
[`lib/parse_runtime_state.py`](lib/parse_runtime_state.py).

### Gotcha: zombie `curl` clients hold ref-counts open

If you cancel `stress-test.sh` or `torture.sh` mid-run, the `curl`
processes they spawned to talk to `/api/generate` may keep running.
From Ollama's scheduler point of view those are still in-flight
requests — `/api/ps` keeps showing the model as loaded, evictions
hang indefinitely with `refCount=2`, and subsequent runs see
unexpectedly low parallelism. Fix:

```bash
sudo pkill --signal=KILL --full 'curl.*api/generate'
```

Documented as Mode 3 in
[`../docs/break-modes.md`](../docs/break-modes.md#mode-3-eviction-deadlock-when-ref-counts-wont-drop).

---

## CI / cron

All scripts are safe to run repeatedly with machine-friendly exit
codes. Examples:

```bash
# /etc/apt/apt.conf.d/99-mes-check
DPkg::Post-Invoke { "/opt/github/MaxusAI/amd-rocm-ollama/scripts/install-mes-firmware.sh --check >/dev/null 2>&1 || logger -t mes-check 'MES firmware regressed - re-run install-mes-firmware.sh'"; };

# Daily systemd timer
ExecStart=/opt/github/MaxusAI/amd-rocm-ollama/scripts/validate.sh --skip-long-ctx
```

Layer 2 compiles a tiny HIP program at every run (~3 s); Layer 6
needs the small smoke model present in the model store; Layer 8 takes
4-25 minutes depending on model size.
