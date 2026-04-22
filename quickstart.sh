#!/usr/bin/env bash
# quickstart.sh - one-command bring-up + validate for amd-rocm-ollama.
#
# Default behaviour (no flags):
#   1. Prereq check         (docker, docker compose, render/video groups)
#   2. Submodule init       (idempotent; populates external/ollama if missing)
#   3. .env scaffold        (copy from .env.example if absent; print detected GIDs)
#   4. Endpoint detection   (probe :11434; pick HOST | CONTAINER | OTHER mode)
#   5. Bring-up (only if nothing is on :11434):
#        - image present check (FAIL FAST unless --build given)
#        - docker compose up + wait for /api/tags
#   6. Auto-pull smoke      (llama3.2:latest, ~2 GiB, ONLY if no models installed; --no-pull to suppress)
#   7. ./scripts/validate.sh --skip-long-ctx --mode <host|container>
#   8. Footer with next-step hints
#
# Mode selection (printed loudly before validate runs):
#   - if our compose container is already on :11434 -> CONTAINER (reuses it)
#   - if host systemd 'ollama.service' is on :11434 -> HOST       (no container started)
#   - if anything else is on :11434                 -> OTHER      (validates the live API anyway)
#   - if nothing is on :11434                       -> CONTAINER  (brings the stack up)
#   --build forces CONTAINER and refuses to start if :11434 is held by something else.
#
# Flags:
#   --build         Run `docker compose build` before `up` (~30 min on first run).
#                   Forces CONTAINER mode; aborts if :11434 is bound by host ollama.
#   --no-build      Explicit no-op for clarity in scripts (default).
#   --no-pull       Skip the auto-pull of llama3.2:latest even if no models are installed.
#   --skip-up       Don't start/build the container; validate whatever's already running
#                   (use this to force HOST mode against a host-installed ollama).
#   --help, -h      Show this message.
#
# Exit codes:
#   0   prereqs + bring-up + validate all green
#   1   one or more steps failed (validate output names the failing layer)
#   2   bad invocation / mutually-exclusive flags
#
# Re-exec under bash if invoked via `sh quickstart.sh`.
# shellcheck disable=SC2128
if [ -z "${BASH_VERSION:-}" ]; then
    exec bash "$0" "$@"
fi

set -o errexit
set -o nounset
set -o pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE="${COMPOSE:-docker compose}"
SERVICE="${SERVICE:-ollama}"
HOST_PORT="${HOST_PORT:-11434}"
IMAGE_TAG="${IMAGE_TAG:-amd-rocm-ollama:7.2.2}"
SMOKE_PULL_MODEL="${SMOKE_PULL_MODEL:-llama3.2:latest}"

# shellcheck source=scripts/lib/pretty.sh
. "${REPO_ROOT}/scripts/lib/pretty.sh"

DO_BUILD=0
DO_PULL=1
DO_UP=1

usage() {
    sed --quiet '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
    case "$1" in
        --build)    DO_BUILD=1; shift ;;
        --no-build) DO_BUILD=0; shift ;;
        --no-pull)  DO_PULL=0; shift ;;
        --skip-up)  DO_UP=0; shift ;;
        --help|-h)  usage; exit 0 ;;
        *)
            err "unknown flag: $1"
            echo "Run '$0 --help' for usage." >&2
            exit 2 ;;
    esac
done

if [ "$DO_BUILD" -eq 1 ] && [ "$DO_UP" -eq 0 ]; then
    err "--build and --skip-up are mutually exclusive (build implies bringing the container up)"
    exit 2
fi

# _port_listener <port> - print the LISTEN row(s) for a TCP port, empty if
# nothing is bound. Used to pre-empt the most common quickstart failure: the
# host's bundled ollama.service still binding :11434 and shadowing our
# container at the bind layer (docker emits an unhelpful 'address already
# in use' with no hint that systemctl stop ollama is the fix).
_port_listener() {
    local port="$1"
    if command -v ss >/dev/null 2>&1; then
        ss --tcp --listening --processes --numeric "sport = :${port}" 2>/dev/null \
            | awk 'NR>1 {print}'
    elif command -v lsof >/dev/null 2>&1; then
        lsof -nP -iTCP:"${port}" -sTCP:LISTEN 2>/dev/null
    fi
}

# _api_alive <port> - 0 if /api/tags responds within 2s, 1 otherwise.
_api_alive() {
    curl --silent --max-time 2 --fail --output /dev/null \
        "http://localhost:${1}/api/tags"
}

# _detect_endpoint_mode - print one of: container | host | other | ""
# Empty string means "nothing on :HOST_PORT, free to bring our own up".
# Decision order: our compose container > host systemd > anything else.
_detect_endpoint_mode() {
    if ! _api_alive "$HOST_PORT" && [ -z "$(_port_listener "$HOST_PORT")" ]; then
        printf ''
        return
    fi
    # Something is on the port. Figure out who.
    local cid state
    cid="$(cd "$REPO_ROOT" && $COMPOSE ps --quiet "$SERVICE" 2>/dev/null | head --lines 1)"
    if [ -n "$cid" ]; then
        state="$(docker inspect --format '{{.State.Running}}' "$cid" 2>/dev/null || printf 'false')"
        if [ "$state" = "true" ]; then
            printf 'container'
            return
        fi
    fi
    if command -v systemctl >/dev/null 2>&1 \
            && systemctl is-active --quiet ollama 2>/dev/null; then
        printf 'host'
        return
    fi
    printf 'other'
}

# ---------------------------------------------------------------------------
# step 1: prereqs
# ---------------------------------------------------------------------------

header "Quickstart: prereq check"

PREREQ_FAIL=0

if command -v docker >/dev/null 2>&1; then
    ok "docker:         $(docker --version 2>/dev/null | head -1)"
else
    err "docker:         NOT FOUND - install Docker Engine first (https://docs.docker.com/engine/install/)"
    PREREQ_FAIL=1
fi

if docker compose version >/dev/null 2>&1; then
    ok "docker compose: $(docker compose version --short 2>/dev/null)"
else
    err "docker compose: NOT FOUND - install the compose plugin (apt install docker-compose-plugin)"
    PREREQ_FAIL=1
fi

# Capture host GIDs once so we can both verify and seed .env from them.
DETECTED_VIDEO_GID="$(getent group video  2>/dev/null | cut --delimiter=: --fields=3 || true)"
DETECTED_RENDER_GID="$(getent group render 2>/dev/null | cut --delimiter=: --fields=3 || true)"

if [ -n "$DETECTED_VIDEO_GID" ] && [ -n "$DETECTED_RENDER_GID" ]; then
    ok "host groups:    video=${DETECTED_VIDEO_GID}, render=${DETECTED_RENDER_GID}"
else
    err "host groups:    video/render not found in /etc/group - install AMD GPU stack first"
    PREREQ_FAIL=1
fi

if [ ! -e /dev/kfd ]; then
    err "/dev/kfd:       NOT PRESENT - amdkfd driver not loaded; check 'lsmod | grep amdgpu'"
    PREREQ_FAIL=1
else
    ok "/dev/kfd:       present"
fi

if ! ls /dev/dri/renderD* >/dev/null 2>&1; then
    err "/dev/dri:       no renderD* nodes - amdgpu DRI not exposed"
    PREREQ_FAIL=1
else
    ok "/dev/dri:       $(ls /dev/dri/renderD* 2>/dev/null | tr '\n' ' ')"
fi

if [ "$PREREQ_FAIL" -ne 0 ]; then
    err "prerequisite check failed - fix the items marked above and re-run"
    exit 1
fi

# ---------------------------------------------------------------------------
# step 2: submodule
# ---------------------------------------------------------------------------

header "Submodule (external/ollama)"

if [ -f "${REPO_ROOT}/external/ollama/go.mod" ]; then
    ok "external/ollama already populated"
else
    info "running: git submodule update --init --recursive"
    git -C "$REPO_ROOT" submodule update --init --recursive
    ok "submodule initialized"
fi

# ---------------------------------------------------------------------------
# step 3: .env scaffold
# ---------------------------------------------------------------------------

header ".env (per-host overrides)"

if [ -f "${REPO_ROOT}/.env" ]; then
    ok ".env exists - leaving as-is"
else
    if [ -f "${REPO_ROOT}/.env.example" ]; then
        cp "${REPO_ROOT}/.env.example" "${REPO_ROOT}/.env"
        ok "copied .env.example -> .env"
        # If detected GIDs differ from the .env.example defaults (44/992),
        # patch them in so the container actually matches the host.
        if [ -n "$DETECTED_VIDEO_GID" ] && [ "$DETECTED_VIDEO_GID" != "44" ]; then
            sed --in-place "s|^VIDEO_GID=.*|VIDEO_GID=${DETECTED_VIDEO_GID}|" "${REPO_ROOT}/.env"
            info "patched VIDEO_GID=${DETECTED_VIDEO_GID} (host differs from default 44)"
        fi
        if [ -n "$DETECTED_RENDER_GID" ] && [ "$DETECTED_RENDER_GID" != "992" ]; then
            sed --in-place "s|^RENDER_GID=.*|RENDER_GID=${DETECTED_RENDER_GID}|" "${REPO_ROOT}/.env"
            info "patched RENDER_GID=${DETECTED_RENDER_GID} (host differs from default 992)"
        fi
    else
        info ".env.example missing - skipping .env scaffold (compose defaults will apply)"
    fi
fi

# ---------------------------------------------------------------------------
# step 4: endpoint detection
#
# Decide WHAT we are validating before we touch docker. Three signals matter:
#   - is anything answering /api/tags on :HOST_PORT ?
#   - does our compose container own that listener?
#   - is host systemd 'ollama.service' the one binding it?
# The mode picked here drives both the auto-pull transport (compose exec vs
# HTTP /api/pull) and the --mode flag passed to validate.sh.
# ---------------------------------------------------------------------------

header "Endpoint detection (:${HOST_PORT})"

DETECTED="$(_detect_endpoint_mode)"
LISTENER_INFO="$(_port_listener "$HOST_PORT")"
MODE=""              # final decision: container | host | other
SHOULD_BRING_UP=0    # do we need `compose up` later?

case "$DETECTED" in
    container)
        ok "our compose container '${SERVICE}' is already on :${HOST_PORT}"
        info "reusing it - no build / no up"
        MODE="container"
        ;;
    host)
        if [ "$DO_BUILD" -eq 1 ]; then
            err "host systemd 'ollama.service' is binding :${HOST_PORT}, but --build was given"
            err "--build implies CONTAINER mode; free the port first:"
            info "  sudo systemctl stop ollama && sudo systemctl disable ollama"
            info "then re-run:  ./quickstart.sh --build"
            exit 1
        fi
        ok "host systemd 'ollama.service' is running on :${HOST_PORT}"
        info "preferring HOST ollama (no container will be started)"
        info "to test the container instead: sudo systemctl stop ollama && ./quickstart.sh"
        MODE="host"
        ;;
    other)
        if [ "$DO_BUILD" -eq 1 ]; then
            err ":${HOST_PORT} is bound by something we did not start, but --build was given:"
            printf '%s\n' "$LISTENER_INFO" | sed 's/^/         /'
            err "free the port first or drop --build"
            exit 1
        fi
        ok ":${HOST_PORT} is responding (not our container, not host systemd)"
        if [ -n "$LISTENER_INFO" ]; then
            info "current listener:"
            printf '%s\n' "$LISTENER_INFO" | sed 's/^/         /'
        fi
        info "validating whatever is on :${HOST_PORT} as-is"
        MODE="other"
        ;;
    "")
        if [ "$DO_UP" -eq 0 ]; then
            err "no ollama on :${HOST_PORT} and --skip-up was given - nothing to validate"
            info "drop --skip-up to bring up the container, or start a host ollama first"
            exit 1
        fi
        ok ":${HOST_PORT} is free - will bring up the compose container"
        MODE="container"
        SHOULD_BRING_UP=1
        ;;
esac

# ---------------------------------------------------------------------------
# step 5: bring-up (only when we picked CONTAINER and nothing is up yet)
# ---------------------------------------------------------------------------

if [ "$SHOULD_BRING_UP" -eq 1 ]; then
    header "Container image"

    if [ "$DO_BUILD" -eq 1 ]; then
        info "running: $COMPOSE build  (~30 min on first run)"
        cd "$REPO_ROOT"
        $COMPOSE build
        ok "build complete"
    else
        if docker image inspect "$IMAGE_TAG" >/dev/null 2>&1; then
            ok "image present: $IMAGE_TAG"
        else
            err "image not found: $IMAGE_TAG"
            err "run with --build to compile it (~30 min), or 'make build' standalone"
            exit 1
        fi
    fi

    header "docker compose up"

    # Re-check the port right before `up`. Detection ran a few seconds ago,
    # and a host service / another container may have grabbed :HOST_PORT in
    # the interim - in that case docker emits a generic 'address already in
    # use' that gives no hint about the cause.
    LISTENER_INFO="$(_port_listener "$HOST_PORT")"
    if [ -n "$LISTENER_INFO" ]; then
        err "port ${HOST_PORT} on the host became busy since detection:"
        printf '%s\n' "$LISTENER_INFO" | sed 's/^/         /'
        if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet ollama 2>/dev/null; then
            err "the host's bundled 'ollama' systemd service is binding :${HOST_PORT}"
            info "stop it once:  sudo systemctl stop ollama && sudo systemctl disable ollama"
            info "or re-run quickstart with no flags to use the host ollama instead"
        else
            info "free port ${HOST_PORT} or run with a different port: HOST_PORT=11500 ./quickstart.sh"
        fi
        exit 1
    fi

    info "running: $COMPOSE up --detach $SERVICE"
    cd "$REPO_ROOT"
    if ! $COMPOSE up --detach "$SERVICE"; then
        err "$COMPOSE up failed - inspect with: $COMPOSE logs --tail 100 $SERVICE"
        exit 1
    fi

    info "waiting for /api/tags on http://localhost:${HOST_PORT} (up to 90s)"
    deadline=$(( $(date +%s) + 90 ))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        if _api_alive "$HOST_PORT"; then
            ok "ollama API is responding"
            break
        fi
        sleep 2
    done
    if ! _api_alive "$HOST_PORT"; then
        err "ollama API did not respond within 90s"
        info "check logs: $COMPOSE logs --tail 100 $SERVICE"
        exit 1
    fi
fi

# ---------------------------------------------------------------------------
# step 6: smoke-model auto-pull (only if no models installed)
# ---------------------------------------------------------------------------

header "Smoke model"

INSTALLED_COUNT="$(curl --silent --max-time 5 \
        "http://localhost:${HOST_PORT}/api/tags" 2>/dev/null \
    | python3 -c 'import json,sys
try:
    d = json.loads(sys.stdin.read())
except Exception:
    print(0); sys.exit(0)
print(len(d.get("models",[])))' 2>/dev/null || echo 0)"

if [ "${INSTALLED_COUNT:-0}" -gt 0 ]; then
    ok "${INSTALLED_COUNT} model(s) already installed - skipping auto-pull"
elif [ "$DO_PULL" -eq 0 ]; then
    info "no models installed and --no-pull set - validate Layer 6/8 will SKIP"
else
    info "no models installed; pulling $SMOKE_PULL_MODEL (~2 GiB) so the smoke test has something to load"
    info "use --no-pull next time to skip this"
    if [ "$MODE" = "container" ]; then
        $COMPOSE exec -T "$SERVICE" ollama pull "$SMOKE_PULL_MODEL"
    else
        # host / other: no docker exec, hit the API directly
        curl --no-progress-meter --fail --max-time 600 \
            --request POST \
            --header 'content-type: application/json' \
            --data "{\"name\":\"$SMOKE_PULL_MODEL\",\"stream\":false}" \
            "http://localhost:${HOST_PORT}/api/pull"
    fi
    ok "pulled $SMOKE_PULL_MODEL"
fi

# ---------------------------------------------------------------------------
# step 7: validate ladder
# ---------------------------------------------------------------------------

header "Validation target"

case "$MODE" in
    container)
        info "mode      = CONTAINER  (docker compose service '${SERVICE}', image ${IMAGE_TAG})"
        VALIDATE_MODE="container" ;;
    host)
        info "mode      = HOST       (ollama running on the host, outside any container)"
        VALIDATE_MODE="host" ;;
    other)
        info "mode      = OTHER      (an ollama-compatible API on :${HOST_PORT} we did not start)"
        # validate.sh has no 'other' bucket; treat it like host (no compose
        # ownership assumptions, no docker logs).
        VALIDATE_MODE="host" ;;
    *)
        err "internal error: MODE='$MODE' is not container|host|other"
        exit 1 ;;
esac
info "endpoint  = http://localhost:${HOST_PORT}"

header "Validation ladder (layers 0-7; Layer 8 needs 'make validate-full')"

VALIDATE_RC=0
"${REPO_ROOT}/scripts/validate.sh" --mode "$VALIDATE_MODE" --skip-long-ctx || VALIDATE_RC=$?

# ---------------------------------------------------------------------------
# step 8: footer
# ---------------------------------------------------------------------------

header "Quickstart complete"

if [ "$VALIDATE_RC" -eq 0 ]; then
    ok "all selected layers passed (validated: ${MODE})"
    if [ "$MODE" = "container" ]; then
        PULL_HINT="docker compose exec ${SERVICE} ollama pull gemma4:31b-it-q4_K_M"
    else
        PULL_HINT="ollama pull gemma4:31b-it-q4_K_M"
    fi
    cat <<EOF

  Next steps:
    make logs                # tail the ollama server log
    make ps                  # show loaded models
    make validate-full       # add Layer 8 long-context test (~4-25 min)
    make stress-test-quick   # safe ~5-min stress (concurrency=2, ctx=32K)

  Pull a long-context model for the headline test:
    ${PULL_HINT}

EOF
else
    err "validate.sh exited with code ${VALIDATE_RC} (mode=${MODE}) - check the [FAIL] lines above"
    cat <<EOF

  Next steps:
    make mes-check           # rule out the MES 0x83 firmware regression first
    docs/build-fixes.md      # symptom -> root cause map
    docs/validation-tests.md # what each layer expects

EOF
    exit "$VALIDATE_RC"
fi
