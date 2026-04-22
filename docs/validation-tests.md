# Validation tests & requirements

End-to-end test ladder for `amd-rocm-ollama` on AMD Strix Halo (`gfx1151`).
Each layer is a hard requirement for the layer above it — **if a test fails,
fix that layer before continuing**. The whole stack is deemed working when
Layer 8 passes.

> **Just want to run all of this?** The whole ladder is automated in
> [`../scripts/validate.sh`](../scripts/validate.sh):
>
> ```bash
> make validate          # all layers except the slow Layer 8 (~30 s)
> make validate-full     # everything including 200K-token prefill (4-25 min)
> ./scripts/validate.sh --layer 1   # just check MES firmware
> ./scripts/validate.sh --help      # see all options
> ```
>
> The hand-written prose below documents what each layer does and why,
> and what to fix when one fails. The script implements the same checks.

| Layer | What it proves                          | Time   | Blocker if it fails                                   |
| ----- | --------------------------------------- | ------ | ----------------------------------------------------- |
| 0     | Host kernel cmdline sane                | 1 s    | Host can't reach the iGPU at all                      |
| 1     | Host MES firmware **not 0x83**          | 1 s    | Every GPU compute kernel will page-fault              |
| 2     | Host HIP smoke test (`hipMemcpy`)       | 5 s    | ROCm runtime is broken on this host                   |
| 3     | Container builds                        | 10-25 m| Anything below this assumes the image exists          |
| 4     | Container runs and is healthy           | 10 s   | Compose, devices, group ids, port binding             |
| 5     | Ollama bootstrap discovery sees the GPU | 5 s    | Container saw `library=ROCm`, not silent CPU fallback |
| 6     | Small inference (`llama3.2`)            | 5 s    | End-to-end token generation                           |
| 7     | Memory math at 256K                     | 1 s    | Confirms VRAM headroom for the target context         |
| 8     | Long-context inference (~`LONG_CTX_TOKENS` char budget, default 200K) | 4-25 m | Pass = HTTP OK + positive `prompt_eval_count` (actual tokens depend on model caps; model auto-resolves to largest installed >=128K-ctx if `LONG_CTX_MODEL` not pulled) |

Numbers in this doc were captured on:

```
host:           AMD Ryzen AI MAX+ 395 / Radeon 8060S (gfx1151), 128 GiB UMA (96 GPU / 31 sys)
kernel:         6.14.0-1018-oem
linux-firmware: 20240318.git3b128b60-0ubuntu2.26  (the broken stock package; see Layer 1)
ROCm (host):    7.2.1
image:          amd-rocm-ollama:7.2.2  (rocm/dev-ubuntu-24.04:7.2.2-complete + ollama v0.21.0)
```

Cross-references:

- Build failures and their fixes: [`build-fixes.md`](build-fixes.md)
- rocBLAS prune details: [`rocblas-prune.md`](rocblas-prune.md)
- User-facing setup: [`../README.md`](../README.md)

---

## Layer 0 — Host kernel cmdline

**Requirement.** No `amd_iommu=off`, and `amdgpu.cwsr_enable` either unset or `=1`.

```bash
cat /proc/cmdline | tr ' ' '\n' | grep --extended-regexp 'iommu|amdgpu|ttm'
```

Expected (recommended baseline; the only hard rule is "no `amd_iommu=off`"):

```
amd_iommu=on
iommu=pt
amdgpu.cwsr_enable=1
ttm.pages_limit=25165824
```

**Why it matters.** With `amd_iommu=off` the iGPU's GTT can still allocate
host pages but the GPU's page-table walker can't translate them, so
`hipMemcpy` H2D faults at the first byte. This was a false trail in our
debugging — the *real* root cause turned out to be Layer 1 — but
`amd_iommu=on iommu=pt` is still the correct baseline for compute on a UMA
APU and removes one variable from the diagnostic surface. See
[`build-fixes.md` Fix 3](build-fixes.md#fix-3-iommu-baseline-not-the-actual-page-fault-fix)
for the full story.

**If it fails.** Edit `/etc/default/grub`, `sudo update-grub`, reboot.

---

## Layer 1 — Host MES firmware version (the real GPU-fault gate)

**Requirement.** MES firmware version on the running kernel must be
**`0x80` or lower** — `0x83` is the one regressed in current Ubuntu
`linux-firmware` and breaks every compute queue on `gfx1151`.

```bash
sudo cat /sys/kernel/debug/dri/1/amdgpu_firmware_info | grep --extended-regexp 'MES|MEC'
```

Expected (any version `< 0x83` works; this box is running the override):

```
MEC feature version: 35, firmware version: 0x0000001f
MES_KIQ feature version: 6, firmware version: 0x0000006c
MES feature version: 1, firmware version: 0x0000007c
```

**Anti-pattern (what this stock package gives you):**

```
MES feature version: 1, firmware version: 0x00000083    ←  BROKEN, will page-fault
```

**Why it matters.** On `gfx1151` the MES (Micro Engine Scheduler) blob
shipped at version `0x83` mismatches the KFD driver's expectation of the
compute virtual-address layout. Every queue creation succeeds at the API
level, but the very first compute dispatch faults with
`[gfxhub] page fault ... CPF (0x4) WALKER_ERROR=1 MAPPING_ERROR=1`.

**If it fails.** Run the automated installer:

```bash
make install-mes-firmware    # equivalent to: sudo ./scripts/install-mes-firmware.sh
sudo reboot
make mes-check               # equivalent to: ./scripts/install-mes-firmware.sh --check
```

The script downloads the pre-regression `gc_11_5_1_*` blobs from upstream
`linux-firmware` git, verifies their md5 against known-good values,
installs them as `/lib/firmware/updates/amdgpu/` overrides, and rebuilds
the running kernel's initramfs so the override loads at very early boot.
It's idempotent and survives `linux-firmware` package upgrades. See
[`../scripts/README.md`](../scripts/README.md) for the full manual
procedure if you want to do it by hand, or
[`build-fixes.md` Fix 4](build-fixes.md#fix-4-mes-0x83-firmware-regression-the-actual-root-cause-of-the-page-fault)
for the diagnostic story.

Quick spot-check that the override files are in place on this host:

```bash
ls /lib/firmware/updates/amdgpu/gc_11_5_1_*.bin.zst
md5sum /lib/firmware/updates/amdgpu/gc_11_5_1_mes_2.bin.zst
# expect: 01c2a51ea8c226a341dfab50fc41a194
```

---

## Layer 2 — Host HIP smoke test (`hipMemcpy` + kernel launch)

**Requirement.** A trivial HIP program that allocates a device buffer, runs
a kernel that writes a sentinel into it, and copies the result back must
exit `0` and print `out=12345`.

The program is checked into the repo at
[`../scripts/hip-kernel-test.cpp`](../scripts/hip-kernel-test.cpp), so
you can compile it directly against the host's `hipcc` without any
copy-paste:

```bash
hipcc --offload-arch=gfx1151 \
    scripts/hip-kernel-test.cpp \
    -o /tmp/hip-kernel-test
/tmp/hip-kernel-test
echo "exit=$?"
```

(`hipcc --help` only documents the short `-o` form for the output flag;
the corresponding long form is not part of the public interface.)

The same file is also used by `./scripts/validate.sh --layer 2`, so a
single `make validate` run covers it as well.

Expected:

```
out=12345
exit=0
```

**Why it matters.** This is the smallest test that exercises the full
ROCm stack outside of any framework (no Ollama, no rocBLAS, no Docker):
queue creation → kernel dispatch → device-side write → D2H copy. If this
fails on the host with `Memory access fault by GPU node-1`, layers 3+ are
guaranteed to fail the same way. If this passes on the host but fails in
the container, the issue is container plumbing (Layer 4) not GPU.

**If it fails.** Almost always means Layer 1 (MES `0x83`) is unfixed.
A second, much rarer cause is `amd_iommu=off` (Layer 0).

---

## Layer 3 — Container builds

**Requirement.** `make build` completes with exit `0` and produces the
`amd-rocm-ollama:7.2.2` image.

```bash
cd /opt/github/MaxusAI/amd-rocm-ollama
make build
```

Expected (first cold build, ~10-25 minutes on Strix Halo):

```
[+] Building 600.0s (XX/XX) FINISHED
 => => naming to docker.io/library/amd-rocm-ollama:7.2.2
```

**If it fails:**

| First failing stage | Most likely fix                                                                       |
| ------------------- | ------------------------------------------------------------------------------------- |
| `cpu` configure     | `find_package(hip)` failure → see [`build-fixes.md` Fix 1](build-fixes.md#fix-1-cmake_prefix_pathoptrocm-in-the-base-stage) |
| `rocm-7` configure  | Same — `CMAKE_PREFIX_PATH=/opt/rocm` missing in `base` stage                          |
| `rocm-7` install    | `rocBLAS install` is the slowest step (~580 s); not a failure, just be patient        |
| `runtime` post-prune| If the prune deleted too much, see [`build-fixes.md` Fix 2](build-fixes.md#fix-2-rocblas-prune-pattern---flip-from-keep-gfx1151-to-drop-other-arches) |

---

## Layer 4 — Container runs and is healthy

**Requirement.** Container reaches `Up (healthy)` within 60 s of `make up`.

```bash
make up
sleep 8
docker compose --project-directory /opt/github/MaxusAI/amd-rocm-ollama ps
```

Expected:

```
NAME          IMAGE                   STATUS                        PORTS
ollama-rocm   amd-rocm-ollama:7.2.2   Up About a minute (healthy)   0.0.0.0:11434->11434/tcp
```

**If it fails.** Read `make logs` immediately. Common causes:

| Symptom in logs                                            | Cause                                                                |
| ---------------------------------------------------------- | -------------------------------------------------------------------- |
| `permission denied` on `/dev/kfd` or `/dev/dri/renderD*` | Wrong `group_add:` in `docker-compose.yml`; run `getent group render video` and update (render node index varies) |
| Port `11434` already in use                                | Host `ollama` systemd service is still running (`sudo systemctl stop ollama`) |
| `manifest unknown ...rocm/dev-ubuntu-24.04`                | `docker pull rocm/dev-ubuntu-24.04:7.2.2-complete` first |

---

## Layer 5 — Ollama bootstrap discovery sees the ROCm GPU

**Requirement.** Logs must contain a single `inference compute` line with
`library=ROCm` and `compute=gfx1151`. The presence of this line means
the page-fault gauntlet (Layers 0-2) actually held in container space.

```bash
make logs | grep --extended-regexp 'inference compute|fault|library=cpu'
```

Expected (one line, no faults, no CPU fallback):

```
... level=INFO source=types.go msg="inference compute" id=0 filter_id=0
    library=ROCm compute=gfx1151 name=ROCm0 description="Radeon 8060S Graphics"
    libdirs=ollama,rocm driver=70253.21 pci_id=0000:c6:00.0 type=iGPU
    total="192.0 GiB" available="191.6 GiB"
... level=INFO source=routes.go msg="vram-based default context"
    total_vram="192.0 GiB" default_num_ctx=262144
```

The `total="192.0 GiB"` is the sum of the GPU's local VRAM pool plus its
GTT window; ollama uses this for its auto-context budget. The
`default_num_ctx=262144` (= 256 K) is what allows the auto-budget to pick
the full context for `gemma4:31b-it-q4_K_M` without an explicit `num_ctx`.

**Anti-patterns:**

```
... msg="inference compute" id=cpu library=cpu ...
... msg="vram-based default context" total_vram="0 B" default_num_ctx=4096
... Memory access fault by GPU node-1 ...
```

Any of those means Layer 1 or 2 is regressed (the fix didn't survive the
last reboot, or the override blobs got overwritten by a `linux-firmware`
package upgrade).

**If it fails.**

```bash
sudo dmesg | grep --extended-regexp 'page fault|gfxhub|amdgpu' | tail -n 20
```

If `dmesg` shows a `[gfxhub] page fault ... CPF (0x4)`, it's Layer 1
(MES `0x83` came back). Re-verify
`/lib/firmware/updates/amdgpu/gc_11_5_1_*.bin.zst` are present and the
running kernel's initramfs has them embedded:

```bash
sudo lsinitramfs /boot/initrd.img-$(uname -r) | grep gc_11_5_1
```

---

## Layer 6 — Small-model inference smoke test

**Requirement.** A small model produces non-empty text and the GPU does
the work (verified via `rocm-smi` showing utilization spike).

```bash
curl --silent --request POST \
    --header 'content-type: application/json' \
    --data '{"model":"llama3.2:latest","messages":[{"role":"user","content":"Say hello in three words."}],"stream":false,"options":{"num_predict":20,"temperature":0.0}}' \
    http://localhost:11434/api/chat \
    | python3 -c "import json,sys;r=json.load(sys.stdin);print('CONTENT:',repr(r['message']['content']));print(f\"decode: {r['eval_count']/(r['eval_duration']/1e9):.1f} tok/s\")"
```

Expected (numbers approximate; both `gemma4:e4b` and `llama3.2` work cleanly):

```
CONTENT: 'Hello there friend!'
decode: 103.0 tok/s
```

GPU should be doing the work — confirm in another terminal:

```bash
sudo rocm-smi --showuse
# expect: GPU% > 80% during the 50-100 ms generation window
```

> **Known content quirk on this box:** `gemma4:31b-it-q4_K_M` (blob
> `sha256-280af6832eca…`) generates GPU-side fine — 10.5 tok/s decode at 96%
> GPU util — but the `RENDERER gemma4 / PARSER gemma4` pipeline currently
> emits only `<start_of_turn>model\n…` instead of an answer. The smaller
> `gemma4:e4b-it-q4_K_M` and unrelated models like `llama3.2` work
> normally, so this is a model-blob issue, not infra. Use them for
> Layer 6 functional smoke tests.

---

## Layer 7 — Memory math at 256K (informational)

**Requirement.** Free VRAM after loading `gemma4:31b-it-q4_K_M` with
`num_ctx=262144` is enough headroom that you don't OOM under prefill.

Budget on this box:

| Component                                     | Estimated size  |
| --------------------------------------------- | --------------- |
| Weights (Q4_K_M, 31 B)                        | ~19.9 GiB       |
| KV cache @ q8_0 + flash-attn @ 256K           | ~6 - 10 GiB     |
| KV cache @ f16, no FA, @ 256K (worst-case)    | ~12 - 20 GiB    |
| Activations + runtime overhead                | ~2 - 3 GiB      |
| **Total worst case**                          | **~43 GiB**     |
| **Available (96 GiB UMA)**                    | **96 GiB**      |
| **Headroom**                                  | **≥ 50 GiB**    |

Quick real-world check after the model is hot:

```bash
sudo rocm-smi --showmeminfo vram
# during 200K prefill against gemma4:e4b-it-q4_K_M (smaller, easier reference):
#   weights ~3 GiB + KV cache (128K cap) ~9 GiB → total ~12 GiB
# during 200K prefill against gemma4:31b-it-q4_K_M:
#   weights ~20 GiB + KV cache (full 200K) ~25 GiB → total ~45-50 GiB expected
```

**If it fails (OOM or driver hang):**

- Drop `num_ctx` to `131072` (128 K) — same model, half the KV cache.
- Switch to `gemma4:e4b-it-q4_K_M` at full 256K (will be capped to 128K
  anyway because the model declares `n_ctx_train=131072`).
- Confirm the BIOS UMA split is 96 GiB:
  `rocminfo | grep --before-context 5 'POOL 1' | head -n 30`.

---

## Layer 8 — Long-context inference (the headline feature)

**Requirement.** The Layer 8 script sends a long prompt (default: character
budget from `LONG_CTX_TOKENS`, usually targeting a **~200K-token** prefill on
`gemma4:31b-it-q4_K_M`). The harness passes on HTTP success with positive
`prompt_eval_count` (models with lower `n_ctx_train` cap tokens, as in the e4b
example below). The model that actually advertises 256 K is
`gemma4:31b-it-q4_K_M`; `gemma4:e4b-it-q4_K_M` truncates at 128 K.

The reusable test script lives at [`/tmp/long_ctx_test.py`](#test-script);
re-create from the snippet below. It builds a prompt of ~200 K tokens,
posts to `/api/generate` with `raw=true` and `num_ctx=262144`, prints
prefill rate, decode rate, and total VRAM peak.

### Result on `gemma4:e4b-it-q4_K_M` (model caps at 128 K)

| Metric                     | Value                                            |
| -------------------------- | ------------------------------------------------ |
| Sent                       | ~200,044 tokens (800 KB)                         |
| Actually processed         | **131,072 tokens** (128 K — model `n_ctx_train`) |
| Prefill duration           | 220.1 s                                          |
| **Prefill rate**           | **595.5 tok/s**                                  |
| Decode rate (at 128K ctx)  | 18.1 tok/s                                       |
| Wall clock                 | 223.8 s                                          |
| Peak VRAM                  | 12.6 GiB                                         |
| GPU utilization (sustained)| 99 %                                             |
| Faults / dmesg errors      | none                                             |

Server log on the truncation:

```
WARN ... requested context size too large for model num_ctx=262144 n_ctx_train=131072
WARN ... truncating input prompt limit=131072 prompt=249549 keep=4 new=131072
```

> Tokenizer ratio measured: 249,549 tok / 800,176 chars = **3.21 chars/token**.
> A 200 K-token target needs ~640 KB of input.

### Test script

```python
# /tmp/long_ctx_test.py
import json, time, urllib.request, sys

PASSAGE = (
    "The Strix Halo APU integrates a Zen 5 CPU complex with an RDNA 3.5 GPU "
    "(gfx1151) sharing a unified 128 GiB LPDDR5X memory pool. ROCm 7.2.2 "
    "introduces compiler and runtime support for this architecture. "
)
TARGET_CHARS = 200_000 * 3 + 200      # ~200K tokens at 3.21 chars/token
text = (PASSAGE * (TARGET_CHARS // len(PASSAGE) + 1))[:TARGET_CHARS]
prompt = (
    "You will be shown a long passage. After the passage, answer the question "
    "in ONE short sentence.\n\nPASSAGE:\n" + text +
    "\n\nQUESTION: What GPU architecture is mentioned in the passage?\nANSWER:"
)
print(f"prompt size: {len(prompt):,} chars (~{int(len(prompt)/3.21):,} tokens estimated)", flush=True)

payload = {
    "model": "gemma4:31b-it-q4_K_M",   # change to e4b for the smaller model
    "prompt": prompt,
    "stream": False,
    "raw": True,                       # bypass chat template
    "options": {"num_ctx": 262144, "num_predict": 8, "temperature": 0.0},
}
req = urllib.request.Request(
    "http://localhost:11434/api/generate",
    data=json.dumps(payload).encode(),
    headers={"content-type": "application/json"},
)
t0 = time.time()
with urllib.request.urlopen(req, timeout=3600) as resp:
    r = json.loads(resp.read())
wall = time.time() - t0

ped = r.get("prompt_eval_duration", 1)/1e9
pec = r.get("prompt_eval_count") or 1
ed  = r.get("eval_duration", 1)/1e9
ec  = r.get("eval_count") or 1
print(f"wall            : {wall:>10.1f} s")
print(f"prompt_eval     : {pec:>10,} tok / {ped:>6.1f} s = {pec/ped:>7.1f} tok/s")
print(f"eval (decode)   : {ec:>10,} tok / {ed:>6.1f} s = {ec/ed:>7.1f} tok/s @ {pec:,} ctx")
print(f"response        : {r.get('response','')!r}")
```

### How to run it (with GPU monitoring)

```bash
# 1. unload anything currently in VRAM (so we observe the cold load)
for m in gemma4:31b-it-q4_K_M gemma4:e4b-it-q4_K_M llama3.2:latest; do
    curl --silent --request POST --header 'content-type: application/json' \
        --data "{\"model\":\"$m\",\"keep_alive\":0}" \
        http://localhost:11434/api/generate >/dev/null
done

# 2. run the test in the background
nohup python3 /tmp/long_ctx_test.py > /tmp/long_ctx_test.out 2>&1 &
TEST_PID=$!

# 3. poll GPU every 60s while it runs (prefill is ~5-25 min)
while kill -0 $TEST_PID 2>/dev/null; do
    sleep 60
    sudo rocm-smi --showuse --showmeminfo vram --csv | grep '^card0'
done

# 4. read result
cat /tmp/long_ctx_test.out
```

**Pass criteria.**

- `prompt_eval_count` matches what you actually sent (no `truncating input
  prompt` warning in `make logs` other than the documented e4b 128K cap).
- `dmesg` shows zero new `page fault` or `gfxhub` lines after the test.
- `make logs` shows no `library=cpu` fallback during the run.
- GPU utilization in `rocm-smi` stayed > 80 % through prefill.
- Final `response` is non-empty (or, for the known `gemma4:31b` content
  quirk above, the prefill numbers are valid even if response text is
  control tokens).

---

## Quick "is the whole stack still working?" one-liner

After a host reboot or a `linux-firmware` package upgrade, this single
command tells you whether anything in the chain regressed:

```bash
( sudo cat /sys/kernel/debug/dri/1/amdgpu_firmware_info | grep '^MES feature' \
  && /tmp/hip-kernel \
  && curl --silent http://localhost:11434/api/tags | python3 -c "import json,sys;print('models:',[m['name'] for m in json.load(sys.stdin)['models']])" \
) 2>&1
```

Healthy output:

```
MES feature version: 1, firmware version: 0x0000007c
out=12345
models: ['qwen3.5:122b-a10b-q4_K_M', 'gemma4:latest', 'gemma4:e4b-it-q4_K_M', 'gemma4:31b-it-q4_K_M', 'llama3.2:latest', 'deepseek-r1:1.5b']
```

Anything else and you walk the layers above top-to-bottom.
