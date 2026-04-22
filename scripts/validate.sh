#!/usr/bin/env bash
# scripts/validate.sh - 9-layer validation ladder for amd-rocm-ollama.
#
# Implements the test plan from docs/validation-tests.md. Each layer is a
# hard requirement for the layer above it - if a layer fails, dependent
# layers are skipped and the script exits non-zero with a pointer to the
# fix.
#
# Usage:
#   ./scripts/validate.sh                       # run all layers (auto-detect host or container)
#   ./scripts/validate.sh --mode host           # validate the host-installed Ollama
#   ./scripts/validate.sh --mode container      # validate the docker compose Ollama
#   ./scripts/validate.sh --mode auto           # default: prefer container if running, else host
#   ./scripts/validate.sh --layer 1             # run only layer 1 (and any host-side prereqs)
#   ./scripts/validate.sh --from 4              # run layer 4 onwards (skip host-side)
#   ./scripts/validate.sh --skip-long-ctx       # skip the multi-minute Layer 8
#   ./scripts/validate.sh --help                # show this help
#
# Layers 0-2 always run on the host (kernel cmdline, MES firmware, HIP smoke test).
# Layers 3-5 are runtime-specific:
#   container mode: Layer 3 = image present; Layer 4 = compose health; Layer 5 = compose logs
#   host mode:      Layer 3 = SKIP (n/a);    Layer 4 = systemd / API health; Layer 5 = journalctl + /api/ps
# Layers 6-8 hit the Ollama HTTP API (http://localhost:HOST_PORT) so they're identical in both modes.
#
# Exit codes:
#   0   all selected layers passed
#   1   one or more layers failed
#   2   bad invocation
#
# Run as a normal user; the script uses 'sudo --non-interactive' for the
# few commands that need root (debugfs read, dmesg). Cache the sudo
# credential first if you don't want prompts:  sudo -v

# Re-exec under bash if invoked via 'sh script.sh' or 'sudo sh script.sh'.
# Everything above this line is comments, so still POSIX-safe under dash;
# everything below uses bash-specific syntax (set -o pipefail, [[ ]],
# arrays, ${VAR:-default} substitution, etc.).
# shellcheck disable=SC2128
if [ -z "${BASH_VERSION:-}" ]; then
    exec bash "$0" "$@"
fi

set -o errexit
set -o nounset
set -o pipefail

# ---------------------------------------------------------------------------
# config
# ---------------------------------------------------------------------------

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE_FILE="${COMPOSE_FILE:-${REPO_ROOT}/docker-compose.yml}"
HOST_PORT="${HOST_PORT:-11434}"
COMPOSE_SERVICE="${COMPOSE_SERVICE:-${SERVICE:-ollama}}"   # docker compose service name (NOT container_name)
DRI_INDEX="${DRI_INDEX:-1}"   # /sys/kernel/debug/dri/<idx>/ - 1 on this box
HIP_TEST_SRC="${HIP_TEST_SRC:-${REPO_ROOT}/scripts/hip-kernel-test.cpp}"
# HIP_TEST_BIN: empty by default; layer_2 mktemps a per-run path so a stale
# root-owned /tmp/hip-kernel-test from a previous `sudo ./scripts/validate.sh`
# run can't make hipcc fail with a misleading "ROCm install is broken" error.
# Set this env var explicitly only if you want to inspect the binary after.
HIP_TEST_BIN="${HIP_TEST_BIN:-}"
LONG_CTX_OUT="${LONG_CTX_OUT:-/tmp/long_ctx_validate.out}"
# Model preferences. These are the historical defaults and act as the FIRST
# choice if the user has them pulled. If the env var is unset OR the named
# model isn't installed, _resolve_smoke_model / _resolve_long_ctx_model
# auto-pick whatever IS available (smallest installed for smoke, largest
# >=128K-context model for long-ctx). Everyone gets a useful run regardless
# of which Gemma/Llama/Qwen tag they've pulled.
SMOKE_MODEL_PREFERRED="${SMOKE_MODEL:-llama3.2:latest}"
LONG_CTX_MODEL_PREFERRED="${LONG_CTX_MODEL:-gemma4:e4b-it-q4_K_M}"
SMOKE_MODEL=""           # resolved at Layer 6 entry, see _resolve_smoke_model
LONG_CTX_MODEL=""        # resolved at Layer 8 entry, see _resolve_long_ctx_model
LONG_CTX_TOKENS="${LONG_CTX_TOKENS:-200000}"
LONG_CTX_NUM_CTX="${LONG_CTX_NUM_CTX:-262144}"
IMAGE_TAG="${IMAGE_TAG:-amd-rocm-ollama:7.2.2}"

FROM_LAYER=0
ONLY_LAYER=
SKIP_LONG_CTX=0
MODE="${MODE:-auto}"   # auto | container | host - which Ollama runtime to validate
DETECTED_MODE=          # set by detect_mode() once layers start
CONTAINER_NAME=         # set by detect_mode() in container mode (from 'docker compose ps')

# ---------------------------------------------------------------------------
# pretty-printing (colors from scripts/lib/pretty.sh; layer-aware
# pass/fail/skip/print_header are validate-specific and stay local. Our
# `info` shadows pretty.sh's variant so we keep the dim styling that
# matches Layer hint lines.)
# ---------------------------------------------------------------------------

# shellcheck source=lib/pretty.sh
. "${REPO_ROOT}/scripts/lib/pretty.sh"
# shellcheck source=lib/api.sh
. "${REPO_ROOT}/scripts/lib/api.sh"

declare -a RESULTS=()   # "<layer>|<status>|<message>"

print_header() {
    printf '\n%s===== Layer %s: %s =====%s\n' "${C_BOLD}${C_BLUE}" "$1" "$2" "${C_RESET}"
}

pass() {
    local layer="$1" msg="$2"
    printf '  %s[PASS]%s %s\n' "${C_GREEN}" "${C_RESET}" "$msg"
    RESULTS+=("${layer}|PASS|${msg}")
}

fail() {
    local layer="$1" msg="$2" hint="${3:-}"
    printf '  %s[FAIL]%s %s\n' "${C_RED}" "${C_RESET}" "$msg"
    [ -n "$hint" ] && printf '         %s%s%s\n' "${C_DIM}" "${hint}" "${C_RESET}"
    RESULTS+=("${layer}|FAIL|${msg}")
}

skip() {
    local layer="$1" msg="$2"
    printf '  %s[SKIP]%s %s\n' "${C_YELLOW}" "${C_RESET}" "$msg"
    RESULTS+=("${layer}|SKIP|${msg}")
}

# validate-specific: dim styling so "info" lines visually recede behind
# the colored PASS/FAIL/SKIP labels. Different from pretty.sh's plain
# `info()` and intentionally so.
info() {
    printf '  %s%s%s\n' "${C_DIM}" "$1" "${C_RESET}"
}

# Print the most relevant slice of Ollama's effective server config -
# the keys that govern "how much load Ollama will accept and how it
# spends VRAM". These DON'T appear in any /api/* endpoint (verified:
# /api/config, /api/info, /api/server, /api/runtime, /api/env all 404
# on Ollama 0.21.0) and only the explicitly-set ones are in
# /proc/<pid>/environ - everything that fell back to a default is
# invisible there. The values below come from the structured
#   msg="server config" env="map[...]"
# line that Ollama emits ONCE per `serve` boot to stderr. We extract
# and parse it via scripts/lib/snapshot.sh, with caching keyed on the
# systemd InvocationID so repeated runs are instant.
print_ollama_runtime_config() {
    # shellcheck source=lib/snapshot.sh
    . "${REPO_ROOT}/scripts/lib/snapshot.sh"
    local cfg
    cfg=$(snapshot_ollama_config_json)
    if [ -z "$cfg" ] || [ "$cfg" = "null" ]; then
        info "ollama config: (could not read; restart ollama to refresh logs)"
        return
    fi
    # Pull the keys we care to surface; default unknown -> "?".
    local out
    out=$(printf '%s' "$cfg" | python3 -c '
import json, sys
try:
    d = json.loads(sys.stdin.read()) or {}
except Exception:
    d = {}
keys = [
    ("OLLAMA_NUM_PARALLEL",      "num_parallel     "),
    ("OLLAMA_MAX_QUEUE",         "max_queue        "),
    ("OLLAMA_MAX_LOADED_MODELS", "max_loaded_models"),
    ("OLLAMA_KEEP_ALIVE",        "keep_alive       "),
    ("OLLAMA_FLASH_ATTENTION",   "flash_attention  "),
    ("OLLAMA_KV_CACHE_TYPE",     "kv_cache_type    "),
    ("OLLAMA_NEW_ENGINE",        "new_engine       "),
    ("OLLAMA_CONTEXT_LENGTH",    "context_length   "),
    ("OLLAMA_LOAD_TIMEOUT",      "load_timeout     "),
    ("OLLAMA_GPU_OVERHEAD",      "gpu_overhead     "),
]
for k, label in keys:
    v = d.get(k, "?")
    if v == "" and k == "OLLAMA_KV_CACHE_TYPE":
        v = "f16 (default)"
    elif v == "":
        v = "(unset)"
    print(f"  {label}= {v}")
')
    info "ollama runtime config (governs how much load it will accept):"
    printf '%s\n' "$out" | sed "s|^|        ${C_DIM}|; s|\$|${C_RESET}|"
}

# Print the ACTUAL runtime state of the most recently loaded model -
# what the inner llama.cpp runner decided, not what the daemon-level
# env vars hint at. The two are easy to confuse:
#   OLLAMA_FLASH_ATTENTION=false (env)  vs  flash_attn=enabled (runner)
# both happen by default and mean different things. This block tells
# you the truth: was FA actually applied, what's the K/V cache type,
# how big is it, and what compute buffers are reserved on device vs
# host pinned memory.
#
# The data is per-model-load, so it's empty if no model has been
# inferred against since the last Ollama restart. We hint the user to
# load one in that case.
print_ollama_runtime_state() {
    # snapshot.sh already sourced by print_ollama_runtime_config, but be
    # defensive in case this is called standalone.
    # shellcheck source=lib/snapshot.sh
    . "${REPO_ROOT}/scripts/lib/snapshot.sh"
    local rt cfg
    rt=$(snapshot_ollama_runtime_state_json)
    if [ -z "$rt" ] || [ "$rt" = "null" ]; then
        info "ollama runtime state: (no model loaded since last restart -"
        info "  send any /api/generate request to populate runner-level info)"
        return
    fi
    # Pull config too so the hint can detect "env set but not applied"
    # (e.g. user set OLLAMA_KV_CACHE_TYPE=q8_0 after a model was already
    # loaded - the running model still uses f16 until reloaded).
    cfg=$(snapshot_ollama_config_json)
    local out
    out=$(printf '%s\n%s\n' "$rt" "$cfg" | python3 -c '
import json, sys
raw = sys.stdin.read().splitlines()
try:
    d = json.loads(raw[0]) if raw else {}
    d = d or {}
except Exception:
    d = {}
try:
    cfg = json.loads(raw[1]) if len(raw) > 1 else {}
    cfg = cfg or {}
except Exception:
    cfg = {}
def g(k, default="?"):
    v = d.get(k, default)
    return default if v == "" or v is None else v
fa_req = g("flash_attn_requested", "?")
fa_res = g("flash_attn_resolved", "?")
fa_line = f"flash attention      = {fa_res}    (runner saw: requested={fa_req})"
kv_total = g("kv_cache_total_mib", 0)
kv_cells = g("kv_cache_cells", 0)
kv_layers = g("kv_cache_layers", 0)
kv_seqs = g("kv_cache_seqs", 1)
try:
    kv_seqs_int = int(kv_seqs)
except (TypeError, ValueError):
    kv_seqs_int = 1
kv_k_type = g("kv_cache_k_type", "?")
kv_v_type = g("kv_cache_v_type", "?")
# When NUM_PARALLEL > 1, Ollama allocates one KV slot per concurrent
# sequence, so the total scales linearly. Surface per-seq alongside
# total so users do not get spooked by a "bigger than f16" total
# after enabling q8_0 with NUM_PARALLEL=2.
if kv_seqs_int > 1 and kv_total:
    per_seq = kv_total / kv_seqs_int
    kv_line = (f"kv cache             = {kv_total:.0f} MiB total ({per_seq:.0f} MiB per seq x {kv_seqs_int} seqs)  "
               f"K({kv_k_type}) + V({kv_v_type}) over {kv_layers} layers, {kv_cells} cells")
else:
    kv_line = (f"kv cache             = {kv_total:.0f} MiB total  "
               f"K({kv_k_type}) + V({kv_v_type}) over {kv_layers} layers, {kv_cells} cells")
cb = g("compute_buffer_mib", 0)
hb = g("host_compute_buffer_mib", 0)
buf_line = f"compute buffers      = {cb:.0f} MiB device + {hb:.0f} MiB host pinned"
lib = g("library", "?"); arch = g("compute", "?")
gpu_line = f"library / compute    = {lib} / {arch}"
short = g("model_short", "?")
mod_line = f"last model loaded    = {short}"

env_kv  = cfg.get("OLLAMA_KV_CACHE_TYPE", "")
env_fa  = cfg.get("OLLAMA_FLASH_ATTENTION", "")
hints = []
# Detect three scenarios for KV cache quantization:
#  1. Env set + FA env=true + runtime quantized -> all good (no hint).
#  2. Env set + FA env=false + runtime f16  -> Ollama silently ignores
#     OLLAMA_KV_CACHE_TYPE because it gates KV quantization on the env
#     OLLAMA_FLASH_ATTENTION=true (the runner auto-enabling FA is NOT
#     enough for the daemon-level KV gate). This is the most confusing
#     case - users see "auto enabled" in the runner log and assume
#     KV quantization will follow. It does not.
#  3. Env set + FA env=true + runtime still f16 -> drift; restart needed.
#  4. Env unset + KV f16 + non-trivial size -> tip about q8_0.
if env_kv and env_kv != "f16" and kv_k_type == "f16":
    if env_fa != "true" and env_fa != "1":
        fa_state = env_fa if env_fa else "unset"
        hints.append("DRIFT: OLLAMA_KV_CACHE_TYPE=" + env_kv + " is IGNORED because OLLAMA_FLASH_ATTENTION=" + fa_state + ".")
        hints.append("  Ollama gates KV quantization on the env var (the runner auto-enabling FA does not count).")
        hints.append("  Add  Environment=OLLAMA_FLASH_ATTENTION=1  to the systemd override and restart ollama.")
    else:
        hints.append("DRIFT: OLLAMA_KV_CACHE_TYPE=" + env_kv + " in env, but loaded model has K/V=f16.")
        hints.append("  Reload the model to apply (e.g. `ollama stop " + short + "` then send any request).")
elif env_kv and env_kv == kv_k_type:
    pass  # consistent, nothing to say
elif not env_kv and kv_k_type == "f16" and kv_total > 1024:
    hints.append("Tip: set OLLAMA_FLASH_ATTENTION=1 + OLLAMA_KV_CACHE_TYPE=q8_0 to halve the KV cache.")
# FA env-var vs runtime mismatch is normal (env=false but runtime=auto->enabled);
# only flag the surprising case where user explicitly asked for FA but didnt get it.
if (env_fa == "true" or env_fa == "1") and fa_res == "disabled":
    hints.append("UNEXPECTED: OLLAMA_FLASH_ATTENTION=true but runner DISABLED FA - check model compat.")

print(f"  {gpu_line}")
print(f"  {mod_line}")
print(f"  {fa_line}")
print(f"  {kv_line}")
print(f"  {buf_line}")
for h in hints:
    print(f"  {h}")
')
    info "ollama runtime state (what the runner ACTUALLY did at last model load):"
    printf '%s\n' "$out" | sed "s|^|        ${C_DIM}|; s|\$|${C_RESET}|"
}

# Was the previous (numerically lower) layer a PASS? Used to gate dependent
# layers - if Layer 1 failed we don't bother running Layer 2 etc.
# A layer that wasn't run at all (because of --from / --layer) is treated
# as "presumed OK" - the user explicitly said to skip it.
prereq_passed() {
    local layer="$1"
    for r in "${RESULTS[@]}"; do
        IFS='|' read -r ll status _ <<<"$r"
        if [ "$ll" = "$layer" ]; then
            [ "$status" = "PASS" ] && return 0
            return 1
        fi
    done
    return 0  # layer wasn't run; presume OK
}

# Should we actually run a given layer based on --layer / --from flags?
should_run() {
    local layer="$1"
    if [ -n "$ONLY_LAYER" ]; then
        [ "$layer" = "$ONLY_LAYER" ] && return 0 || return 1
    fi
    [ "$layer" -ge "$FROM_LAYER" ] && return 0 || return 1
}

# ---------------------------------------------------------------------------
# argument parsing
# ---------------------------------------------------------------------------

usage() {
    sed -n '2,/^$/p' "$0" | sed 's/^# \?//'
    exit "${1:-0}"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --layer)         ONLY_LAYER="$2"; shift 2 ;;
        --layer=*)       ONLY_LAYER="${1#*=}"; shift ;;
        --from)          FROM_LAYER="$2"; shift 2 ;;
        --from=*)        FROM_LAYER="${1#*=}"; shift ;;
        --skip-long-ctx) SKIP_LONG_CTX=1; shift ;;
        --mode)          MODE="$2"; shift 2 ;;
        --mode=*)        MODE="${1#*=}"; shift ;;
        -h|--help)       usage 0 ;;
        *)               printf 'unknown arg: %s\n\n' "$1"; usage 2 ;;
    esac
done

case "$MODE" in
    auto|container|host) ;;
    *) printf 'invalid --mode: %s (must be: auto|container|host)\n' "$MODE"; exit 2 ;;
esac

# ---------------------------------------------------------------------------
# runtime detection - which Ollama are we validating?
# ---------------------------------------------------------------------------

# Returns the actual container name from 'docker compose ps' for our
# service, or empty string if no running container exists.
# Uses '|| true' to keep set -o pipefail + errexit from killing the
# script when the compose service doesn't exist.
compose_container_name() {
    command -v docker >/dev/null 2>&1 || { echo ""; return 0; }
    [ -r "$COMPOSE_FILE" ] || { echo ""; return 0; }
    docker compose --file "$COMPOSE_FILE" ps \
        --status running --format '{{.Name}}' "$COMPOSE_SERVICE" 2>/dev/null \
        | head -n 1 || true
}

api_responding() {
    # Thin alias kept so existing call sites read naturally; api.sh's
    # api_alive does the actual check (with the same 3s timeout).
    api_alive 3
}

# Find the PID listening on $HOST_PORT (any of TCP4/TCP6/UDS routed via
# the ollama serve process). Tries 'ss' first, falls back to 'lsof' or
# 'fuser'. Returns empty if nothing found or no permission.
listening_pid() {
    local pid=""
    if command -v ss >/dev/null 2>&1; then
        # 'ss -tlnp' needs root for the 'users:(("name",pid=N))' column
        pid=$(sudo --non-interactive ss -tlnp 2>/dev/null \
            | awk -v port=":${HOST_PORT}" '$4 ~ port' \
            | grep --extended-regexp --only-matching 'pid=[0-9]+' \
            | head -n 1 | cut --delimiter='=' --fields=2)
    fi
    if [ -z "$pid" ] && command -v lsof >/dev/null 2>&1; then
        pid=$(sudo --non-interactive lsof --no-header \
            -iTCP:${HOST_PORT} -sTCP:LISTEN 2>/dev/null \
            | awk 'NR==1 { print $2 }')
    fi
    if [ -z "$pid" ] && command -v fuser >/dev/null 2>&1; then
        pid=$(sudo --non-interactive fuser ${HOST_PORT}/tcp 2>/dev/null \
            | awk '{ print $1 }')
    fi
    printf '%s' "$pid"
}

# Returns "user|group|exe" for the process listening on $HOST_PORT, or
# empty if not found. exe is the realpath of /proc/<pid>/exe (e.g.
# '/usr/local/bin/ollama'). All three columns separated by '|' so the
# caller can split with IFS. Returns empty on no match / no permission.
ollama_process_info() {
    local pid user group exe
    pid=$(listening_pid)
    [ -z "$pid" ] && { printf ''; return; }
    user=$(ps --no-headers --format 'user' --pid "$pid" 2>/dev/null | awk '{print $1}')
    group=$(ps --no-headers --format 'group' --pid "$pid" 2>/dev/null | awk '{print $1}')
    exe=$(sudo --non-interactive readlink --canonicalize "/proc/${pid}/exe" 2>/dev/null \
        || readlink --canonicalize "/proc/${pid}/exe" 2>/dev/null \
        || echo "?")
    printf '%s|%s|%s|%s' "$user" "$group" "$exe" "$pid"
}

# True iff the listening process is running as root (uid 0).
ollama_running_as_root() {
    local info user
    info=$(ollama_process_info)
    [ -z "$info" ] && return 1
    user=$(printf '%s' "$info" | cut --delimiter='|' --fields=1)
    [ "$user" = "root" ]
}

# Print a hint pointing to Fix 5 if (a) we're in host mode and (b) the
# listening Ollama is NOT running as root. No-op otherwise. Called from
# the Layer 5 FAIL paths to surface the most common host gotcha.
# Print a host-mode hint when Layer 5 reports FAIL_VULKAN/FAIL_CPU.
# Past versions of this script blamed (a) User=ollama and (b) missing
# OLLAMA_ROCM env vars - both retracted after controlled A/B tests
# (see docs/build-fixes.md Fix 5 -> "What we got wrong"). The actual
# root cause is almost always the MES 0x83 firmware regression
# (Fix 4) - when the rocm runner faults during init, Ollama's
# auto-selector silently falls back to Vulkan or CPU.
#
# Don't try to be clever about the environment - just point at Layer 1
# and the live diagnostic data.
host_layer5_hint() {
    [ "$DETECTED_MODE" != "host" ] && return 0
    local proc_info user group pid groups_line
    proc_info=$(ollama_process_info)
    if [ -n "$proc_info" ]; then
        IFS='|' read -r user group _ pid <<<"$proc_info"
        groups_line=$(sudo --non-interactive cat "/proc/${pid}/status" 2>/dev/null \
            | awk '/^Groups:/ {$1=""; print}' | xargs)
    fi

    info "${C_YELLOW}!! HINT: Host-mode Layer 5 failed. The MES 0x83 firmware regression${C_RESET}"
    info "${C_YELLOW}!! is the #1 cause of FAIL_VULKAN/FAIL_CPU here - when the rocm/${C_RESET}"
    info "${C_YELLOW}!! runner faults during init, Ollama silently falls back to Vulkan/CPU.${C_RESET}"
    info "${C_YELLOW}!! Check that first:${C_RESET}"
    info "${C_YELLOW}!!     make mes-check          # or: ./scripts/install-mes-firmware.sh --check${C_RESET}"
    info "${C_YELLOW}!! If 'BROKEN: 0x83', fix it:${C_RESET}"
    info "${C_YELLOW}!!     make install-mes-firmware && sudo reboot${C_RESET}"
    info "${C_YELLOW}!!${C_RESET}"
    if [ -n "$proc_info" ]; then
        info "${C_YELLOW}!! Live process state for reference:${C_RESET}"
        info "${C_YELLOW}!!   running as: ${user}/${group}  (User=ollama is FINE - don't change it)${C_RESET}"
        if [ -n "$groups_line" ]; then
            info "${C_YELLOW}!!   /proc/${pid}/status Groups: ${groups_line}  (need video + render)${C_RESET}"
        else
            info "${C_YELLOW}!!   /proc/${pid}/status Groups: (run 'sudo -v' first to read)${C_RESET}"
        fi
    fi
    info "${C_YELLOW}!!${C_RESET}"
    info "${C_YELLOW}!! Past wrong theories (kept here so you don't waste time on them):${C_RESET}"
    info "${C_YELLOW}!!   - 'switch to User=root' - NO, User=ollama works fine${C_RESET}"
    info "${C_YELLOW}!!   - 'set OLLAMA_ROCM=1 + GGML_USE_ROCM=1' - NO, Ollama 0.21.0${C_RESET}"
    info "${C_YELLOW}!!     prefers ROCm over Vulkan on its own when the rocm runner works${C_RESET}"
    info "${C_YELLOW}!! Full story: docs/build-fixes.md#fix-5${C_RESET}"
}

detect_mode() {
    case "$MODE" in
        container)
            DETECTED_MODE="container"
            CONTAINER_NAME=$(compose_container_name)
            ;;
        host)
            DETECTED_MODE="host"
            CONTAINER_NAME=
            ;;
        auto)
            CONTAINER_NAME=$(compose_container_name)
            if [ -n "$CONTAINER_NAME" ]; then
                DETECTED_MODE="container"
            elif api_responding; then
                DETECTED_MODE="host"
            else
                # Neither is running. Default to host so Layers 0-2 still
                # run and Layers 3-5 fail with a useful "nothing to test"
                # message instead of a misleading docker error.
                DETECTED_MODE="host"
            fi
            ;;
    esac
}

# ---------------------------------------------------------------------------
# layer 0 - host kernel cmdline
# ---------------------------------------------------------------------------

layer_0() {
    print_header 0 "Host kernel cmdline (no amd_iommu=off)"
    local cmdline
    cmdline=$(cat /proc/cmdline)
    info "cmdline: $cmdline"
    if grep --quiet 'amd_iommu=off' /proc/cmdline; then
        fail 0 "amd_iommu=off present" \
            "Edit /etc/default/grub, remove amd_iommu=off, add iommu=pt, run sudo update-grub && sudo reboot"
        return
    fi
    pass 0 "no amd_iommu=off; iommu state OK"
    if grep --quiet 'amdgpu.cwsr_enable=0' /proc/cmdline; then
        info "warning: amdgpu.cwsr_enable=0 is present; remove it for the recommended baseline"
    fi
}

# ---------------------------------------------------------------------------
# layer 1 - host MES firmware version (must NOT be 0x83)
# ---------------------------------------------------------------------------

layer_1() {
    print_header 1 "Host MES firmware version (the gate)"
    local fw_path="/sys/kernel/debug/dri/${DRI_INDEX}/amdgpu_firmware_info"
    if ! sudo --non-interactive test -r "$fw_path"; then
        fail 1 "cannot read $fw_path" \
            "Run 'sudo -v' first or check that DRI_INDEX is correct (current: $DRI_INDEX)"
        return
    fi
    # Cache the full dump once - we use it for the MES gate AND for the
    # full overview block printed below.
    local fw_dump
    fw_dump=$(sudo --non-interactive cat "$fw_path")
    local mes_line
    mes_line=$(printf '%s\n' "$fw_dump" | grep '^MES feature' || true)
    if [ -z "$mes_line" ]; then
        fail 1 "no 'MES feature' line in amdgpu_firmware_info" \
            "Either this isn't an RDNA3+ GPU or the kernel version doesn't expose MES info"
        return
    fi
    info "$mes_line"
    local mes_ver
    mes_ver=$(printf '%s\n' "$mes_line" | grep --extended-regexp --only-matching '0x[0-9a-fA-F]+' | tail -n 1)
    case "$mes_ver" in
        0x00000083|0x83)
            fail 1 "MES firmware version is $mes_ver (BROKEN; the 0x83 regression)" \
                "Run scripts/install-mes-firmware.sh as root, then sudo update-initramfs -u -k \$(uname -r) && reboot"
            ;;
        0x*)
            local mes_dec=$((mes_ver))
            if [ "$mes_dec" -lt $((0x83)) ]; then
                pass 1 "MES firmware version $mes_ver (< 0x83) is safe"
            else
                fail 1 "MES firmware version $mes_ver (>= 0x83) is suspect" \
                    "Confirmed-good versions are 0x80 or earlier; install the override blobs"
            fi
            ;;
        *)
            fail 1 "could not parse MES firmware version from: $mes_line"
            ;;
    esac

    # Full firmware overview. Useful for cross-referencing community
    # bug reports (Framework forum threads, drm/amd work_items, etc.)
    # which often cite specific blob revisions. We:
    #   - filter out entries with firmware version 0x00000000 (means
    #     'N/A on this SKU' - VCE/UVD/CE/SOS/etc. on Strix Halo APUs)
    #   - always keep VBIOS (different format, no firmware-version field)
    #   - always keep the MES line(s) regardless of value (this is the
    #     gate, the user wants to see the value)
    # Each kept line is indented + dimmed so it doesn't compete with
    # the PASS/FAIL above for attention.
    info "firmware overview (non-zero entries; full dump at $fw_path):"
    printf '%s\n' "$fw_dump" \
        | awk '
            /^VBIOS / { print; next }
            /^MES / { print; next }
            /firmware version: 0x00000000\>/ { next }
            { print }
        ' \
        | sed "s|^|        ${C_DIM}|; s|\$|${C_RESET}|"

    # Runtime MES health check: even with a "good" firmware version
    # installed, separate kernel-side MES regressions can surface as
    # periodic messages in dmesg. We track three related fault modes:
    #
    #   "MES failed to respond to msg=MISC (WAIT_REG_MEM)"
    #   "amdgpu_mes_reg_write_reg_wait"
    #     -> upstream commit e356d321d024 ("drm/amdgpu: cleanup MES11
    #        command submission"), mainline >= 6.10. Deucher's March
    #        2026 SDMA SEM_WAIT_FAIL_TIMER_CNTL series is the fix.
    #
    #   "MES ring buffer is full"
    #     -> escalated form: once the ring fills, the GPU stays wedged
    #        until reboot. Reported on Linux 6.18 + linux-firmware
    #        20260110 against gc_11_5_0 (Phoenix). Same MES subsystem,
    #        different GC variant - so this is *not* gfx1151-specific.
    #        Tracking: gitlab.freedesktop.org/drm/amd/-/work_items/4749
    #
    # We don't fail Layer 1 on the first two (workloads can still
    # complete), but "ring buffer is full" means the GPU is wedged:
    # demote that to a hard warning that tells the user to reboot.
    # See docs/build-fixes.md "Future-proofing" for the full picture.
    # Source dmesg.sh lazily (on first call) so layers that don't run
    # this code path don't pay the source cost.
    # shellcheck source=lib/dmesg.sh
    . "${REPO_ROOT}/scripts/lib/dmesg.sh"
    local mes_dmesg
    mes_dmesg=$(mes_grep_recent 5)
    if [ -n "$mes_dmesg" ]; then
        warn "kernel reported MES errors since boot (separate kernel bug, NOT the 0x83 firmware issue):"
        printf '%s\n' "$mes_dmesg" | sed 's|^|        |'
        if printf '%s' "$mes_dmesg" | grep --quiet --extended-regexp "$MES_RING_FULL_REGEX"; then
            warn "  -> 'MES ring buffer is full' = GPU is WEDGED until reboot (drm/amd work_items/4749)"
            warn "  -> reboot to recover; Layers 5-8 below will likely fail until you do"
        fi
        warn "  -> upstream kernel regression in commit e356d321d024 (mainline >= 6.10)"
        warn "  -> fix series in flight (Deucher, March 2026, SDMA SEM_WAIT_FAIL_TIMER_CNTL)"
        warn "  -> details + tracking: docs/build-fixes.md Fix 4 'Future-proofing'"
    fi
}

# ---------------------------------------------------------------------------
# layer 2 - host HIP smoke test
# ---------------------------------------------------------------------------

layer_2() {
    print_header 2 "Host HIP smoke test (hipMemcpy + kernel launch)"
    if ! prereq_passed 1 && [ -z "$ONLY_LAYER" ]; then
        skip 2 "Layer 1 (MES firmware) failed; HIP test will fault the same way"
        return
    fi
    if ! command -v hipcc >/dev/null 2>&1; then
        fail 2 "hipcc not found in PATH" \
            "Install ROCm on the host or run this script inside the container"
        return
    fi
    if [ ! -r "$HIP_TEST_SRC" ]; then
        fail 2 "HIP source not found at $HIP_TEST_SRC" \
            "Reset HIP_TEST_SRC env var or restore scripts/hip-kernel-test.cpp"
        return
    fi
    # Pick a fresh per-run binary path (or honor an explicit override).
    # Without this, a previous `sudo ./scripts/validate.sh` run leaves
    # /tmp/hip-kernel-test owned by root and the next non-sudo run fails
    # at link time with "ld.lld: failed to write output: Permission denied",
    # which the old code reported as "ROCm install is broken".
    local hip_test_bin="$HIP_TEST_BIN"
    if [ -z "$hip_test_bin" ]; then
        hip_test_bin=$(mktemp --tmpdir hip-kernel-test.XXXXXXXX)
        # shellcheck disable=SC2064  # expand $hip_test_bin now, not on RETURN
        trap "rm --force \"$hip_test_bin\" 2>/dev/null || true" RETURN
    elif [ -e "$hip_test_bin" ] && ! rm --force "$hip_test_bin" 2>/dev/null; then
        fail 2 "cannot remove stale $hip_test_bin (owned by root from a prior sudo run?)" \
            "sudo --non-interactive rm --force $hip_test_bin and re-run"
        return
    fi
    info "compiling $HIP_TEST_SRC for gfx1151 -> $hip_test_bin..."
    # hipcc --help only documents the short -o form for the output flag.
    if ! hipcc --offload-arch=gfx1151 \
            "$HIP_TEST_SRC" \
            -o "$hip_test_bin" 2>&1 | sed 's/^/    /'; then
        fail 2 "hipcc compile failed" "ROCm install on the host is broken"
        return
    fi
    info "running $hip_test_bin..."
    local out rc
    out=$(timeout 30 "$hip_test_bin" 2>&1 || true)
    rc=$?
    info "output: $out"
    if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep --quiet '^out=12345$'; then
        pass 2 "HIP kernel returned out=12345"
    else
        fail 2 "HIP kernel did not return 12345 (exit=$rc)" \
            "Re-check Layer 1 (MES firmware) and dmesg | grep gfxhub"
    fi
}

# ---------------------------------------------------------------------------
# layer 3 - container image exists
# ---------------------------------------------------------------------------

layer_3() {
    print_header 3 "Container image built (mode=$DETECTED_MODE)"
    if [ "$DETECTED_MODE" = "host" ]; then
        skip 3 "host mode: container image is not relevant"
        return
    fi
    if ! command -v docker >/dev/null 2>&1; then
        fail 3 "docker not found in PATH" \
            "Install docker, or run with --mode host to validate the host install"
        return
    fi
    if docker image inspect "$IMAGE_TAG" >/dev/null 2>&1; then
        local size
        size=$(docker image inspect "$IMAGE_TAG" --format '{{.Size}}' \
            | awk '{ printf "%.1f GB", $1/1024/1024/1024 }')
        pass 3 "$IMAGE_TAG image present ($size)"
    else
        fail 3 "$IMAGE_TAG image not found" \
            "Run 'make build' (cold build is ~10-25 minutes)"
    fi
}

# ---------------------------------------------------------------------------
# layer 4 - ollama runtime is up
#   container mode: 'docker compose ps' shows compose service healthy
#   host mode:      systemctl is-active OR /api/version responds
# ---------------------------------------------------------------------------

layer_4() {
    if [ "$DETECTED_MODE" = "container" ]; then
        layer_4_container
    else
        layer_4_host
    fi
}

layer_4_container() {
    print_header 4 "Container running and healthy (compose service: $COMPOSE_SERVICE)"
    if ! prereq_passed 3 && [ -z "$ONLY_LAYER" ]; then
        skip 4 "Layer 3 (image) failed"
        return
    fi
    local status
    status=$(docker compose --file "$COMPOSE_FILE" ps \
        --format '{{.Status}}' "$COMPOSE_SERVICE" 2>/dev/null \
        | head -n 1 || true)
    if [ -z "$status" ]; then
        fail 4 "compose service '$COMPOSE_SERVICE' is not running (no container found)" \
            "Run 'make up' and retry. Or use --mode host if you don't run via docker."
        return
    fi
    info "container: ${CONTAINER_NAME:-?}  status: $status"
    # Same rationale as the host branch: show what governs the daemon's
    # concurrency budget so stress-test and validation results are
    # interpretable without digging through 'docker compose logs'.
    print_ollama_runtime_config
    print_ollama_runtime_state
    if printf '%s' "$status" | grep --quiet --ignore-case 'healthy'; then
        pass 4 "container '$CONTAINER_NAME' is up and healthy"
    elif printf '%s' "$status" | grep --quiet --ignore-case 'starting\|health: starting'; then
        info "still starting; waiting up to 30s for healthcheck..."
        local i
        for i in $(seq 1 30); do
            sleep 1
            status=$(docker compose --file "$COMPOSE_FILE" ps \
                --format '{{.Status}}' "$COMPOSE_SERVICE" 2>/dev/null | head -n 1)
            if printf '%s' "$status" | grep --quiet --ignore-case 'healthy'; then
                pass 4 "container '$CONTAINER_NAME' became healthy after ${i}s"
                return
            fi
        done
        fail 4 "container '$CONTAINER_NAME' never became healthy after 30s" "Read 'make logs'"
    else
        fail 4 "container '$CONTAINER_NAME' is up but not healthy: $status" "Read 'make logs'"
    fi
}

layer_4_host() {
    print_header 4 "Host Ollama running (systemd unit + /api/version)"
    local svc_state="" api_ok=0 api_resp="" version=""
    if command -v systemctl >/dev/null 2>&1; then
        svc_state=$(systemctl is-active ollama.service 2>/dev/null || true)
        if [ -n "$svc_state" ] && [ "$svc_state" != "unknown" ]; then
            info "systemctl is-active ollama.service: $svc_state"
        fi
    fi
    api_resp=$(curl --silent --show-error --max-time 5 \
        "http://localhost:${HOST_PORT}/api/version" 2>&1 || true)
    if [ -n "$api_resp" ] && printf '%s' "$api_resp" | grep --quiet '"version"'; then
        api_ok=1
        version=$(printf '%s' "$api_resp" \
            | python3 -c 'import json,sys; print(json.loads(sys.stdin.read()).get("version","?"))' 2>/dev/null || echo "?")
        info "/api/version: ollama $version listening on :$HOST_PORT"
    else
        info "/api/version: no/invalid response: $api_resp"
    fi
    # Inspect the listening process - user/group is critical on Strix
    # Halo (User=ollama doesn't reliably get GPU access; see Fix 5 in
    # docs/build-fixes.md).
    if [ "$api_ok" -eq 1 ]; then
        local proc_info user group exe pid
        proc_info=$(ollama_process_info)
        if [ -n "$proc_info" ]; then
            IFS='|' read -r user group exe pid <<<"$proc_info"
            info "running as: ${user}/${group}  exe: ${exe}  pid: ${pid}"
            # Note: User=ollama is the install-script default and is
            # FINE on Strix Halo. Don't warn about it here - if there's
            # a real issue, Layer 5 will catch it (FAIL_VULKAN/FAIL_CPU)
            # and emit the diagnostic hint pointing at Fix 5.
        else
            info "(could not identify the listening process - run 'sudo -v' first for full info)"
        fi
    fi
    # Surface the effective runtime config (NUM_PARALLEL, MAX_QUEUE, KEEP_ALIVE,
    # FLASH_ATTENTION, KV_CACHE_TYPE, ...) so the user can see at a glance
    # how much concurrent load this Ollama instance will accept BEFORE
    # running the stress test or wondering why N parallel requests serialize.
    # Then show what the runner ACTUALLY did at the last model load -
    # the env vars are not the same thing as the runtime decisions.
    if [ "$api_ok" -eq 1 ]; then
        print_ollama_runtime_config
        print_ollama_runtime_state
    fi
    if [ "$api_ok" -eq 1 ] && [ "$svc_state" = "active" ]; then
        pass 4 "host Ollama active (systemd) and API responding (v$version)"
    elif [ "$api_ok" -eq 1 ]; then
        pass 4 "host Ollama API responding (v$version) - not under systemd"
    elif [ "$svc_state" = "active" ]; then
        fail 4 "ollama.service is active but API on port $HOST_PORT is not responding" \
            "Check OLLAMA_HOST in /etc/systemd/system/ollama.service (default binds to 127.0.0.1:11434)"
    else
        fail 4 "host Ollama is not running (no systemd unit active and no API on :$HOST_PORT)" \
            "Start it with 'sudo systemctl start ollama' or 'OLLAMA_HOST=0.0.0.0:$HOST_PORT ollama serve &'. Or use --mode container."
    fi
}

# ---------------------------------------------------------------------------
# layer 5 - ollama bootstrap discovery sees ROCm
#   container mode: grep 'docker compose logs'
#   host mode:      grep 'journalctl --unit=ollama'; fall back to /api/ps inspection
# ---------------------------------------------------------------------------

layer_5() {
    if [ "$DETECTED_MODE" = "container" ]; then
        layer_5_container
    else
        layer_5_host
    fi
}

# Returns the most recent 'inference compute' line from a log blob, or
# empty if not found. Common helper for both container and host paths.
extract_inference_compute() {
    grep --extended-regexp 'msg="inference compute"' | tail -n 1 || true
}

# Classify an 'inference compute' log line as PASS / specific FAIL / UNKNOWN.
# Possible verdicts:
#   PASS_ROCM_GFX1151   library=ROCm + compute=gfx1151 (the goal)
#   PASS_ROCM_OTHER     library=ROCm but a different gfx target
#   FAIL_CPU            silent fallback to library=cpu
#   FAIL_VULKAN         library=Vulkan (Ollama was built with Vulkan, not ROCm - wrong build)
#   FAIL_OTHER_LIB      library=cuda/oneapi/etc (not a ROCm build)
#   MISSING             empty input (no line found)
#   UNKNOWN             unparseable line
classify_inference_compute() {
    local line="$1"
    if [ -z "$line" ]; then
        echo "MISSING"
        return
    fi
    if printf '%s' "$line" | grep --quiet 'library=ROCm' \
            && printf '%s' "$line" | grep --quiet 'compute=gfx1151'; then
        echo "PASS_ROCM_GFX1151"
    elif printf '%s' "$line" | grep --quiet 'library=ROCm'; then
        echo "PASS_ROCM_OTHER"
    elif printf '%s' "$line" | grep --quiet 'library=cpu'; then
        echo "FAIL_CPU"
    elif printf '%s' "$line" | grep --quiet 'library=Vulkan'; then
        echo "FAIL_VULKAN"
    elif printf '%s' "$line" | grep --extended-regexp --quiet 'library=(cuda|oneapi|metal)'; then
        echo "FAIL_OTHER_LIB"
    else
        echo "UNKNOWN"
    fi
}

layer_5_container() {
    print_header 5 "Ollama GPU discovery (library=ROCm) [container logs]"
    if ! prereq_passed 4 && [ -z "$ONLY_LAYER" ]; then
        skip 5 "Layer 4 (container health) failed"
        return
    fi
    # The 'inference compute' line is emitted once at bootstrap, which
    # can be hours old in long-running containers. Look at the FULL log
    # (no --tail) and grep. If still nothing, query /api/ps to force a
    # discovery print (works because OLLAMA_DEBUG=2 re-prints on demand).
    local logs line
    logs=$(docker compose --file "$COMPOSE_FILE" logs "$COMPOSE_SERVICE" 2>&1 || true)
    line=$(printf '%s\n' "$logs" | extract_inference_compute)
    if [ -z "$line" ]; then
        info "no bootstrap log line found; querying /api/ps to force a discovery print..."
        curl --silent --max-time 5 "http://localhost:${HOST_PORT}/api/ps" >/dev/null 2>&1 || true
        sleep 1
        logs=$(docker compose --file "$COMPOSE_FILE" logs "$COMPOSE_SERVICE" 2>&1 || true)
        line=$(printf '%s\n' "$logs" | extract_inference_compute)
    fi
    layer_5_finalize "$line" "$logs"
}

layer_5_host() {
    print_header 5 "Ollama GPU discovery (library=ROCm) [host logs]"
    if ! prereq_passed 4 && [ -z "$ONLY_LAYER" ]; then
        skip 5 "Layer 4 (host runtime) failed"
        return
    fi
    local logs="" line=""
    if command -v journalctl >/dev/null 2>&1; then
        # System unit first; fall back to user unit. --no-pager keeps it
        # from launching less in a terminal context.
        logs=$(sudo --non-interactive journalctl --unit=ollama.service \
            --no-pager --since "30 days ago" 2>/dev/null || true)
        if [ -z "$logs" ]; then
            logs=$(journalctl --user --unit=ollama.service \
                --no-pager --since "30 days ago" 2>/dev/null || true)
        fi
    fi
    if [ -n "$logs" ]; then
        line=$(printf '%s\n' "$logs" | extract_inference_compute)
    fi
    if [ -z "$line" ]; then
        info "no 'inference compute' line in journal; will infer from /api/ps after a tiny load test..."
        # /api/ps reports loaded models with size_vram. If size_vram > 0
        # for any loaded model, GPU is in use. To get something loaded
        # we fire a 1-token noop generate first.
        if api_load_tiny_model; then
            local ps_json
            ps_json=$(curl --silent --max-time 5 "http://localhost:${HOST_PORT}/api/ps" 2>/dev/null || true)
            local size_vram
            size_vram=$(printf '%s' "$ps_json" \
                | python3 -c 'import json,sys
try:
    j=json.loads(sys.stdin.read())
    m=j.get("models",[])
    print(max((x.get("size_vram",0) for x in m), default=0))
except Exception:
    print(0)' 2>/dev/null)
            info "/api/ps: max size_vram across loaded models = ${size_vram:-0} bytes"
            if [ "${size_vram:-0}" -gt 0 ] 2>/dev/null; then
                pass 5 "host Ollama loaded a model with size_vram=${size_vram} bytes (GPU in use)"
                return
            fi
            fail 5 "host Ollama has a model loaded but size_vram=0 (running on CPU)" \
                "Check 'sudo cat /sys/kernel/debug/dri/${DRI_INDEX}/amdgpu_firmware_info' (Layer 1) and ollama service logs"
            return
        fi
        fail 5 "no journal entry AND tiny model load failed" \
            "Either grant journal read access (sudo -v first) or check 'ollama list' for any installed model"
        return
    fi
    layer_5_finalize "$line" "$logs"
}

# Common finalizer: classify the line + check for fault markers.
layer_5_finalize() {
    local line="$1" logs="$2" verdict
    if [ -z "$line" ]; then
        if printf '%s' "$logs" | grep --quiet 'ggml_cuda_init: found 1 ROCm device'; then
            pass 5 "no 'inference compute' line, but 'found 1 ROCm devices' present (Ollama booted with GPU)"
            return
        fi
        fail 5 "no 'inference compute' or 'found 1 ROCm devices' in available logs" \
            "Try 'make restart' (container) or 'sudo systemctl restart ollama' (host) and retry"
        return
    fi
    info "$line"
    verdict=$(classify_inference_compute "$line")
    case "$verdict" in
        PASS_ROCM_GFX1151)
            pass 5 "library=ROCm + compute=gfx1151"
            ;;
        PASS_ROCM_OTHER)
            pass 5 "library=ROCm but compute is NOT gfx1151 (still GPU, just unexpected target)"
            ;;
        FAIL_CPU)
            fail 5 "Ollama silently fell back to library=cpu" \
                "GPU discovery faulted; re-check Layer 1 (MES firmware) and dmesg | grep gfxhub"
            host_layer5_hint
            ;;
        FAIL_VULKAN)
            fail 5 "Ollama is using library=Vulkan, NOT ROCm" \
                "This Ollama binary was built with Vulkan support; the goal is ROCm. In container mode use 'make build && make up'. In host mode replace your host install with a ROCm-built ollama (or just use --mode container)."
            host_layer5_hint
            ;;
        FAIL_OTHER_LIB)
            fail 5 "Ollama is using a non-ROCm library (see above)" \
                "Wrong Ollama build for this hardware. Rebuild against ROCm 7.x."
            host_layer5_hint
            ;;
        UNKNOWN|*)
            fail 5 "unexpected inference compute line (see above)" \
                "If 'library=' is something unexpected, file an issue with the line above"
            ;;
    esac
    if printf '%s' "$logs" | grep --quiet 'Memory access fault by GPU'; then
        info "${C_RED}!! 'Memory access fault by GPU' present in logs - host firmware may have regressed${C_RESET}"
    fi
}

# _resolve_smoke_model <preferred> - print the model name to use for the
# Layer 6 smoke test, picking in priority order:
#   1. <preferred> (env var SMOKE_MODEL or historical default) if installed
#   2. api_smallest_model (whatever the user has, even if it's not Llama 3.2)
#   3. "" if no models installed at all
_resolve_smoke_model() {
    local preferred="$1" size_b
    if [ -n "$preferred" ]; then
        size_b=$(api_model_size_bytes "$preferred")
        if [ "${size_b:-0}" -gt 0 ]; then
            printf '%s' "$preferred"
            return
        fi
    fi
    api_smallest_model
}

# _resolve_long_ctx_model <preferred> - print the model name to use for the
# Layer 8 long-context test:
#   1. <preferred> if installed
#   2. largest installed model whose declared max_context >= 128K
#   3. api_largest_model as a last resort (Layer 8 will accept truncation)
#   4. "" if no models installed
_resolve_long_ctx_model() {
    local preferred="$1" size_b
    if [ -n "$preferred" ]; then
        size_b=$(api_model_size_bytes "$preferred")
        if [ "${size_b:-0}" -gt 0 ]; then
            printf '%s' "$preferred"
            return
        fi
    fi
    # Walk installed models from largest to smallest, return first one
    # advertising at least 128K context. Capped at 8 candidates to bound
    # the per-model /api/show wall time (each call is ~50-150 ms).
    local names name max_ctx checked=0
    names=$(curl --silent --max-time 5 "$(_api_url)/api/tags" 2>/dev/null \
        | python3 -c 'import json,sys
try:
    d = json.loads(sys.stdin.read())
except Exception:
    print(""); sys.exit(0)
ms = sorted(d.get("models",[]), key=lambda m: -m.get("size", 0))
for m in ms[:8]:
    print(m["name"])')
    while IFS= read -r name; do
        [ -z "$name" ] && continue
        checked=$((checked + 1))
        max_ctx=$(api_model_max_context "$name")
        if [ "${max_ctx:-0}" -ge 131072 ]; then
            printf '%s' "$name"
            return
        fi
    done <<< "$names"
    # No 128K-capable model among the top 8; settle for the biggest installed.
    if [ "$checked" -gt 0 ]; then
        api_largest_model
    fi
}

# Tiny model load helper for host-mode Layer 5: load whatever's smallest
# so we don't blow VRAM on a Layer-5 sanity check on machines where the
# largest model is half a TB.
api_load_tiny_model() {
    local first_model
    first_model=$(api_smallest_model)
    if [ -z "$first_model" ]; then
        info "no installed models found via /api/tags"
        return 1
    fi
    info "loading smallest installed model for GPU check: $first_model"
    curl --silent --show-error --max-time 60 \
        --request POST \
        --header 'content-type: application/json' \
        --data "{\"model\":\"${first_model}\",\"prompt\":\"hi\",\"stream\":false,\"options\":{\"num_predict\":1,\"temperature\":0.0}}" \
        "http://localhost:${HOST_PORT}/api/generate" >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# layer 6 - small-model inference smoke test
# ---------------------------------------------------------------------------

layer_6() {
    SMOKE_MODEL=$(_resolve_smoke_model "$SMOKE_MODEL_PREFERRED")
    if [ -z "$SMOKE_MODEL" ]; then
        print_header 6 "Small-model inference smoke test (no model resolved)"
        skip 6 "no installed models found via /api/tags" \
            "Pull a small model and re-run, e.g.: ollama pull llama3.2:latest"
        return
    fi
    print_header 6 "Small-model inference smoke test ($SMOKE_MODEL)"
    if [ "$SMOKE_MODEL" != "$SMOKE_MODEL_PREFERRED" ]; then
        info "preferred model '$SMOKE_MODEL_PREFERRED' not installed; auto-picked smallest: $SMOKE_MODEL"
    fi
    if ! prereq_passed 5 && [ -z "$ONLY_LAYER" ]; then
        skip 6 "Layer 5 (GPU discovery) failed"
        return
    fi
    if ! command -v curl >/dev/null 2>&1 || ! command -v python3 >/dev/null 2>&1; then
        fail 6 "curl and python3 are required"
        return
    fi
    local resp curl_rc
    set +o errexit
    resp=$(curl --silent --show-error --max-time 120 \
        --request POST \
        --header 'content-type: application/json' \
        --data "{\"model\":\"${SMOKE_MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":\"Say hello in three words.\"}],\"stream\":false,\"options\":{\"num_predict\":20,\"temperature\":0.0}}" \
        "http://localhost:${HOST_PORT}/api/chat" 2>&1)
    curl_rc=$?
    set -o errexit
    if [ "$curl_rc" -ne 0 ]; then
        fail 6 "curl failed (exit=$curl_rc): $resp" \
            "GPU may be busy with another inference; retry when idle. Or change model: SMOKE_MODEL=... ./scripts/validate.sh --layer 6"
        return
    fi
    if [ -z "$resp" ]; then
        fail 6 "empty response from /api/chat"
        return
    fi
    local content tps
    content=$(printf '%s' "$resp" | python3 -c '
import json, sys
try:
    r = json.loads(sys.stdin.read())
    print(r.get("message", {}).get("content", "") or "")
except Exception as e:
    print(f"PARSE_ERROR: {e}", file=sys.stderr)
    sys.exit(1)
' 2>/dev/null)
    tps=$(printf '%s' "$resp" | python3 -c '
import json, sys
r = json.loads(sys.stdin.read())
ec = r.get("eval_count", 0) or 0
ed = (r.get("eval_duration", 0) or 1) / 1e9
print(f"{ec/ed:.1f}" if ec else "0")
' 2>/dev/null)
    info "content: ${content:0:80}"
    info "decode rate: ${tps} tok/s"
    if [ -n "$content" ]; then
        pass 6 "small-model generated non-empty text ($tps tok/s)"
    else
        fail 6 "model loaded but generated empty content" \
            "Try a different model: SMOKE_MODEL=gemma4:e4b-it-q4_K_M ./scripts/validate.sh --layer 6"
    fi
}

# ---------------------------------------------------------------------------
# layer 7 - memory math at 256K (informational)
# ---------------------------------------------------------------------------

layer_7() {
    print_header 7 "VRAM headroom for 256K context (informational)"
    if ! prereq_passed 5 && [ -z "$ONLY_LAYER" ]; then
        skip 7 "Layer 5 failed"
        return
    fi
    local total_b free_b total_g free_g
    if ! sudo --non-interactive rocm-smi --showmeminfo vram --csv >/tmp/_rocm_vram.csv 2>&1; then
        fail 7 "rocm-smi --showmeminfo vram failed" "Install rocm-smi on the host or run this layer in the container"
        return
    fi
    total_b=$(awk -F, 'NR==2 { print $2 }' /tmp/_rocm_vram.csv)
    free_b=$(awk -F, 'NR==2 { print $4 }' /tmp/_rocm_vram.csv)
    total_g=$(awk "BEGIN { printf \"%.1f\", ${total_b}/1024/1024/1024 }")
    free_g=$(awk "BEGIN { printf \"%.1f\", ${free_b}/1024/1024/1024 }")
    info "VRAM total=${total_g} GiB  free=${free_g} GiB"
    # Try to size the budget against the actual model the user will hit at
    # Layer 8. Fall back to the historical hardcoded gemma4:31b figure if
    # no long-ctx model is resolvable yet.
    local resolved size_b size_g max_ctx target_ctx kv_g budget_g recommended_g
    resolved=$(_resolve_long_ctx_model "$LONG_CTX_MODEL_PREFERRED")
    if [ -n "$resolved" ]; then
        size_b=$(api_model_size_bytes "$resolved")
        max_ctx=$(api_model_max_context "$resolved")
        target_ctx=$LONG_CTX_NUM_CTX
        # Cap at the model's own max if it's lower than our test request
        # (e.g. gemma4:e4b is 128K-capped; budget at 128K, not 256K).
        if [ "${max_ctx:-0}" -gt 0 ] && [ "$max_ctx" -lt "$target_ctx" ]; then
            target_ctx=$max_ctx
        fi
        size_g=$(awk "BEGIN { printf \"%.1f\", ${size_b:-0}/1024/1024/1024 }")
        # Rough KV cache estimate at f16: ~80 KiB / token for a typical
        # 30B-ish quant. Scales linearly with target_ctx. Order-of-magnitude
        # only - tells the user "enough room?" not exact bytes.
        kv_g=$(awk "BEGIN { printf \"%.1f\", ${target_ctx} * 80 / 1024 / 1024 }")
        budget_g=$(awk "BEGIN { printf \"%.1f\", ${size_g} + ${kv_g} + 3 }")
        recommended_g=$(awk "BEGIN { printf \"%.1f\", ${budget_g} + 5 }")
        info "long-ctx model: $resolved (~${size_g} GiB on disk, max_ctx=${max_ctx})"
        info "worst-case budget at ctx=${target_ctx}: ~${budget_g} GiB (weights ~${size_g} + KV f16 ~${kv_g} + overhead ~3)"
    else
        # No model installed yet - fall back to the historical reference figures.
        budget_g=43
        recommended_g=50
        info "no long-ctx model installed; using reference budget for gemma4:31b-q4_K_M at 256K"
        info "256K worst-case budget for gemma4:31b-q4_K_M: ~43 GiB (weights ~20 + KV f16 ~20 + overhead)"
    fi
    rm --force /tmp/_rocm_vram.csv
    if awk "BEGIN { exit !(${total_g} >= ${recommended_g}) }"; then
        pass 7 "VRAM total ${total_g} GiB is sufficient (>= ${recommended_g} GiB recommended for budget ~${budget_g} GiB)"
    else
        fail 7 "VRAM total ${total_g} GiB is below the recommended ${recommended_g} GiB for budget ~${budget_g} GiB" \
            "Increase BIOS UMA split for the iGPU, or pick a smaller LONG_CTX_MODEL"
    fi
}

# ---------------------------------------------------------------------------
# layer 8 - long-context inference (the headline feature)
# ---------------------------------------------------------------------------

layer_8() {
    LONG_CTX_MODEL=$(_resolve_long_ctx_model "$LONG_CTX_MODEL_PREFERRED")
    if [ -z "$LONG_CTX_MODEL" ]; then
        print_header 8 "Long-context inference (no model resolved)"
        skip 8 "no installed models found via /api/tags" \
            "Pull a long-context-capable model, e.g.: ollama pull gemma4:31b-it-q4_K_M"
        return
    fi
    print_header 8 "Long-context inference (~${LONG_CTX_TOKENS} tokens, model: $LONG_CTX_MODEL)"
    if [ "$LONG_CTX_MODEL" != "$LONG_CTX_MODEL_PREFERRED" ]; then
        info "preferred model '$LONG_CTX_MODEL_PREFERRED' not installed; auto-picked: $LONG_CTX_MODEL"
    fi
    if [ "$SKIP_LONG_CTX" -eq 1 ]; then
        skip 8 "skipped via --skip-long-ctx"
        return
    fi
    if ! prereq_passed 5 && [ -z "$ONLY_LAYER" ]; then
        skip 8 "Layer 5 failed"
        return
    fi
    info "this can take 4-25 minutes; running with timeout 1800s"
    # Initialize-on-declare so $script is *always* a defined parameter,
    # even if bash re-reads this script mid-execution (e.g. the file is
    # edited while the long python3 subprocess below is running). With
    # `set -u`, a `local script` followed by a *separate* assignment is
    # safe in normal flow, but can desync if the script is rewritten on
    # disk between parser passes. Initializing inline avoids that.
    local script=""
    script=$(mktemp --suffix=.py)
    # Ensure the temp file is removed on any function exit path,
    # including errexit-trip on a future edit, so we don't leak files
    # in /tmp. ${script:-} guards against the same re-read race.
    # shellcheck disable=SC2064  # we want $script expanded *now*
    trap "rm --force \"${script:-}\" 2>/dev/null || true" RETURN
    cat >"$script" <<PY
import json, time, urllib.request, sys
PASSAGE = (
    "The Strix Halo APU integrates a Zen 5 CPU complex with an RDNA 3.5 GPU "
    "(gfx1151) sharing a unified 128 GiB LPDDR5X memory pool. ROCm 7.2.2 "
    "introduces compiler and runtime support for this architecture. "
)
TARGET_CHARS = ${LONG_CTX_TOKENS} * 3 + 200
text = (PASSAGE * (TARGET_CHARS // len(PASSAGE) + 1))[:TARGET_CHARS]
prompt = (
    "You will be shown a long passage. After the passage, answer the question "
    "in ONE short sentence.\n\nPASSAGE:\n" + text +
    "\n\nQUESTION: What GPU architecture is mentioned in the passage?\nANSWER:"
)
print(f"prompt={len(prompt):,} chars (~{int(len(prompt)/3.21):,} tok)", flush=True)
payload = {
    "model": "${LONG_CTX_MODEL}",
    "prompt": prompt,
    "stream": False,
    "raw": True,
    "options": {"num_ctx": ${LONG_CTX_NUM_CTX}, "num_predict": 8, "temperature": 0.0},
}
req = urllib.request.Request(
    "http://localhost:${HOST_PORT}/api/generate",
    data=json.dumps(payload).encode(),
    headers={"content-type": "application/json"},
)
t0 = time.time()
try:
    with urllib.request.urlopen(req, timeout=1800) as resp:
        r = json.loads(resp.read())
except Exception as exc:
    print(f"REQUEST_FAILED after {time.time()-t0:.1f}s: {exc}", flush=True)
    sys.exit(1)
wall = time.time() - t0
ped = (r.get("prompt_eval_duration", 0) or 1) / 1e9
pec = r.get("prompt_eval_count") or 0
ed  = (r.get("eval_duration", 0) or 1) / 1e9
ec  = r.get("eval_count") or 0
print(f"wall={wall:.1f}s prompt_eval={pec:,} ({pec/ped:.1f} tok/s) decode={ec}/{ed:.2f}s ({ec/ed:.1f} tok/s)", flush=True)
print(f"response={r.get('response','')!r}", flush=True)
sys.exit(0 if pec > 0 else 1)
PY
    info "running long-context test..."
    # Don't use `if pipeline; then` here - with set -e + pipefail, a
    # bash-script edit during the long python3 call can desync line
    # numbers and trip nounset on what *was* the next statement. Run
    # the pipeline explicitly and capture the rc into a local first.
    local rc=0
    timeout 1800 python3 "$script" 2>&1 | tee "$LONG_CTX_OUT" | sed 's/^/    /' || rc=$?
    if [ "$rc" -eq 0 ]; then
        local pec=""
        # `|| true` so a missing match (which would already have failed
        # the python3 call above) doesn't double-trip errexit here.
        pec=$(grep --only-matching --extended-regexp 'prompt_eval=[0-9,]+' "$LONG_CTX_OUT" \
            | head -n 1 \
            | tr --delete ',' \
            | cut --delimiter='=' --fields=2 \
            || true)
        pass 8 "long-context inference completed (prompt_eval=${pec:-?} tokens)"
    else
        fail 8 "long-context inference failed or timed out (rc=$rc)" \
            "Check 'make logs' and dmesg for faults"
    fi
    # cleanup is via the RETURN trap registered above
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

detect_mode

printf '%samd-rocm-ollama validation ladder%s\n' "${C_BOLD}" "${C_RESET}"
printf '  repo:       %s\n' "$REPO_ROOT"
printf '  port:       %s\n' "$HOST_PORT"
printf '  mode:       %s' "$DETECTED_MODE"
if [ "$MODE" = "auto" ]; then
    printf ' %s(auto-detected)%s' "${C_DIM}" "${C_RESET}"
else
    printf ' %s(forced via --mode %s)%s' "${C_DIM}" "$MODE" "${C_RESET}"
fi
printf '\n'
if [ "$DETECTED_MODE" = "container" ]; then
    printf '  service:    %s (container: %s)\n' "$COMPOSE_SERVICE" "${CONTAINER_NAME:-?}"
fi
[ -n "$ONLY_LAYER" ] && printf '  only layer: %s\n' "$ONLY_LAYER"
[ "$FROM_LAYER" -gt 0 ] && printf '  from layer: %s\n' "$FROM_LAYER"

# Several layers (1: MES dmesg + debugfs read; 5: journalctl in host mode;
# 7: rocm-smi inside container) shell out to `sudo --non-interactive`.
# Warn early so users don't see cryptic "permission denied" inside layers.
if [ "$(id -u)" -ne 0 ] && ! sudo --non-interactive true 2>/dev/null; then
    printf '  %ssudo:%s no cached credentials - some layers will report partial\n' \
        "${C_YELLOW}" "${C_RESET}"
    printf '         results. Pre-cache with: %ssudo -v%s, then re-run.\n' \
        "${C_DIM}" "${C_RESET}"
fi

for layer in 0 1 2 3 4 5 6 7 8; do
    if should_run "$layer"; then
        "layer_$layer"
    fi
done

# ---------------------------------------------------------------------------
# summary
# ---------------------------------------------------------------------------

printf '\n%s===== summary =====%s\n' "${C_BOLD}" "${C_RESET}"
declare -i n_pass=0 n_fail=0 n_skip=0
for r in "${RESULTS[@]}"; do
    IFS='|' read -r ll status msg <<<"$r"
    case "$status" in
        PASS) printf '  %sLayer %s: PASS%s  %s\n' "${C_GREEN}" "$ll" "${C_RESET}" "$msg"; n_pass=$((n_pass+1)) ;;
        FAIL) printf '  %sLayer %s: FAIL%s  %s\n' "${C_RED}"   "$ll" "${C_RESET}" "$msg"; n_fail=$((n_fail+1)) ;;
        SKIP) printf '  %sLayer %s: SKIP%s  %s\n' "${C_YELLOW}" "$ll" "${C_RESET}" "$msg"; n_skip=$((n_skip+1)) ;;
    esac
done

printf '\n  %d passed  %d failed  %d skipped\n' "$n_pass" "$n_fail" "$n_skip"

if [ "$n_fail" -gt 0 ]; then
    printf '\n%sValidation FAILED.%s See docs/validation-tests.md for the per-layer fix.\n' "${C_RED}" "${C_RESET}"
    exit 1
fi

printf '\n%sAll selected layers passed.%s\n' "${C_GREEN}" "${C_RESET}"
exit 0
