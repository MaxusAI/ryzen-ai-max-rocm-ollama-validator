# Where does Ollama break on the AMD Ryzen AI MAX+ 395?

Empirical results from pushing the `gfx1151` setup with realistic models
to find the actual breakage thresholds. All numbers from one box:

- AMD Ryzen AI MAX+ 395 w/ Radeon 8060S, BIOS UMA split = **96 GiB GPU /
  31 GiB system**.
- Linux 6.14.0-1018-oem, MES firmware `0x7c` (post-`0x83` regression).
- Host Ollama 0.21.0 (curl-installed), built against ROCm 7.2.1.
- Override:

  ```ini
  Environment="OLLAMA_FLASH_ATTENTION=1"
  Environment="OLLAMA_KV_CACHE_TYPE=q8_0"
  Environment="OLLAMA_NUM_PARALLEL=2"
  ```

The point of this document is not "look how easy it is to crash" - it
is the opposite. Ollama survived everything thrown at it; the GPU never
wedged; the API kept responding. What we found is **where it gets
unusable** before it actually breaks. Knowing that lets you size
deployments and set client-side timeouts that match reality.

---

## Summary: four observed limit modes

| # | Limit mode                        | Trigger                                                                                | Symptom                                                              | Ollama recovered? |
| - | --------------------------------- | -------------------------------------------------------------------------------------- | -------------------------------------------------------------------- | ----------------- |
| 1 | **Compute starvation**            | qwen3.5:122b @ 256K ctx, 131K-token prompt, concurrency=2                              | 1 of 2 requests hit the 30-min curl timeout (HTTP 500 from runner)   | yes               |
| 2 | **VRAM ceiling at load**          | gemma4:31b (18.5 GiB weights) loaded on top of qwen3.5:122b (87 GiB live)              | clean OOM in the journal: `cudaMalloc failed: out of memory`         | yes               |
| 3 | **Eviction deadlock**             | same as #2, but qwen had a stale ref-count=2 from a prior aborted parallel test        | API returned **empty body** after curl 180 s timeout; nothing loaded | yes               |
| 4 | **Silent NUM_PARALLEL downgrade** | sustained pressure / fragmented free VRAM at model load time                           | runner re-fits with `parallel=1` even when env says `NUM_PARALLEL=2` | yes               |

What we did **not** observe at any point during these tests:

- No MES timeout / ring-full events in `dmesg` (the `0x7c` firmware
  held throughout).
- No GPU reset, no kernel oops, no host reboot needed.
- No Ollama daemon crash. `/api/version` always responded.
- No data corruption in completed responses.

The post-0x83 firmware really is night-and-day different from the
broken one — under prior MES this exact workload would have wedged the
GPU within minutes.

---

## Mode 1: compute starvation at 131K-token prompts × 2

**Test**: `scripts/stress-test.sh --num-ctx 262144 --concurrency 2
--requests 2` against `qwen3.5:122b-a10b-q4_K_M`, with the default
`--prompt-frac 0.5` (≈131K tokens per prompt).

**Result**:

```text
Per-request results
  [FAIL] request #1: rc=28 wall=1799.97s (failed)
    #2: wall=931.49s  prompt=129215 tok in 929.393s  decode=16 tok in 1.850s

Summary
  num_ctx:               262144 (model max=262144)
  concurrency:           2 (Ollama NUM_PARALLEL=2)
  succeeded=1  failed=1
  wall (run only):       1800s
  VRAM peak:             94.51 GiB         <-- 1.5 GiB headroom
  GPU peak util / temp:  100% / 81 C
  MES dmesg pre/post:    timeouts 0->0 (+0)  ring-full 0->0 (+0)
  ollama runtime (real): FA=enabled  KV=K(q8_0)+V(q8_0)  ROCm/gfx1151
```

**What happened**: prompt eval for 131K tokens on a 125 B-parameter MoE
took **15 min 31 sec** for the request that completed and **>30 min**
(curl timeout) for the one that didn't. Ollama itself returned HTTP 500
to the timed-out request - that's the runner correctly failing the
request rather than letting it block forever. The KV cache was
preallocated for both sequences; the bottleneck is the prefill compute,
not memory.

**Practical implication**: at 256K context on this hardware, plan for
**single-request serving**, not concurrent. If you need concurrency,
either drop the context or accept that Ollama's `NUM_PARALLEL` will
silently downgrade to 1 anyway under memory pressure (see Mode 4).

---

## Mode 2: VRAM ceiling at load (clean OOM)

**Test**: with qwen3.5:122b loaded (87 GiB / 96 GiB used, 9 GiB free)
plus llama3.2:latest as a small co-tenant (2.7 GiB), `POST
/api/generate` to `gemma4:31b-it-q4_K_M` (needs ~18.8 GiB for weights).

**Result** (from `journalctl _SYSTEMD_INVOCATION_ID=...`):

```text
runner.go:1290 msg=load request="{Operation:alloc ... GPULayers:61[ID:0 Layers:61(0..60)] ...}"
ggml_backend_cuda_buffer_type_alloc_buffer: allocating 18843.56 MiB on device 0:
  cudaMalloc failed: out of memory
alloc_tensor_range: failed to allocate ROCm0 buffer of size 19758907904
server.go:1043 msg="model requires more gpu memory than is currently available,
                    evicting a model to make space" "loaded layers"=35
sched.go:892   msg="no idle runners, picking the shortest duration" runner_count=1
               runner.name=...qwen3.5:122b... runner.size="87.0 GiB"
```

(The `cudaMalloc` label is misleading - it's really `hipMalloc`. Ollama
links the same upstream ggml code path for both.)

**What happened**: clean OOM signal caught, eviction logic kicked in.
This is the success path - Ollama detects the over-commit at allocation
time and tries to make room.

**Practical implication**: you **can** safely load multiple models that
together exceed VRAM. Ollama will evict the largest least-recently-used
one to make space. The `availble VRAM` heuristic Ollama uses is
slightly optimistic (it allowed both qwen and llama3.2 to coexist at
89.8 GiB / 96 GiB), so the real OOM check happens at allocation in the
runner, not at scheduling.

---

## Mode 3: eviction deadlock when ref-counts won't drop

**Test**: same as Mode 2, but the previous Mode-1 test had been
aborted via the user backgrounding the wrapper. Two stale `curl`
processes (PIDs from the earlier test) were still attached to qwen,
keeping `refCount=2`.

**Result**:

```text
sched.go:254 msg="resetting model to expire immediately to make room"
             runner.name=...qwen3.5:122b... refCount=2
sched.go:265 msg="waiting for pending requests to complete and unload to occur"
[... 180 seconds of nothing ...]
[curl returns empty body]
```

**What happened**: Ollama wanted to evict qwen to load gemma4, but
`refCount=2` meant two requests were "still in flight" from the
scheduler's perspective. Those requests were the abandoned curls -
client-side dead but server-side still bookkeeping. Ollama waited
indefinitely; the new gemma4 request hung with no useful error. After
we `kill -9`'d the stale curls, the API recovered immediately.

**Practical implication**: **always wait for `stress-test.sh` /
`torture.sh` to complete cleanly before starting a new run**, or
manually kill leftover `curl ... /api/generate` processes. The
`stress-test.sh` script tracks its own children, but if it's
backgrounded mid-run via the IDE's "Background" button, those children
become orphaned and keep ref-counts alive on whatever model they were
talking to. This is fundamentally a **lifecycle bug between the test
harness and Ollama's scheduler**, not a kernel/firmware issue. If
you've ever wondered why a fresh model load "just hangs" - check for
zombie clients first:

```bash
pgrep --list-full --full 'curl.*api/generate'
sudo pkill --signal=KILL --full 'curl.*api/generate'
```

---

## Mode 4: silent `NUM_PARALLEL` downgrade

**Test**: any of the above, when total VRAM commitment for `NUM_PARALLEL`
sequences would exceed available memory.

**Result** (from journal scheduler log):

```text
runner.size="87.0 GiB" runner.vram="87.0 GiB" runner.parallel=1
                                              ^^^^^^^^^^^^^^^^^^
```

But the env (and `validate.sh` Layer 4):

```text
OLLAMA_NUM_PARALLEL: 2
```

**What happened**: Ollama internally lowered the per-runner parallelism
from 2 to 1 because the second sequence's KV cache wouldn't fit. There
is no warning to the client. The request that arrives with the
expectation of being one of two parallel slots ends up serialized
behind any other request, which is most of why Mode 1 took 30 minutes
for the second request - it was actually serialized, not parallel.

**Detection**: `validate.sh` Layer 4 surfaces this directly via the
**runtime state** block (added 2026-04-19). Look for a mismatch between
`num_parallel = 2` (env) and the runner's `kv_cache: ... 1 seq` line:

```text
ollama runtime config (governs how much load it will accept):
  num_parallel     = 2
ollama runtime state (what the runner ACTUALLY did at last model load):
  kv cache         = 7616 MiB total (7616 MiB per seq x 1 seqs)  K(q8_0) + V(q8_0)
                                                       ^^^^^^^
```

**Practical implication**: at 256K context on qwen3.5:122b, **assume
parallel=1 regardless of what env says**. The downgrade is the right
call from Ollama (better than refusing the load), but it makes
concurrency benchmarks meaningless unless you check the runtime state.

---

## What does NOT break it

For completeness, configurations we tried that worked fine:

- 256K context, `OLLAMA_KV_CACHE_TYPE=q8_0`, single-request serving:
  works, ~15 min for 131K-token prompt eval.
- 256K context, two small co-tenant models (qwen 87 + llama3.2 2.7 = 90
  GiB): coexists.
- 64K context, `concurrency=8` against `NUM_PARALLEL=2`: queues
  cleanly (we cut the test short, but no errors observed in the queued
  portion).
- All firmware-stress regressions from the `0x83`-era playbook (long
  decode, rapid model swap, idle-then-burst): no MES events with
  firmware `0x7c`.

The current envelope for **dependable** serving on this hardware is
roughly:

| Context | Model class                             | Concurrency | KV type | VRAM headroom | Status        |
| ------- | --------------------------------------- | ----------- | ------- | ------------- | ------------- |
| 64K     | up to ~75 GiB weights (qwen3.5:122b)    | 1-2         | q8_0    | ~16 GiB       | rock solid    |
| 128K    | up to ~75 GiB weights                   | 1-2         | q8_0    | ~12 GiB       | solid         |
| 256K    | up to ~75 GiB weights                   | **1**       | q8_0    | ~8 GiB        | works, slow   |
| 256K    | up to ~75 GiB weights                   | 2           | q8_0    | ~1.5 GiB      | edge - Mode 1 |
| 256K    | any                                     | any         | **f16** | negative      | won't load    |

---

## Reproducing these tests

```bash
# Mode 1 (single-test):
./scripts/stress-test.sh \
    --model qwen3.5:122b-a10b-q4_K_M \
    --num-ctx 262144 --concurrency 2 --requests 2 --prompt-frac 0.5

# All four modes via the staged ladder:
./scripts/torture.sh --list             # see the stages
./scripts/torture.sh                    # full run, stops on first failure
./scripts/torture.sh --only 5           # just the heavy queue-saturation stage

# History of all runs is kept here:
./scripts/log-run.sh show --last 5
```

Each invocation logs one record to `logs/run-history.jsonl` with the
full system snapshot AND the new `ollama_runtime` block (FA decision,
KV type, per-seq size, sequence count, library/arch). Diff between
runs to see exactly what changed:

```bash
./scripts/log-run.sh diff 0 1
```
