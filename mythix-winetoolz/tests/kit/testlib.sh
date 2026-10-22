#!/usr/bin/env bash
# Shared test machinery for the winetoolz test suites — source it from a
# test file, define test_* functions, then call run_all_tests.
#
#   run_all_tests <title>    runs every test_* (or those matching $FILTER),
#                            each in its own subshell under set -euo pipefail
#                            with an isolated HOME (tests/kit/harness.sh), the
#                            mock zenity and the mock terminal, with the lib
#                            sourced. Exits 1 if any test failed.
#   fail / assert_eq / assert_contains / assert_not_contains / log_has
#   fixture_wine / fixture_vulkan / run_module / wine_calls / wine_argv / wine_env
#   fake_wine / fake_wrapper / fake_prefix / fake_pe / builtin_dll
#   fake_catalog / catalog_add / catalog_seed / mkcab / mksfx / fake_zstd

TESTLIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=harness.sh
source "$TESTLIB_DIR/harness.sh"
LIB="$WT_ROOT/modules/winetoolz-lib.sh"
FILTER="${FILTER:-}"

PASS=0 FAIL=0 SKIP=0
declare -a FAILED=()

fail() { printf '    FAIL: %s\n' "$*" >&2; return 1; }
assert_eq() {  # <expected> <actual> [what]
    [[ "$1" == "$2" ]] || fail "${3:-value}: expected [$1], got [$2]"
}
assert_contains() {  # <haystack> <needle> [what]
    [[ "$1" == *"$2"* ]] || fail "${3:-text} does not contain [$2]: [$1]"
}
log_has() {  # <plain text> — the mock logs args %q-quoted; accept either form
    grep -qF -- "$1" "$ZMOCK_LOG" || grep -qF -- "$(printf '%q' "$1")" "$ZMOCK_LOG" \
        || fail "zenity log does not contain [$1]"
}
assert_not_contains() {
    [[ "$1" != *"$2"* ]] || fail "${3:-text} unexpectedly contains [$2]"
}

run_test() {
    local name="$1"
    [[ -z "$FILTER" || "$name" == *"$FILTER"* ]] || return 0
    local out rc
    # Not inside an && / || list: bash would silently ignore the tests'
    # `set -e` there, and a failed assertion would not stop the test.
    out="$(
        exec 2>&1
        wt_kit_setup
        trap 'wt_kit_teardown' EXIT
        export WT_ASSUME_GUI=1 WT_TERMINAL=xterm
        set -euo pipefail
        # shellcheck source=../modules/winetoolz-lib.sh
        source "$LIB"
        "$name"
        wt_kit_markup_ok
    )"
    rc=$?
    if (( rc == 0 )) && [[ "$out" == *"(skipped"* ]]; then
        SKIP=$((SKIP + 1))
        printf '  skip  %s %s\n' "$name" "$(grep -o '(skipped[^)]*)' <<< "$out" | head -1)"
    elif (( rc == 0 )); then
        PASS=$((PASS + 1))
        printf '  ok    %s\n' "$name"
    else
        FAIL=$((FAIL + 1))
        FAILED+=("$name")
        printf '  FAIL  %s (rc=%s)\n%s\n' "$name" "$rc" "$(printf '%s\n' "$out" | sed 's/^/        /' | tail -n 25)"
    fi
}

# --- shared fixtures --------------------------------------------------------------

MODS="$WT_ROOT/modules/shared_lib"
FAKE_WINE_REL="wine-custom/buildz/test-wine/bin/wine"

fixture_wine() {  # a selectable fake Wine build at ~/$FAKE_WINE_REL
    fake_wine "$HOME/$FAKE_WINE_REL" "wine-9.99 (test)"
}

fixture_vulkan() {  # a Vulkan ICD so the modules do not ask about it
    mkdir -p "$HOME/.local/share/vulkan/icd.d"
    printf '{}\n' > "$HOME/.local/share/vulkan/icd.d/test_icd.json"
}

run_module() {  # <module.sh> [args] — as the menu runs it
    local rc=0
    wt_kit_run "$MODS/$1" "${@:2}" >"$KIT_TMP/module.out" 2>&1 || rc=$?
    return "$rc"
}

fake_cmd() {  # <name> [sh code] — a stand-in command on PATH that logs its
              # calls to $KIT_TMP/fake-cmds.log, then runs the code
    mkdir -p "$KIT_TMP/fakebin"
    { printf '#!/bin/sh\necho "%s $*" >> "%s/fake-cmds.log"\n' "$1" "$KIT_TMP"; printf '%s\n' "${2:-}"; } \
        > "$KIT_TMP/fakebin/$1"
    chmod +x "$KIT_TMP/fakebin/$1"
    case ":$PATH:" in *":$KIT_TMP/fakebin:"*) ;; *) export PATH="$KIT_TMP/fakebin:$PATH" ;; esac
}

real_prefix_copy() {  # <source prefix> <dest> — a real prefix to test on
    mkdir -p "$(dirname "$2")"
    cp -a -- "$1" "$2"
    rm -rf -- "$2/drive_c/users/"*/Temp/* 2>/dev/null || true
}

wine_calls() { cat "$KIT_TMP/wine-calls.log" 2>/dev/null || true; }
wine_argv() { cat "$KIT_TMP/wine-argv.log" 2>/dev/null || true; }
wine_env() { cat "$KIT_TMP/wine-env.last" 2>/dev/null || true; }

# --- helpers to build fake installs -------------------------------------------

fake_wine() {  # <path> [version]
    # Logs every call; "wineboot" creates a minimal prefix in $WINEPREFIX,
    # like the real one does.
    mkdir -p "$(dirname "$1")"
    cat > "$1" <<EOF
#!/bin/sh
[ "\$1" = --version ] && { echo "${2:-wine-9.99}"; exit 0; }
echo "ran \$*" >> "$KIT_TMP/wine-calls.log"
# Argument boundaries ([arg1][arg2]...) and the environment of the last call.
for a in "\$@"; do printf '[%s]' "\$a"; done >> "$KIT_TMP/wine-argv.log"; echo >> "$KIT_TMP/wine-argv.log"
{ echo "PWD=\$PWD"; env; } > "$KIT_TMP/wine-env.last"
# FAKE_WINE_FAIL=<text>: any call whose arguments contain it exits 1.
if [ -n "\${FAKE_WINE_FAIL:-}" ]; then
    case "\$*" in *"\$FAKE_WINE_FAIL"*) exit 1 ;; esac
fi
if [ "\$1" = wineboot ] && [ -n "\$WINEPREFIX" ]; then
    mkdir -p "\$WINEPREFIX/drive_c/windows/system32" "\$WINEPREFIX/dosdevices"
    printf 'WINE REGISTRY Version 2\\n#arch=%s\\n' "\${WINEARCH:-win64}" > "\$WINEPREFIX/system.reg"
    : > "\$WINEPREFIX/user.reg"
    : > "\$WINEPREFIX/drive_c/windows/system32/wineboot.exe"
fi
exit 0
EOF
    chmod +x "$1"
}

fake_wine_reg() {  # <path> — a fake Wine whose `reg add/delete/query` work on
                   # a small registry kept in $WINEPREFIX/fake-reg.json, with
                   # the output format of Wine's reg.exe (CRLF, 4-space columns)
    mkdir -p "$(dirname "$1")"
    cat > "$1" <<EOF
#!/usr/bin/env -S python3 -I
import json, os, sys
args = sys.argv[1:]
if args[:1] == ["--version"]:
    print("wine-9.99 (test)"); sys.exit(0)
with open("$KIT_TMP/wine-calls.log", "a") as f:
    f.write("ran " + " ".join(args) + "\n")
if args[:1] != ["reg"]:
    sys.exit(0)
db_path = os.path.join(os.environ["WINEPREFIX"], "fake-reg.json")
try:
    db = json.load(open(db_path))
except FileNotFoundError:
    db = {"keys": [], "values": {}}
def norm(k): return k.rstrip("\\\\").lower()
def key_exists(k):
    return any(norm(x) == norm(k) for x in db["keys"])
def add_key(k):
    parts = k.rstrip("\\\\").split("\\\\")
    for i in range(1, len(parts) + 1):
        sub = "\\\\".join(parts[:i])
        if not key_exists(sub): db["keys"].append(sub)
def opt(name):
    for i, a in enumerate(args):
        if a.lower() == name and i + 1 < len(args): return args[i + 1]
    return None
out = sys.stdout
cmd, key = args[1].lower(), args[2]
if cmd == "add":
    add_key(key)
    name = opt("/v")
    if name is not None:
        db["values"].setdefault(norm(key), {})[name.lower()] = [name, opt("/d") or ""]
elif cmd == "delete":
    name = opt("/v")
    vals = db["values"].get(norm(key), {})
    if name is None or name.lower() not in vals:
        sys.stderr.write("reg: Unable to find the specified registry value\n"); sys.exit(1)
    del vals[name.lower()]
elif cmd == "query":
    if not key_exists(key):
        sys.stderr.write("reg: Unable to find the specified registry key\n"); sys.exit(1)
    recurse = "/s" in [a.lower() for a in args]
    # Like Wine: a key's path is printed above its values (not at all when
    # it has none); subkeys keep the case they were created with.
    def show(k):
        vals = db["values"].get(norm(k), {})
        if vals:
            out.write("%s\r\n" % k)
            for name, data in vals.values():
                out.write("    %s    REG_SZ    %s\r\n" % (name, data))
            out.write("\r\n")
        n = len(norm(k)) + 1
        for x in db["keys"]:
            if norm(x).startswith(norm(k) + "\\\\") and "\\\\" not in x[n:]:
                sub = k + "\\\\" + x[n:]
                if recurse: show(sub)
                else: out.write("%s\r\n" % sub)
    out.write("\r\n")
    show(key.rstrip("\\\\"))
json.dump(db, open(db_path, "w"))
EOF
    chmod +x "$1"
}

fake_reg_get() {  # <prefix> <key> <name> — a value from fake_wine_reg's registry
    python3 -I - "$1/fake-reg.json" "$2" "$3" <<'PY2'
import json, sys
db = json.load(open(sys.argv[1]))
v = db["values"].get(sys.argv[2].lower(), {}).get(sys.argv[3].lower())
print(v[1] if v else "<unset>")
PY2
}

fake_net() {  # puts a fake curl on PATH: GitHub API answers come from
              # $KIT_TMP/net/api/<owner>_<repo>[_list].json, downloads from
              # $KIT_TMP/net/files/<file name>; anything else is a 404
    mkdir -p "$KIT_TMP/netbin" "$KIT_TMP/net/api" "$KIT_TMP/net/files"
    cat > "$KIT_TMP/netbin/curl" <<'EOF'
#!/usr/bin/env bash
net="$KIT_TMP/net" out="" url="" prev=""
for a in "$@"; do
    [[ "$prev" == --output ]] && out="$a"
    [[ "$prev" == -- ]] && url="$a"
    prev="$a"
done
[[ " $* " == *" --config - "* ]] && cat > /dev/null
echo "curl $url" >> "$KIT_TMP/curl-calls.log"
case "$url" in
    https://api.github.com/repos/*/releases/latest)
        r="${url#https://api.github.com/repos/}"; r="${r%/releases/latest}"
        f="$net/api/${r//\//_}.json" ;;
    https://api.github.com/repos/*/releases\?*)
        r="${url#https://api.github.com/repos/}"; r="${r%/releases\?*}"
        f="$net/api/${r//\//_}_list.json" ;;
    https://*)
        n="${url%%[?#]*}"; f="$net/files/${n##*/}" ;;
    *)  echo "curl: (1) Protocol not supported" >&2; exit 1 ;;
esac
if [[ ! -f "$f" ]]; then echo "curl: (22) The requested URL returned error: 404" >&2; exit 22; fi
if [[ -n "$out" ]]; then cp -- "$f" "$out"; else cat -- "$f"; fi
EOF
    chmod +x "$KIT_TMP/netbin/curl"
    export PATH="$KIT_TMP/netbin:$PATH"
}

catalog_add() {  # <key> <file> [name] — a downloads.tsv line for a fixture file
    local sum
    sum="$(sha256sum "$2")"; sum="${sum%% *}"
    printf '%s  %s  %s  https://fixture.invalid/%s\n' "$1" "$sum" "${3:-$(basename "$2")}" "${3:-$(basename "$2")}" \
        >> "$WT_DOWNLOADS_LIST"
}

catalog_seed() {  # <key> <file> [name] — catalog entry + verified copy in the cache
    local name="${3:-$(basename "$2")}"
    catalog_add "$1" "$2" "$name"
    mkdir -p "$HOME/.cache/winetoolz/downloads"
    cp "$2" "$HOME/.cache/winetoolz/downloads/$name"
}

fake_catalog() {  # an empty test catalog in place of modules/downloads.tsv
    export WT_DOWNLOADS_LIST="$KIT_TMP/downloads.tsv"
    : > "$WT_DOWNLOADS_LIST"
}

mkcab() { python3 -I "$TESTLIB_DIR/mkcab.py" "$@"; }

mksfx() {  # <out.exe> <member=file>... — a cabinet behind a PE stub, like a
           # self-extracting Microsoft redistributable (cabextract finds it)
    local out="$1"; shift
    mkcab "$out.cab" "$@"
    fake_pe "$out" x86
    head -c 1024 /dev/zero >> "$out"
    cat "$out.cab" >> "$out"
    rm -f "$out.cab"
}

fake_zstd() {  # puts a gzip-backed stand-in for zstd on PATH (tests only)
    mkdir -p "$KIT_TMP/zbin"
    printf '#!/bin/sh\nfor a in "$@"; do [ "$a" = -d ] && exec gzip -dc; done\nexec gzip -c\n' > "$KIT_TMP/zbin/zstd"
    chmod +x "$KIT_TMP/zbin/zstd"
    export PATH="$KIT_TMP/zbin:$PATH"
}

fake_wrapper() {  # <tool_dir> <proton|neutron>  — a wrapper that must never run
    mkdir -p "$1"
    printf '#!/bin/sh\necho "WRAPPER RAN: $0 $*" >> "%s/wrapper-ran.log"\nexit 1\n' "$KIT_TMP" > "$1/$2"
    chmod +x "$1/$2"
    fake_wine "$1/files/bin/wine" "wine-9.0 (Proton)"
    printf '1717000000 %s\n' "$(basename "$1")" > "$1/version"
}

fake_prefix() {  # <dir> [arch]
    mkdir -p "$1/drive_c/windows/system32"
    printf 'WINE REGISTRY Version 2\n;; All keys relative to \\\\Machine\n\n#arch=%s\n' "${2:-win64}" > "$1/system.reg"
    : > "$1/drive_c/windows/system32/wineboot.exe"
    [[ "${2:-win64}" == win64 ]] && mkdir -p "$1/drive_c/windows/syswow64"
    return 0
}


fake_pe() {  # <path> <x64|x86>  — a minimal PE header with the machine field
    python3 -I - "$1" "$2" <<'PY2'
import struct, sys
path, arch = sys.argv[1], sys.argv[2]
machine = {"x64": 0x8664, "x86": 0x14c}[arch]
dos = bytearray(0x80)
dos[0:2] = b"MZ"
struct.pack_into("<I", dos, 0x3c, 0x80)
pe = b"PE\0\0" + struct.pack("<H", machine) + b"\0" * 18
open(path, "wb").write(bytes(dos) + pe + b"payload")
PY2
}

builtin_dll() {  # <path> — a file carrying Wine's builtin stamp
    { printf 'MZ'; head -c 62 /dev/zero; printf 'Wine builtin DLL'; } > "$1"
}

run_all_tests() {
    local title="$1" t
    local -a all=()
    mapfile -t all < <(declare -F | awk '{print $3}' | grep '^test_')
    printf '%s\n' "$title"
    for t in "${all[@]}"; do run_test "$t"; done
    printf '\n%d passed, %d failed%s\n' "$PASS" "$FAIL" "$( (( SKIP )) && printf ', %d skipped' "$SKIP")"
    if (( FAIL )); then
        printf 'failed: %s\n' "${FAILED[*]}"
        exit 1
    fi
}
