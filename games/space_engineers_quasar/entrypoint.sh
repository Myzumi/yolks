#!/bin/bash
set -Eeuo pipefail

cd /home/container

export HOME=/home/container
export XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-/home/container/.config}"
export XDG_DATA_HOME="${XDG_DATA_HOME:-/home/container/.local/share}"
export QUASAR_INSTALL_DIR="${QUASAR_INSTALL_DIR:-/home/container/quasar}"

QUASAR_ROOT="${QUASAR_INSTALL_DIR}"
QUASAR_ARCHIVE="quasar-installer-linux.tar.gz"
QUASAR_BASE_URL="${QUASAR_RELEASE_BASE_URL:-https://github.com/CometWorks/quasar/releases/latest/download}"
STOP_TIMEOUT="${SE_GRACEFUL_STOP_TIMEOUT:-25}"

mkdir -p "${QUASAR_ROOT}" "${XDG_CONFIG_HOME}" "${XDG_DATA_HOME}"

# ---------------------------------------------------------------------------
# Pterodactyl <-> Quasar port contract
# ---------------------------------------------------------------------------
# Pterodactyl exposes the server's primary allocation as SERVER_PORT. Quasar's
# current managed-DS implementation accepts ServerPort and derives the two other
# Space Engineers ports as:
#   SteamPort     = ServerPort + 1000
#   RemoteApiPort = ServerPort + 2000
#
# The egg cannot allocate additional Panel ports by itself; allocations are
# Panel/Wings resources. We therefore calculate and validate the ports here,
# write a machine-readable manifest, and print exactly which allocations the
# Pterodactyl server must own before the managed DS is started.
SE_GAME_PORT="${SERVER_PORT:-${SE_SERVER_PORT:-27016}}"
QUASAR_WEB_PORT="${QUASAR_WEB_PORT:-5044}"

validate_port() {
    local name="$1" value="$2"
    if [[ ! "$value" =~ ^[0-9]+$ ]] || (( value < 1 || value > 65535 )); then
        echo "[quasar-yolk] ERROR: ${name} is not a valid TCP/UDP port: ${value}"
        exit 64
    fi
}

validate_port "SERVER_PORT" "${SE_GAME_PORT}"
validate_port "QUASAR_WEB_PORT" "${QUASAR_WEB_PORT}"

if (( SE_GAME_PORT > 63535 )); then
    echo "[quasar-yolk] ERROR: SERVER_PORT=${SE_GAME_PORT} is too high for Quasar's +2000 Remote API derivation."
    exit 64
fi

SE_STEAM_PORT=$((SE_GAME_PORT + 1000))
SE_REMOTE_API_PORT=$((SE_GAME_PORT + 2000))

if (( QUASAR_WEB_PORT == SE_GAME_PORT || QUASAR_WEB_PORT == SE_STEAM_PORT || QUASAR_WEB_PORT == SE_REMOTE_API_PORT )); then
    echo "[quasar-yolk] ERROR: QUASAR_WEB_PORT=${QUASAR_WEB_PORT} collides with a managed Space Engineers port."
    exit 64
fi

cat > "${QUASAR_ROOT}/pterodactyl-ports.json" <<EOF
{
  "gamePort": ${SE_GAME_PORT},
  "steamPort": ${SE_STEAM_PORT},
  "remoteApiPort": ${SE_REMOTE_API_PORT},
  "quasarWebPort": ${QUASAR_WEB_PORT},
  "notes": "gamePort is the Pterodactyl primary allocation; Quasar currently derives steamPort=gamePort+1000 and remoteApiPort=gamePort+2000"
}
EOF

echo "[quasar-yolk] Port contract:"
echo "[quasar-yolk]   SE game / Pterodactyl primary : ${SE_GAME_PORT}/udp"
echo "[quasar-yolk]   SE Steam (Quasar derived)      : ${SE_STEAM_PORT}/udp"
echo "[quasar-yolk]   SE Remote API (if enabled)     : ${SE_REMOTE_API_PORT}/tcp"
echo "[quasar-yolk]   Quasar Web UI                  : ${QUASAR_WEB_PORT}/tcp"
echo "[quasar-yolk] Manifest: ${QUASAR_ROOT}/pterodactyl-ports.json"
echo "[quasar-yolk] NOTE: make sure the derived ports are assigned to this server in Pterodactyl."

install_quasar_bootstrap() {
    local tmp
    tmp="$(mktemp -d)"
    trap 'rm -rf "${tmp}"' RETURN

    echo "[quasar-yolk] Downloading current Quasar Linux bootstrap..."
    curl -fL --retry 5 --retry-delay 2 --connect-timeout 20 \
        "${QUASAR_BASE_URL}/${QUASAR_ARCHIVE}" \
        -o "${tmp}/${QUASAR_ARCHIVE}"
    curl -fL --retry 5 --retry-delay 2 --connect-timeout 20 \
        "${QUASAR_BASE_URL}/SHA256SUMS" \
        -o "${tmp}/SHA256SUMS"

    local expected actual
    expected="$(awk -v n="${QUASAR_ARCHIVE}" '$2==n || $2=="*"n {print $1; exit}' "${tmp}/SHA256SUMS")"
    if [[ -z "${expected}" ]]; then
        echo "[quasar-yolk] ERROR: ${QUASAR_ARCHIVE} is missing from SHA256SUMS."
        return 1
    fi
    actual="$(sha256sum "${tmp}/${QUASAR_ARCHIVE}" | awk '{print $1}')"
    if [[ "${actual}" != "${expected}" ]]; then
        echo "[quasar-yolk] ERROR: Quasar archive checksum mismatch."
        return 1
    fi

    mkdir -p "${tmp}/extract"
    tar -xzf "${tmp}/${QUASAR_ARCHIVE}" -C "${tmp}/extract"
    if [[ ! -x "${tmp}/extract/Quasar/Quasar" ]]; then
        echo "[quasar-yolk] ERROR: release archive does not contain Quasar/Quasar."
        return 1
    fi

    # Preserve operator configuration if a manual bootstrap refresh was requested.
    local saved_appsettings=""
    if [[ -f "${QUASAR_ROOT}/appsettings.json" ]]; then
        saved_appsettings="${tmp}/appsettings.operator.json"
        cp -a "${QUASAR_ROOT}/appsettings.json" "${saved_appsettings}"
    fi

    cp -a "${tmp}/extract/Quasar/." "${QUASAR_ROOT}/"
    if [[ -n "${saved_appsettings}" ]]; then
        cp -a "${saved_appsettings}" "${QUASAR_ROOT}/appsettings.json"
    fi

    chmod +x "${QUASAR_ROOT}/Quasar"
    echo "[quasar-yolk] Quasar bootstrap installed in ${QUASAR_ROOT}."
}

if [[ "${QUASAR_FORCE_BOOTSTRAP_REFRESH:-0}" == "1" || ! -x "${QUASAR_ROOT}/Quasar" ]]; then
    install_quasar_bootstrap
fi

# The Bootstrap launcher and worker MUST read the same appsettings.json. Do not use
# QUASAR_WEB_PORT as a direct Quasar environment override here; instead, translate
# the Pterodactyl variable into the shared config file before Bootstrap starts.
if [[ -n "${QUASAR_WEB_PORT:-}" ]]; then
    python3 - "${QUASAR_ROOT}/appsettings.json" "${QUASAR_WEB_PORT}" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
port = int(sys.argv[2])
if not (1 <= port <= 65535):
    raise SystemExit(f"Invalid QUASAR_WEB_PORT: {port}")

data = {}
if path.exists():
    data = json.loads(path.read_text(encoding="utf-8"))
q = data.setdefault("Quasar", {})
q["Host"] = "0.0.0.0"
q["Port"] = port
q["OpenBrowserOnStart"] = False

# Atomic write so an interrupted container start cannot truncate configuration.
tmp = path.with_suffix(path.suffix + ".ptero.tmp")
tmp.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
tmp.replace(path)
PY
fi

if [[ "${SE_COLLECTION_SYNC:-0}" == "1" ]]; then
    echo "[quasar-yolk] NOTE: legacy Workshop collection XML sync is intentionally NOT run under Quasar."
    echo "[quasar-yolk] Quasar profiles are authoritative and render Sandbox_config.sbc on server start."
fi

# Quasar deliberately launches Magnetar with -daemon. That is useful for Quasar
# worker upgrades, but a Pterodactyl container stop would otherwise kill the
# detached DS without giving it a chance to save. On SIGINT/SIGTERM, gracefully
# stop every live Linux Magnetar instance first. Magnetar documents SIGTERM as
# its graceful-stop signal on Linux.
shutdown_managed_servers() {
    trap - INT TERM
    echo
    echo "[quasar-yolk] Container shutdown requested; gracefully stopping Magnetar server(s)..."

    local -a pids=()
    while IFS= read -r -d '' pidfile; do
        local pid cmdline
        pid="$(head -n 1 "${pidfile}" 2>/dev/null | tr -dc '0-9')"
        [[ -n "${pid}" ]] || continue
        [[ -r "/proc/${pid}/cmdline" ]] || continue
        cmdline="$(tr '\0' ' ' < "/proc/${pid}/cmdline" 2>/dev/null || true)"
        case "${cmdline}" in
            *MagnetarInterim*|*MagnetarLegacy*)
                echo "[quasar-yolk] SIGTERM -> Magnetar PID ${pid} (${pidfile})"
                kill -TERM "${pid}" 2>/dev/null || true
                pids+=("${pid}")
                ;;
        esac
    done < <(find /home/container -type f -name magnetar.pid -print0 2>/dev/null)

    local deadline=$((SECONDS + STOP_TIMEOUT))
    while ((${#pids[@]} > 0 && SECONDS < deadline)); do
        local -a still=()
        local pid
        for pid in "${pids[@]}"; do
            if kill -0 "${pid}" 2>/dev/null; then
                still+=("${pid}")
            fi
        done
        pids=("${still[@]}")
        ((${#pids[@]} == 0)) || sleep 1
    done

    if ((${#pids[@]} > 0)); then
        echo "[quasar-yolk] WARNING: Magnetar still running after ${STOP_TIMEOUT}s: ${pids[*]}"
        echo "[quasar-yolk] Leaving final termination to the container runtime."
    else
        echo "[quasar-yolk] Managed Space Engineers server(s) stopped cleanly."
    fi

    if [[ -n "${QUASAR_PID:-}" ]] && kill -0 "${QUASAR_PID}" 2>/dev/null; then
        kill -INT "${QUASAR_PID}" 2>/dev/null || true
    fi
}

trap shutdown_managed_servers INT TERM

# Pterodactyl displays STARTUP in the panel. Keep it overridable, but default to
# the supported Quasar foreground launcher.
STARTUP_CMD="${STARTUP:-${QUASAR_ROOT}/Quasar serve}"
MODIFIED_STARTUP="$(echo "${STARTUP_CMD}" | sed -e 's/{{/${/g' -e 's/}}/}/g')"

echo "[quasar-yolk] .NET: $(dotnet --version)"
echo "[quasar-yolk] Starting: ${MODIFIED_STARTUP}"

/bin/bash -lc "${MODIFIED_STARTUP}" &
QUASAR_PID=$!

set +e
wait "${QUASAR_PID}"
status=$?
set -e

# If Quasar itself exits normally without an external container stop, do not kill
# daemonized managed servers; Quasar intentionally keeps them alive across worker/
# Bootstrap turnover. Pterodactyl stop reaches the trap above before this point.
exit "${status}"
