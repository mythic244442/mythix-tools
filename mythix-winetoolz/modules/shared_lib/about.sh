#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
#  about.sh — About / Help / Dependency Checker
#  winetoolz v2.1
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../winetoolz-lib.sh"

MODULE="About winetoolz"

wt_require_cmds zenity

# =============================================================================
#  Dependency definitions
#  Format: cmd  package_hint  required_by
# =============================================================================

declare -A DEP_PKG DEP_USED_BY

DEP_PKG[zenity]="zenity"
DEP_USED_BY[zenity]="All modules (required)"

DEP_PKG[wget]="wget"
DEP_USED_BY[wget]="Runtimes Installer, VC++ Installer"

DEP_PKG[curl]="curl"
DEP_USED_BY[curl]="DXVK / VKD3D downloader"

DEP_PKG[cabextract]="cabextract"
DEP_USED_BY[cabextract]="DirectX Jun 2010 Installer"

DEP_PKG[unzip]="unzip"
DEP_USED_BY[unzip]="OpenAL installer, Runtimes"

DEP_PKG[zstd]="zstd"
DEP_USED_BY[zstd]="VKD3D-Proton extraction, Prefix backup/restore"

DEP_PKG[tar]="tar"
DEP_USED_BY[tar]="DXVK / VKD3D extraction, Prefix backup"

DEP_PKG[wrestool]="icoutils"
DEP_USED_BY[wrestool]="App Launcher icon extraction (optional)"

DEP_PKG[icotool]="icoutils"
DEP_USED_BY[icotool]="App Launcher icon extraction (optional)"

DEP_PKG[xclip]="xclip"
DEP_USED_BY[xclip]="Env Flags clipboard export (optional)"

DEP_PKG[xsel]="xsel"
DEP_USED_BY[xsel]="Env Flags clipboard export (optional, fallback to xclip)"

DEP_PKG[vulkaninfo]="vulkan-tools"
DEP_USED_BY[vulkaninfo]="Vulkan diagnostics (optional)"

DEP_PKG[wine]="wine / wine64"
DEP_USED_BY[wine]="System Wine fallback (optional if using custom builds)"

DEP_ORDER=(zenity wget curl cabextract unzip zstd tar wrestool icotool xclip xsel vulkaninfo wine)

# =============================================================================
#  Module listing
# =============================================================================

MODULES_INFO="$(cat << 'MODEOF'
  [ Graphics ]
    DXVK Installer         — Vulkan-based D3D 8/9/10/11 translation layer
    VKD3D-Proton Installer — Vulkan-based Direct3D 12 translation layer
    DXVK-NVAPI Installer   — NVIDIA API layer for DLSS / NvAPI

  [ Runtimes ]
    VC++ Runtime Installer — Visual C++ 2015–2022 / 2017–2026
    DirectX Jun 2010       — Legacy DirectX offline redistributable
    Runtime Libraries      — .NET / XNA / XACT / DirectPlay / OpenAL / VC++ legacy

  [ Wine ]
    Wine Tools             — Uninstaller, control panel, taskmgr, regedit, explorer
    DLL Override Manager   — View, add presets, add custom, remove DLL overrides

  [ Prefix ]
    Create Prefix          — Bootstrap a new Wine prefix
    Prefix Manager         — Backup, restore, regedit, kill, build manager
    Prefix Diagnostics     — Health check, arch, Windows ver, DXVK, disk usage

  [ Launch ]
    App Launcher           — Save and run Wine app shortcuts with env profiles
    Env Flags              — Manage launch environment variable profiles
    Log Viewer             — Capture and view Wine output logs

  [ Components ]
    System File Installer  — Copy system DLLs into a prefix

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

    case "$CHOICE" in

        # ------------------------------------------------------------------
        deps)
            # Run checks
            ROWS=()
            for cmd in "${DEP_ORDER[@]}"; do
                local status icon
                if command -v "$cmd" >/dev/null 2>&1; then
                    local ver
                    ver="$("$cmd" --version 2>/dev/null | head -1 | sed 's/^[^0-9]*//' | cut -c1-30 || echo "")"
                    status="✔  installed${ver:+  ($ver)}"
                    icon="✔"
                else
                    status="✘  not found  —  install: ${DEP_PKG[$cmd]}"
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
Launcher shortcuts:  %s
Env profiles      :  %s
Icon cache        :  %s
Prefix backups    :  %s
Wine logs         :  %s
winetoolz root    :  %s' \
                "${HOME}/winetoolz/.config" \
                "${HOME}/.config/winetoolz/launchers/" \
                "${HOME}/.config/winetoolz/env_profiles/" \
                "${HOME}/.config/winetoolz/icons/" \
                "${HOME}/winetoolz/backups/" \
                "${HOME}/winetoolz/logs/" \
                "$(dirname "$SCRIPT_DIR")")"
            ;;

        exit|*) break ;;
    esac
done
