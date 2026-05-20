#!/usr/bin/env bash
# PraestoClaw STAGING one-click updater for macOS / Linux.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/cogao/praestoclaw-installer/staging/update.sh | bash
#
# Differences from the prod updater:
# - Pulls wheels and latest.txt from the ``staging`` branch.
# - Targets the ``praestoclaw-staging`` / ``pc-staging`` entry points.

set -uo pipefail

MIRROR_BASE="https://raw.githubusercontent.com/cogao/praestoclaw-installer/staging"
PACKAGE="${PRAESTOCLAW_PACKAGE:-}"

step()  { printf '\n\033[36m>> %s\033[0m\n' "$*"; }
ok()    { printf '   \033[32mOK: %s\033[0m\n' "$*"; }
warn()  { printf '   \033[33mWARNING: %s\033[0m\n' "$*"; }
fail()  { printf '   \033[31mFAILED: %s\033[0m\n' "$*"; exit 1; }

has_cmd() { command -v "$1" >/dev/null 2>&1; }

compare_version() {
    local left="$1" right="$2"
    if has_cmd "$PYTHON_CMD"; then
        if "$PYTHON_CMD" -c "from packaging.version import Version" 2>/dev/null; then
            "$PYTHON_CMD" -c "
from packaging.version import Version
import sys
l, r = Version(sys.argv[1]), Version(sys.argv[2])
sys.exit(0 if l >= r else 1)
" "$left" "$right" 2>/dev/null
            return $?
        fi
    fi
    left=$(echo "$left" | sed 's/\.post[0-9]\{10,\}//')
    right=$(echo "$right" | sed 's/\.post[0-9]\{10,\}//')
    IFS='.' read -ra lparts <<< "$left"
    IFS='.' read -ra rparts <<< "$right"
    local max=${#lparts[@]}
    [[ ${#rparts[@]} -gt $max ]] && max=${#rparts[@]}
    for ((i = 0; i < max; i++)); do
        local l=${lparts[$i]:-0}
        local r=${rparts[$i]:-0}
        l=$(echo "$l" | grep -oE '^[0-9]+' || echo 0)
        r=$(echo "$r" | grep -oE '^[0-9]+' || echo 0)
        if [[ "$l" -lt "$r" ]]; then return 1; fi
        if [[ "$l" -gt "$r" ]]; then return 0; fi
    done
    return 0
}

stop_praestoclaw_staging_processes() {
    # Stop running praestoclaw-staging / pc-staging processes only —
    # leave any running prod ``praestoclaw`` / ``pc`` processes alone.
    local current_pid=$$
    local parent_pid
    parent_pid=$(ps -o ppid= -p "$current_pid" 2>/dev/null | tr -d ' ')
    local exclude_pids="$current_pid ${parent_pid:-0}"
    local killed=0

    while IFS= read -r line; do
        local pid cmd
        pid=$(echo "$line" | awk '{print $1}')
        cmd=$(echo "$line" | awk '{$1=""; print}' | sed 's/^ //')

        local skip=false
        for ep in $exclude_pids; do
            [[ "$pid" = "$ep" ]] && skip=true
        done
        $skip && continue

        local _exe
        _exe=$(echo "$cmd" | awk '{print $1}')
        _exe=$(basename "$_exe" 2>/dev/null || echo "$_exe")
        local _match=false
        case "$_exe" in
            praestoclaw-staging|praestoclaw-staging.exe|pc-staging|pc-staging.exe) _match=true ;;
        esac
        if ! $_match; then continue; fi

        kill -TERM "$pid" 2>/dev/null || true
        local waited=0
        while kill -0 "$pid" 2>/dev/null && [[ "$waited" -lt 3 ]]; do
            sleep 1
            waited=$((waited + 1))
        done
        if kill -0 "$pid" 2>/dev/null; then
            kill -9 "$pid" 2>/dev/null || true
        fi
        if kill -0 "$pid" 2>/dev/null; then
            warn "Could not stop PID $pid"
        else
            ok "Stopped PID $pid"
            killed=$((killed + 1))
        fi
    done < <(ps -eo pid=,args= 2>/dev/null || true)

    if [[ "$killed" -eq 0 ]]; then
        ok "No running PraestoClaw (staging) processes found."
    else
        sleep 1
    fi
}

# --- Step 1: Verify current installation ---
step "Checking current staging installation ..."

if ! has_cmd praestoclaw-staging; then
    fail "PraestoClaw (staging) is not installed.
  Run the staging installer first:
    curl -fsSL https://raw.githubusercontent.com/cogao/praestoclaw-installer/staging/install.sh | bash"
fi

current_version_raw=$(praestoclaw-staging version 2>&1)
ok "Current: $current_version_raw"

current_version=$(echo "$current_version_raw" | grep -oE '[0-9]+\.[0-9]+[^ ]*' | head -1)

PYTHON_CMD=""
for candidate in python3 python; do
    if has_cmd "$candidate"; then
        PYTHON_CMD="$candidate"
        break
    fi
done
[[ -z "$PYTHON_CMD" ]] && fail "Python not found on PATH."
ok "Python: $($PYTHON_CMD --version 2>&1)"

# --- Step 2: Resolve latest staging version and compare ---
latest=""
if [[ -z "$PACKAGE" ]]; then
    step "Checking for staging updates ..."
    _bust=$(date +%s)
    if has_cmd curl; then
        latest=$(curl -fsSL "$MIRROR_BASE/latest.txt?t=$_bust" | tr -d '[:space:]')
    elif has_cmd wget; then
        latest=$(wget -qO- "$MIRROR_BASE/latest.txt?t=$_bust" | tr -d '[:space:]')
    else
        fail "Neither curl nor wget is available."
    fi
    if ! [[ "$latest" =~ ^[0-9]+\.[0-9]+ ]]; then
        fail "staging latest.txt did not contain a valid version: '$latest'
  Override with PRAESTOCLAW_PACKAGE=<wheel URL or path>"
    fi
    ok "Latest staging version: $latest"

    if [[ -n "$current_version" && -n "$latest" ]]; then
        if compare_version "$current_version" "$latest"; then
            echo ""
            echo "   Already up to date! (current: v$current_version, latest: v$latest)"
            echo ""
            exit 0
        fi
        echo "   Update available: v$current_version -> v$latest"
    fi

    PACKAGE="$MIRROR_BASE/dist/praestoclaw-${latest}-py3-none-any.whl"
fi

DEPS_PACKAGE="${PRAESTOCLAW_GATEWAY_PROTOCOL_PACKAGE:-}"
if [ -z "$DEPS_PACKAGE" ]; then
    if [ -z "$latest" ]; then
        _bust=$(date +%s)
        if has_cmd curl; then
            latest=$(curl -fsSL "$MIRROR_BASE/latest.txt?t=$_bust" | tr -d '[:space:]')
        elif has_cmd wget; then
            latest=$(wget -qO- "$MIRROR_BASE/latest.txt?t=$_bust" | tr -d '[:space:]')
        fi
    fi
    if [[ "$latest" =~ ^[0-9]+\.[0-9]+ ]]; then
        DEPS_PACKAGE="$MIRROR_BASE/dist/agent_gateway_protocol-${latest}-py3-none-any.whl"
    else
        warn "Could not resolve agent_gateway_protocol wheel URL — pip will try PyPI and likely fail."
        warn "Override with PRAESTOCLAW_GATEWAY_PROTOCOL_PACKAGE=<wheel URL or path>"
    fi
fi

INSTALL_TARGETS=()
[ -n "$DEPS_PACKAGE" ] && INSTALL_TARGETS+=("$DEPS_PACKAGE")
INSTALL_TARGETS+=("$PACKAGE")

# --- Step 3: Stop running staging processes ---
step "Stopping running PraestoClaw (staging) processes ..."
stop_praestoclaw_staging_processes

# --- Step 4: Upgrade via pip ---
step "Upgrading to v${latest:-latest} ..."

PIP_FLAGS=(--upgrade --force-reinstall)

if "$PYTHON_CMD" -m pip install "${PIP_FLAGS[@]}" "${INSTALL_TARGETS[@]}" >/dev/null 2>&1; then
    ok "Upgrade complete."
elif "$PYTHON_CMD" -m pip install "${PIP_FLAGS[@]}" --user "${INSTALL_TARGETS[@]}" >/dev/null 2>&1; then
    ok "Upgrade complete (--user)."
elif "$PYTHON_CMD" -m pip install "${PIP_FLAGS[@]}" --break-system-packages "${INSTALL_TARGETS[@]}" >/dev/null 2>&1; then
    ok "Upgrade complete (--break-system-packages)."
else
    pip_out=$("$PYTHON_CMD" -m pip install "${PIP_FLAGS[@]}" "${INSTALL_TARGETS[@]}" 2>&1) || {
        printf '%s\n' "$pip_out"
        fail "pip install failed.
  Common fixes:
    - Corporate proxy: export HTTPS_PROXY=http://proxy:port
    - Manual: $PYTHON_CMD -m pip install --upgrade --force-reinstall ${INSTALL_TARGETS[*]}"
    }
    ok "Upgrade complete."
fi

if has_cmd praestoclaw-staging; then
    ok "$(praestoclaw-staging version 2>&1)"
else
    warn "praestoclaw-staging not found on PATH after upgrade."
fi

# --- Step 5: Post-update startup ---
echo ""
echo "============================================"
echo "  PraestoClaw (staging) updated to v${latest:-latest}!"
echo "============================================"
echo ""

if has_cmd praestoclaw-staging; then
    step "Running post-update config ..."
    praestoclaw-staging init --quick 2>&1 | sed 's/^/   /' || true

    step "Starting PraestoClaw (staging) ..."
    echo "   Press Ctrl+C in this window to stop the server."
    echo ""
    exec praestoclaw-staging s
else
    echo "  Restart your terminal, then run:"
    echo "    praestoclaw-staging s"
    echo ""
fi
