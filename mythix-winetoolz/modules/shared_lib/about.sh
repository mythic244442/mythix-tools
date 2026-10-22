#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
#  about.sh — About / Help / Dependency Checker
#  winetoolz v3.0
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../winetoolz-lib.sh"

MODULE="About winetoolz"

wt_require_cmds zenity
wt_load_config

# =============================================================================
#  Dependency definitions
#  Format: cmd  package_hint  required_by
# =============================================================================

declare -A DEP_PKG DEP_USED_BY

DEP_PKG[zenity]="zenity"
DEP_USED_BY[zenity]="All modules (required)"

DEP_PKG[curl]="curl"
DEP_USED_BY[curl]="All downloads (or wget)"

DEP_PKG[wget]="wget"
DEP_USED_BY[wget]="Downloads when curl is missing (optional)"

DEP_PKG[cabextract]="cabextract"
DEP_USED_BY[cabextract]="DLL Installer, DirectX, XACT, DirectPlay, System File Installer"

DEP_PKG[7z]="p7zip / 7zip"
DEP_USED_BY[7z]="System File Installer (.7z, .rar, some .exe)"

DEP_PKG[xz]="xz-utils"
DEP_USED_BY[xz]="Kron4ek Wine builds, VKD3D-Proton releases"

DEP_PKG[unzip]="unzip"
DEP_USED_BY[unzip]="OpenAL installer, Runtimes"

DEP_PKG[zstd]="zstd"
DEP_USED_BY[zstd]="VKD3D-Proton extraction, Prefix backup/restore"

DEP_PKG[python3]="python3"
DEP_USED_BY[python3]="Quoted launch arguments, GitHub releases, Mythix game names (optional)"

DEP_PKG[jq]="jq"
DEP_USED_BY[jq]="GitHub release lookups (optional, python3 works too)"

DEP_PKG[flock]="util-linux"
DEP_USED_BY[flock]="Noticing a closed terminal window (optional)"

DEP_PKG[tar]="tar"
DEP_USED_BY[tar]="DXVK / VKD3D extraction, Prefix backup"

DEP_PKG[wrestool]="icoutils"
DEP_USED_BY[wrestool]="App Launcher icon extraction (optional)"

DEP_PKG[icotool]="icoutils"
DEP_USED_BY[icotool]="App Launcher icon extraction (optional)"

DEP_PKG[wl-copy]="wl-clipboard"
DEP_USED_BY[wl-copy]="Env Flags clipboard export on Wayland (optional)"

DEP_PKG[xclip]="xclip"
DEP_USED_BY[xclip]="Env Flags clipboard export (optional)"

DEP_PKG[xsel]="xsel"
DEP_USED_BY[xsel]="Env Flags clipboard export (optional, fallback to xclip)"

DEP_PKG[vulkaninfo]="vulkan-tools"
DEP_USED_BY[vulkaninfo]="Vulkan diagnostics (optional)"

DEP_PKG[wine]="wine / wine64"
DEP_USED_BY[wine]="System Wine fallback (optional if using custom builds)"

DEP_ORDER=(zenity curl wget cabextract 7z unzip xz zstd tar python3 jq flock wrestool icotool wl-copy xclip xsel vulkaninfo wine)

# =============================================================================
#  Module listing
# =============================================================================

MODULES_INFO="$(cat << 'MODEOF'
  [ Graphics ]
    DXVK Installer         — Vulkan-based D3D 8/9/10/11 translation layer
    VKD3D-Proton Installer — Vulkan-based Direct3D 12 translation layer
    DXVK-NVAPI Installer   — NVIDIA API layer for DLSS / NvAPI

  [ Runtimes ]
    Runtime Libraries      — .NET / XNA / XACT / DirectPlay / OpenAL / VC++
    VC++ Runtime Installer — Visual C++ 2015–2022 / 2017–2026 (quick)
    DirectX Jun 2010       — Legacy DirectX offline redistributable

  [ Wine ]
    Wine Tools             — Uninstaller, control panel, regedit, cmd, drive C:
    DLL Override Manager   — Overrides for all programs or one, with presets
    Wine Install Manager   — Install, switch, uninstall custom Wine builds
    Runtime Downloads      — GE-Proton and Kron4ek Wine builds from GitHub

  [ Prefix ]
    Create Prefix          — Bootstrap a new Wine prefix
    Winecfg                — Wine configuration for an existing prefix
    Prefix Manager         — Backup, restore, regedit, kill, build manager
    Prefix Diagnostics     — Health check, arch, Windows ver, DXVK, disk usage

  [ Launch ]
    App Launcher           — Save and run Wine app shortcuts with env profiles
    Env Flags              — Manage launch environment variable profiles
    Log Viewer             — Capture and view Wine output logs

  [ Components ]
    DLL Installer          — Curated DLLs: d3dx9/10/11, d3dcompiler, xinput, msxml…
    System File Installer  — Install the DLLs from any archive into a prefix

  [ System ]
    About / Help           — This screen
MODEOF
)"

# =============================================================================
#  Main loop
# =============================================================================

while true; do
    CHOICE=$(zenity --list \
        --title="$(wt_title "$MODULE")" \
        --text="$(printf '<tt>winetoolz  v%s  —  a GUI Wine toolkit\n\nAuthor : blu2442\nLicense: MIT\n\nWhat would you like to view?</tt>' "$WT_VERSION")" \
        --column="Tag" --column="Section" --column="Description" \
        --hide-column=1 --print-column=1 \
        --width=600 --height=300 \
        "deps"     "Dependency Checker"   "Check which required and optional tools are installed" \
        "modules"  "Module Reference"     "List all modules and what they do" \
        "config"   "Config File Location" "Show where winetoolz stores its config and data" \
        "exit"     "Close"                "") || break
    CHOICE="${CHOICE%%|*}"

    case "$CHOICE" in

        # ------------------------------------------------------------------
        deps)
            # Run checks
            ROWS=()
            PM="$(_wt_pkg_manager)"
            for cmd in "${DEP_ORDER[@]}"; do
                if command -v "$cmd" >/dev/null 2>&1; then
                    ver="$(timeout 5 "$cmd" --version </dev/null 2>/dev/null | head -1 | sed 's/^[^0-9]*//' | cut -c1-30 || echo "")"
                    status="✔  installed${ver:+  ($ver)}"
                    icon="✔"
                else
                    status="✘  not found  —  $(_wt_install_hint "$PM" "$(_wt_pkg_for "$cmd" "$PM")")"
                    icon="✘"
                fi
                ROWS+=("$icon" "$cmd" "${DEP_PKG[$cmd]}" "${DEP_USED_BY[$cmd]}" "$status")
            done

            zenity --list \
                --title="$(wt_title "Dependency Checker")" \
                --text="<tt>Dependency status for winetoolz v${WT_VERSION}</tt>" \
                --column="✔" --column="Command" --column="Package" \
                --column="Used By" --column="Status" \
                --width=980 --height=500 \
                "${ROWS[@]}" || true
            ;;

        # ------------------------------------------------------------------
        modules)
            wt_info "$MODULE  ›  Module Reference" "$MODULES_INFO"
            ;;

        # ------------------------------------------------------------------
        config)
            wt_info "$MODULE  ›  Config & Data Locations" "$(printf \
'Config file       :  %s
Prefix search     :  %s
Launcher shortcuts:  %s
Env profiles      :  %s
Icon cache        :  %s
Prefix backups    :  %s
Wine logs         :  %s
Download cache    :  %s
DXVK/VKD3D/NVAPI  :  %s
Wine builds       :  %s
Managed installs  :  %s
winetoolz root    :  %s' \
                "$WT_CONFIG_FILE" \
                "${WT_PREFIX_PATHS//:/  }" \
                "${HOME}/.config/winetoolz/launchers/" \
                "${HOME}/.config/winetoolz/env_profiles/" \
                "${HOME}/.config/winetoolz/icons/" \
                "$WT_BACKUP_DIR" \
                "${HOME}/winetoolz/logs/" \
                "$WT_DL_CACHE" \
                "$WT_RELEASE_BASE" \
                "${HOME}/wine-custom/buildz" \
                "${HOME}/.local/share/mythix-wine-installs" \
                "$(dirname "$SCRIPT_DIR")")"
            ;;

        exit|*) break ;;
    esac
done
