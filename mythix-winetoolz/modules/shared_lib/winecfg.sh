#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
#  winecfg.sh — Winecfg
#  winetoolz v3.0
#  Opens Wine's configuration dialog for an existing prefix.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../winetoolz-lib.sh"

MODULE="Winecfg"

wt_require_cmds zenity

wt_select_prefix_from_config "$MODULE" || exit 0
wt_select_wine_bin "$MODULE" || exit 0
export WT_INNER_WINE WINEPREFIX

TMP=$(mktemp --suffix=.sh)
trap 'rm -f "$TMP"' EXIT

cat <<'INNEREOF' > "$TMP"
#!/usr/bin/env bash
set +e
source "$WT_LIB_PATH"
wt_section "winecfg"
wt_log_info "Wine   : $WT_INNER_WINE"
wt_log_info "Prefix : $WINEPREFIX"
printf '\n'
# The inner wine, never the Proton/Neutron wrapper: the wrapper needs Steam's
# STEAM_COMPAT_DATA_PATH, and Neutron would open its own default prefix.
"$WT_INNER_WINE" winecfg
rc=$?
if (( rc == 0 )); then wt_log_ok "winecfg closed."; else wt_log_err "winecfg exited with code $rc."; fi
wt_pause
exit "$rc"
INNEREOF
chmod +x "$TMP"
wt_run_in_terminal "$TMP"
