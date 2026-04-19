# docs/

Engineering notes for `amd-rocm-ollama`. These are background articles for
maintainers, not user-facing setup docs (see the top-level
[../README.md](../README.md) for that).

| File                                                       | Topic                                                                                              |
| ---------------------------------------------------------- | -------------------------------------------------------------------------------------------------- |
| [validation-tests.md](validation-tests.md)                 | Layered test ladder — 9 hard requirements from kernel cmdline through 200K-token prefill           |
| [build-fixes.md](build-fixes.md)                           | First-build / first-run failures and the fixes applied (CMake HIP, rocBLAS prune, IOMMU, MES firmware, minimal host systemd override + audit trail of two retracted theories) |
| [rocblas-prune.md](rocblas-prune.md)                       | What the gfx1151-only rocBLAS prune actually keeps and why                                         |
| [break-modes.md](break-modes.md)                           | Empirical limit table — where Ollama stops scaling on this hardware (compute starvation, VRAM ceiling, eviction deadlock, silent NUM_PARALLEL downgrade) |
| [`../scripts/stress-test.sh`](../scripts/stress-test.sh)   | (script, not a doc) VRAM/GTT/MES stress tester — read its `--help` for the methodology             |
| [`../scripts/torture.sh`](../scripts/torture.sh)           | (script, not a doc) Escalating torture ladder — finds the breakage threshold automatically         |
| [`../scripts/log-run.sh`](../scripts/log-run.sh)           | (script, not a doc) JSONL run-history wrapper — read its `--help` for the record format            |

**Start here for a brand-new setup:**
[`validation-tests.md`](validation-tests.md) — work it top-to-bottom; each
layer that passes unblocks the next. The whole stack is healthy when
Layer 8 (200K-token prefill) returns clean. The whole ladder is also
automated:

```bash
make validate          # everything except the 4-25-min long-context test
make validate-full     # the whole thing
make validate-logged   # validate-full + append a JSONL record to logs/run-history.jsonl
```

**Tracking what worked and what didn't over time**: every run via the
`*-logged` make targets (or `./scripts/log-run.sh -- <cmd>`) appends
one line to `logs/run-history.jsonl` with a full system snapshot
(kernel, `linux-firmware`, MES firmware, ROCm, Ollama, GPU, runtime
mode) plus the per-layer / per-stress result. Tail recent runs and
diff between them with:

```bash
make run-history                       # last 10 entries
./scripts/log-run.sh diff 0 1          # newest vs second-newest, version + summary
```

**Stress-testing the GPU under realistic concurrent load**: the same
JSONL log captures `make stress-test` runs (largest installed model,
parallel `/api/generate` requests at full `num_ctx`, with rocm-smi +
dmesg monitoring). Use it after firmware/BIOS/kernel changes to catch
MES regressions before they bite a real workload:

```bash
make stress-test-quick                 # ~5 min, safer iteration
make stress-test                       # ~30 min, hits the largest model at full ctx
```

**Finding the actual breakage threshold**: when `make stress-test`
stops being scary and you want to know where Ollama actually falls
over, use the torture ladder. It runs progressively harder
configurations (more concurrency, more queueing, sustained decode at
the VRAM edge), captures the dmesg + Ollama scheduler delta between
stages, and stops at the first failure:

```bash
./scripts/torture.sh --list            # see the stages
./scripts/torture.sh                   # full run, stops on first failure
./scripts/torture.sh --only 5          # just the heavy queue-saturation stage
```

The four observed limit modes (compute starvation at 256K + 131K-token
prompts, VRAM ceiling on multi-model load, eviction deadlock from
zombie clients, silent `NUM_PARALLEL` downgrade) and the dependable
operating envelope are documented in
[`break-modes.md`](break-modes.md).

**Start here if it was working and broke:** the same doc — start at
**Layer 1 (MES firmware)**. The single most common regression is a
`linux-firmware` package upgrade re-installing the buggy `0x83` MES blob
that shadows our override; quick recheck:

```bash
make mes-check         # equivalent to: ./scripts/install-mes-firmware.sh --check
```

If broken, the fix is also one command (then a reboot):

```bash
make install-mes-firmware && sudo reboot
```

Full background:
[`build-fixes.md` Fix 4](build-fixes.md#fix-4-mes-0x83-firmware-regression-the-actual-root-cause-of-the-page-fault).
Operational details for both scripts:
[`../scripts/README.md`](../scripts/README.md).

**Start here if you installed Ollama on the host with
`curl https://ollama.com/install.sh | sh` and it's running on Vulkan
or CPU instead of ROCm:** the cause is almost always Fix 4 (the MES
`0x83` firmware regression) - when the `rocm` runner can't initialise,
Ollama silently falls back to Vulkan or CPU. Diagnosis:

```bash
make mes-check                   # is the MES firmware safe?
make install-mes-firmware        # if not, install the override
sudo reboot
make validate --mode host        # re-check
```

The minimal host systemd override is purely operational
(`OLLAMA_HOST`, `OLLAMA_DEBUG`, `OLLAMA_MODELS`) - **no GPU-specific
env vars and no `User=root` are required**. The full story including
two retracted theories (the `User=root` claim and the `OLLAMA_ROCM=1`
claim) is in
[`build-fixes.md` Fix 5](build-fixes.md#fix-5-minimal-systemd-override-for-the-host-install-and-what-wasnt-actually-needed).
