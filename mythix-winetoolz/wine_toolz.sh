#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
#  wine_toolz.sh — Main Launcher
#  winetoolz v2.1
#
#  Top-level menu shows categories.
#  Selecting a category opens a looping submenu of its modules.
#  Back / cancel returns to the category menu.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Find the winetoolz lib root — two possible layouts:
#   Source tree:   <script-dir>/modules/winetoolz-lib.sh
#   make install:  <prefix>/lib/mythix-winetoolz/modules/winetoolz-lib.sh
#                  (SCRIPT_DIR is <prefix>/bin; strip /bin, append /lib/mythix-winetoolz)
_WT_LIB_ROOT=""
for _candidate in \
    "${SCRIPT_DIR}" \
    "${SCRIPT_DIR%/bin}/lib/mythix-winetoolz"
do
    if [[ -f "${_candidate}/modules/winetoolz-lib.sh" ]]; then
        _WT_LIB_ROOT="${_candidate}"
        break
    fi
done

LIB="${_WT_LIB_ROOT}/modules/winetoolz-lib.sh"
if [[ ! -f "$LIB" ]]; then
    zenity --error --text="Cannot find winetoolz-lib.sh.\nExpected at: $LIB" 2>/dev/null \
        || echo "FATAL: winetoolz-lib.sh not found at: $LIB"
    exit 1
fi
source "$LIB"
wt_load_config

# =============================================================================
#  Terminal banner  (shown in the launching terminal while zenity menus run)
# =============================================================================
printf '\e[1;35m'
cat <<'WOLF'
⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⣀⡀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠸⠁⠸⢳⡄⠀⠀⠀⠀⠀⠀⠀⠀
⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⢠⠃⠀⠀⢸⠸⠀⡠⣄⠀⠀⠀⠀⠀
⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⡠⠃⠀⠀⢠⣞⣀⡿⠀⠀⣧⠀⠀⠀⠀
⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⣀⣠⡖⠁⠀⠀⠀⢸⠈⢈⡇⠀⢀⡏⠀⠀⠀⠀
⠀⠀⠀⠀⠀⠀⠀⠀⠀⡴⠩⢠⡴⠀⠀⠀⠀⠀⠈⡶⠉⠀⠀⡸⠀⠀⠀⠀⠀
⠀⠀⠀⠀⠀⠀⠀⢀⠎⢠⣇⠏⠀⠀⠀⠀⠀⠀⠀⠁⠀⢀⠄⡇⠀⠀⠀⠀⠀
⠀⠀⠀⠀⠀⠀⢠⠏⠀⢸⣿⣴⠀⠀⠀⠀⠀⠀⣆⣀⢾⢟⠴⡇⠀⠀⠀⠀⠀
⠀⠀⠀⠀⠀⢀⣿⠀⠠⣄⠸⢹⣦⠀⠀⡄⠀⠀⢋⡟⠀⠀⠁⣇⠀⠀⠀⠀⠀
⠀⠀⠀⠀⢀⡾⠁⢠⠀⣿⠃⠘⢹⣦⢠⣼⠀⠀⠉⠀⠀⠀⠀⢸⡀⠀⠀⠀⠀
⠀⠀⢀⣴⠫⠤⣶⣿⢀⡏⠀⠀⠘⢸⡟⠋⠀⠀⠀⠀⠀⠀⠀⠀⢳⠀⠀⠀⠀
⠐⠿⢿⣿⣤⣴⣿⣣⢾⡄⠀⠀⠀⠀⠳⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⢣⠀⠀⠀
⠀⠀⠀⣨⣟⡍⠉⠚⠹⣇⡄⠀⠀⠀⠀⠀⠀⠀⠀⠈⢦⠀⠀⢀⡀⣾⡇⠀⠀
⠀⠀⢠⠟⣹⣧⠃⠀⠀⢿⢻⡀⢄⠀⠀⠀⠀⠐⣦⡀⣸⣆⠀⣾⣧⣯⢻⠀⠀
⠀⠀⠘⣰⣿⣿⡄⡆⠀⠀⠀⠳⣼⢦⡘⣄⠀⠀⡟⡷⠃⠘⢶⣿⡎⠻⣆⠀⠀
⠀⠀⠀⡟⡿⢿⡿⠀⠀⠀⠀⠀⠙⠀⠻⢯⢷⣼⠁⠁⠀⠀⠀⠙⢿⡄⡈⢆⠀
⠀⠀⠀⠀⡇⣿⡅⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠙⠦⠀⠀⠀⠀⠀⠀⡇⢹⢿⡀
⠀⠀⠀⠀⠁⠛⠓⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠼⠇⠁
WOLF
printf '\n'
printf '  ╔══════════════════════════════════════════════════════════════╗\n'
printf '  ║                                                              ║\n'
printf '  ║  🍷  winetoolz  v%-4s  —  mythix edition                      ║\n' "${WT_VERSION}"
printf '  ║      Wine prefix manager  •  DXVK  •  runtimes              ║\n'
printf '  ║                                                              ║\n'
printf '  ╚══════════════════════════════════════════════════════════════╝\n'
printf '\e[0m\n'
printf '  \e[2mZenity menus running — this terminal stays open as the host.\e[0m\n\n'

# =============================================================================
#  Script paths
# =============================================================================

MOD="${_WT_LIB_ROOT}/modules/shared_lib"
DXVK_SETUP_SCRIPT="$MOD/dxvk_setup-gui.sh"
VKD3D_SETUP_SCRIPT="$MOD/setup_vkd3d_proton-gui.sh"
NVAPI_SETUP_SCRIPT="$MOD/install_nvapi.sh"
DIRECTX_2010_SCRIPT="$MOD/directx_installer-local.sh"
PREFIX_CREATOR_SCRIPT="$MOD/winetoolz-prefix-maker.sh"
COMPONENT_INSTALL_SCRIPT="$MOD/install_components-x86_64.sh"
DLL_INSTALLER_SCRIPT="$MOD/dll_installer.sh"
RUNTIMES_SCRIPT="$MOD/runtimes_installer.sh"
VC_RUNTIME_SCRIPT="$MOD/vcruntime_installer-gui.sh"
PREFIX_MANAGER_SCRIPT="$MOD/prefix_manager.sh"
WINE_TOOLS_SCRIPT="$MOD/wine_tools.sh"
DLL_OVERRIDE_SCRIPT="$MOD/dll_override_manager.sh"
APP_LAUNCHER_SCRIPT="$MOD/app_launcher.sh"
PREFIX_DIAG_SCRIPT="$MOD/prefix_diagnostics.sh"
ENV_FLAGS_SCRIPT="$MOD/env_flags.sh"
LOG_VIEWER_SCRIPT="$MOD/log_viewer.sh"
ABOUT_SCRIPT="$MOD/about.sh"
WINE_INSTALL_MGR_SCRIPT="$MOD/wine_install_manager.sh"

wt_require_cmds zenity

# =============================================================================
#  Helper: run a module script
# =============================================================================

run_module() {
    local label="$1"; shift
    local script="$1"; shift
    local args=("$@")

    if [[ ! -x "$script" ]]; then
        wt_error_return "$(printf 'Module not found or not executable:\n  %s' "$script")"
        return 1
    fi
    "$script" "${args[@]}" || true
}

# =============================================================================
#  Helper: show a category submenu (looping)
#  Usage: show_submenu "Category Title" \
#             "tag1" "Module Name 1" "Description 1" \
#             "tag2" "Module Name 2" "Description 2" ...
# =============================================================================

show_submenu() {
    local title="$1"; shift
    local -a entries=("$@")   # flat: tag name desc  (triples)

    while true; do
        local -a zargs=()
        local i=0
        while (( i < ${#entries[@]} )); do
            zargs+=("${entries[$i]}" "${entries[$((i+1))]}" "${entries[$((i+2))]}")
            (( i += 3 ))
        done

        local choice
        choice=$(zenity --list \
            --title="$(wt_title "$title")" \
            --text="<tt>Select a module to run.\nCancel or close to go back.</tt>" \
            --column="Tag" --column="Module" --column="Description" \
            --hide-column=1 --print-column=1 \
            --width=740 --height=420 \
            "${zargs[@]}" \
            "back" "← Back to Main Menu" "") || return 0

        choice="${choice%%|*}"
        choice="${choice//[[:space:]]/}"

        case "$choice" in
            back|"") return 0 ;;
            *) _dispatch_module "$choice" ;;
        esac
    done
}

# =============================================================================
#  Module dispatcher — maps tags to actions
# =============================================================================

_dispatch_module() {
    local tag="$1"
    case "$tag" in

        # Graphics
        opt_dxvk)    run_module "DXVK Installer"          "$DXVK_SETUP_SCRIPT"       install ;;
        opt_vkd3d)   run_module "VKD3D-Proton Installer"  "$VKD3D_SETUP_SCRIPT"      install ;;
        opt_nvapi)   run_module "DXVK-NVAPI Installer"    "$NVAPI_SETUP_SCRIPT"              ;;

        # Runtimes
        opt_runtimes) run_module "Runtime Libraries"       "$RUNTIMES_SCRIPT"                ;;
        opt_dx10)     run_module "DirectX Jun 2010"        "$DIRECTX_2010_SCRIPT"            ;;

        # Wine
        opt_winetools)  run_module "Wine Tools"             "$WINE_TOOLS_SCRIPT"              ;;
        opt_dll)        run_module "DLL Override Manager"   "$DLL_OVERRIDE_SCRIPT"            ;;
        opt_winemgr)    run_module "Wine Install Manager"   "$WINE_INSTALL_MGR_SCRIPT"        ;;

        # Prefix
        opt_prefix)   run_module "Prefix Creator"          "$PREFIX_CREATOR_SCRIPT"          ;;
        opt_pfxmgr)   run_module "Prefix Manager"          "$PREFIX_MANAGER_SCRIPT"          ;;
        opt_pfxdiag)  run_module "Prefix Diagnostics"      "$PREFIX_DIAG_SCRIPT"             ;;
        opt_cfg)
            wt_select_prefix "Winecfg" || return
            wt_select_wine_bin "Winecfg" || return
            export WT_INNER_WINE WINEPREFIX WT_WRAPPER
            export WT_LIB_PATH="$SCRIPT_DIR/modules/winetoolz-lib.sh"
            local TMP
            TMP=$(mktemp --suffix=.sh)
            cat <<'INNEREOF' > "$TMP"
#!/usr/bin/env bash
set +e
source "$WT_LIB_PATH"
export WINEPREFIX
wt_section "winecfg"
wt_log_info "Wine   : $WT_INNER_WINE"
wt_log_info "Prefix : $WINEPREFIX"
printf '\n'
if [[ -n "$WT_WRAPPER" ]]; then
    "$WT_WRAPPER" run winecfg
else
    "$WT_INNER_WINE" winecfg
fi
read -rp "  Press Enter to close..." < /dev/tty
INNEREOF
            chmod +x "$TMP"
            wt_run_in_terminal "$TMP"
            ;;

        # Launch
        opt_launch)  run_module "App Launcher"             "$APP_LAUNCHER_SCRIPT"            ;;
        opt_env)     run_module "Env Flags"                "$ENV_FLAGS_SCRIPT"               ;;
        opt_log)     run_module "Log Viewer"               "$LOG_VIEWER_SCRIPT"              ;;

        # Components
        opt_sys)     run_module "System Component Installer" "$COMPONENT_INSTALL_SCRIPT"     ;;
        opt_dll_inst) run_module "DLL Installer"             "$DLL_INSTALLER_SCRIPT"          ;;

        # System
        opt_about)   run_module "About winetoolz"          "$ABOUT_SCRIPT"                   ;;

        *) wt_error_return "Unknown module tag: $tag" ;;
    esac
}

# =============================================================================
#  Category definitions
#  Each category is a tag + label + description for the top-level menu,
#  plus a list of module triples passed to show_submenu.
# =============================================================================

# Top-level category menu
while true; do
    CAT=$(zenity --list \
        --title="[ winetoolz  v${WT_VERSION} ]" \
        --text="<tt>Select a category.\nDouble-click or select and press OK.</tt>" \
        --column="Tag" --column="Category" --column="Description" \
        --hide-column=1 --print-column=1 \
        --width=620 --height=420 \
        "cat_graphics"    "🎮  Graphics"       "DXVK, VKD3D-Proton, DXVK-NVAPI" \
        "cat_runtimes"    "📦  Runtimes"       ".NET, VC++, XNA, DirectX, OpenAL, and more" \
        "cat_wine"        "🍷  Wine"           "Wine tools, DLL override manager" \
        "cat_prefix"      "📁  Prefix"         "Create, manage, backup, restore, diagnose prefixes" \
        "cat_launch"      "🚀  Launch"         "App launcher, env flags, log viewer" \
        "cat_components"  "🔧  Components"     "DLL installer, system file installer"  \
        "cat_system"      "ℹ   System"         "About / help / dependency checker" \
        "cat_exit"        "✖   Exit"           "Close winetoolz") || {
            echo "winetoolz: exiting."
            exit 0
        }

    CAT="${CAT%%|*}"
    CAT="${CAT//[[:space:]]/}"

    case "$CAT" in

        cat_graphics)
            show_submenu "Graphics" \
                "opt_dxvk"   "Install DXVK"          "Vulkan-based D3D8/9/10/11 translation layer" \
                "opt_vkd3d"  "Install VKD3D-Proton"  "Vulkan-based Direct3D 12 translation layer" \
                "opt_nvapi"  "Install DXVK-NVAPI"    "NVIDIA API layer for DLSS / NvAPI support"
            ;;

        cat_runtimes)
            show_submenu "Runtimes" \
                "opt_runtimes" "Runtime Libraries"         ".NET / XNA / XACT / VC++ / DirectPlay / OpenAL and more" \
                "opt_dx10"     "Install DirectX Jun 2010"  "Legacy DirectX offline redistributable package"
            ;;

        cat_wine)
            show_submenu "Wine" \
                "opt_winetools" "Wine Tools"           "Uninstaller, control, taskmgr, regedit, explorer, wineboot" \
                "opt_dll"       "DLL Override Manager" "View, apply presets, add custom, remove DLL overrides" \
                "opt_winemgr"   "Wine Install Manager" "Install, switch, uninstall, and manage custom Wine builds"
            ;;

        cat_prefix)
            show_submenu "Prefix" \
                "opt_prefix"  "Create Prefix"       "Bootstrap a new Wine/Proton prefix from scratch" \
                "opt_cfg"     "Winecfg"             "Open Wine configuration for an existing prefix" \
                "opt_pfxmgr"  "Prefix Manager"      "Backup, restore, regedit, kill processes, build manager" \
                "opt_pfxdiag" "Prefix Diagnostics"  "Health check — arch, Windows ver, DXVK, disk usage"
            ;;

        cat_launch)
            show_submenu "Launch" \
                "opt_launch" "App Launcher"  "Save and launch Wine app shortcuts with env profiles" \
                "opt_env"    "Env Flags"     "Manage launch environment variable profiles" \
                "opt_log"    "Log Viewer"    "Run an app and capture Wine stderr to a log file"
            ;;

        cat_components)
            show_submenu "Components" \
                "opt_dll_inst" "DLL Installer"       "Curated DLLs — d3dx9/10/11, d3dcomp, xinput, msxml, physx and more" \
                "opt_sys"      "System File Installer" "Extract + install DLLs from any archive into a prefix"
            ;;

        cat_system)
            show_submenu "System" \
                "opt_about" "About / Help" "Dependency checker, module reference, config paths"
            ;;

        cat_exit|*)
            echo "winetoolz: exiting."
            exit 0
            ;;
    esac

    sleep 0.1
done
