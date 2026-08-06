#!/bin/bash

cd /home/container

echo "Running on Debian $(cat /etc/debian_version)"
echo "Current timezone: $(cat /etc/timezone)"
wine --version

INTERNAL_IP=$(ip route get 1 | awk '{print $(NF-2);exit}')
export INTERNAL_IP

if [ -z "${STEAM_USER:-}" ]; then
    echo -e "steam user is not set.\nUsing anonymous user.\n"
    STEAM_USER=anonymous
    STEAM_PASS=""
    STEAM_AUTH=""
else
    echo -e "user set to ${STEAM_USER}"
fi

# Update only when explicitly enabled. Validation only runs for 1/true/yes/on;
# unlike the upstream entrypoint, VALIDATE=0 does NOT trigger validation.
if [ -z "${AUTO_UPDATE:-}" ] || [ "${AUTO_UPDATE}" = "1" ]; then
    if [ -n "${SRCDS_APPID:-}" ]; then
        VALIDATE_ARG=""
        case "${VALIDATE:-0}" in
            1|true|TRUE|yes|YES|on|ON) VALIDATE_ARG="validate" ;;
        esac

        UPDATE_CMD=(
            ./steamcmd/steamcmd.sh
            +force_install_dir /home/container
            +login "${STEAM_USER}" "${STEAM_PASS}" "${STEAM_AUTH}"
        )

        if [ "${WINDOWS_INSTALL:-0}" = "1" ]; then
            UPDATE_CMD+=(+@sSteamCmdForcePlatformType windows)
        fi

        UPDATE_CMD+=(+app_update "${SRCDS_APPID}")

        if [ -n "${SRCDS_BETAID:-}" ]; then
            UPDATE_CMD+=(-beta "${SRCDS_BETAID}")
        fi
        if [ -n "${SRCDS_BETAPASS:-}" ]; then
            UPDATE_CMD+=(-betapassword "${SRCDS_BETAPASS}")
        fi
        if [ -n "${HLDS_GAME:-}" ]; then
            UPDATE_CMD+=(+app_set_config 90 mod "${HLDS_GAME}")
        fi
        if [ -n "${VALIDATE_ARG}" ]; then
            UPDATE_CMD+=(validate)
        fi
        UPDATE_CMD+=(+quit)

        echo "Updating game server..."
        if [ "${STEAM_USER}" = "anonymous" ]; then
            "${UPDATE_CMD[@]}"
        else
            numactl --physcpubind=+0 "${UPDATE_CMD[@]}"
        fi
    else
        echo "No appid set. Starting server."
    fi
else
    echo "Auto-update disabled. Starting server without SteamCMD update."
fi

if [ "${XVFB:-0}" = "1" ]; then
    Xvfb :0 -screen 0 "${DISPLAY_WIDTH:-1024}x${DISPLAY_HEIGHT:-768}x${DISPLAY_DEPTH:-16}" &
fi

# Winetricks / Wine setup cache.
# The persistent Wine prefix keeps markers so expensive setup verbs are not
# blindly rerun on every server restart.
mkdir -p "${WINEPREFIX}"
STATE_DIR="${WINEPREFIX}/.ptero-winetricks-state"
mkdir -p "${STATE_DIR}"

run_once() {
    local key="$1"
    shift
    local marker="${STATE_DIR}/${key}.done"

    if [ "${FORCE_WINETRICKS:-0}" = "1" ] || [ ! -f "${marker}" ]; then
        echo "Preparing Wine component: ${key}"
        if "$@"; then
            touch "${marker}"
        else
            echo "WARNING: Wine component '${key}' returned an error; it will retry next boot."
        fi
    else
        echo "Wine component already prepared: ${key}"
    fi
}

install_gecko() {
    local version="${WINE_GECKO_VERSION:-2.47.4}"
    local x86="${WINEPREFIX}/gecko_x86.msi"
    local x64="${WINEPREFIX}/gecko_x86_64.msi"

    [ -f "${x86}" ] || wget -q -O "${x86}" \
        "https://dl.winehq.org/wine/wine-gecko/${version}/wine_gecko-${version}-x86.msi"
    [ -f "${x64}" ] || wget -q -O "${x64}" \
        "https://dl.winehq.org/wine/wine-gecko/${version}/wine_gecko-${version}-x86_64.msi"

    wine msiexec /i "${x86}" /qn /quiet /norestart /log "${WINEPREFIX}/gecko_x86_install.log" &&
    wine msiexec /i "${x64}" /qn /quiet /norestart /log "${WINEPREFIX}/gecko_x64_install.log"
}

install_mono() {
    local version="${WINE_MONO_VERSION:-9.0.0}"
    local mono="${WINEPREFIX}/mono.msi"

    [ -f "${mono}" ] || wget -q -O "${mono}" \
        "https://dl.winehq.org/wine/wine-mono/${version}/wine-mono-${version}-x86.msi"

    wine msiexec /i "${mono}" /qn /quiet /norestart /log "${WINEPREFIX}/mono_install.log"
}

for trick in ${WINETRICKS_RUN:-}; do
    case "${trick}" in
        gecko)
            run_once gecko install_gecko
            ;;
        mono)
            run_once mono install_mono
            ;;
        *)
            safe_key=$(printf '%s' "${trick}" | tr -c 'A-Za-z0-9_.-' '_')
            run_once "winetricks_${safe_key}" winetricks -q "${trick}"
            ;;
    esac
done

# Space Engineers-specific collection sync. Safe no-op when disabled.
if command -v se-collection-sync >/dev/null 2>&1; then
    if ! se-collection-sync; then
        echo "Collection sync failed in strict mode; server launch aborted."
        exit 1
    fi
fi

MODIFIED_STARTUP=$(echo "${STARTUP}" | sed -e 's/{{/${/g' -e 's/}}/}/g')
echo ":/home/container$ ${MODIFIED_STARTUP}"
eval "${MODIFIED_STARTUP}"
