#!/bin/sh
# Fixed macOS bootstrap. No PATH interpreter or user-selectable install input.
set -eu
umask 077
case "${1-}" in python|node) KIND=$1 ;; *) echo 'Usage: prepare.sh python | node' >&2; exit 2 ;; esac
[ "$#" -eq 1 ] || exit 2
RESOURCES=$(CDPATH= cd -P "$(/usr/bin/dirname "$0")" && /bin/pwd -P)
. "$RESOURCES/environment.sh"
export NODE_OPTIONS='' NODE_PATH=''
case "${HOME-}" in /*) ;; *) echo 'Office requires an absolute HOME' >&2; exit 2 ;; esac
[ -d "$HOME" ] || exit 2
USER_HOME=$(CDPATH= cd -P "$HOME" && /bin/pwd -P)
/bin/mkdir -p "$USER_HOME/Library/Application Support/$OFFICE_NAMESPACE"
BASE=$(CDPATH= cd -P "$USER_HOME/Library/Application Support/$OFFICE_NAMESPACE" && /bin/pwd -P)
PYTHON_FINAL="$BASE/python-$PYTHON_ID"
if [ "$KIND" = python ]; then ID=$PYTHON_ID; URL=$PYTHON_URL; SHA=$PYTHON_SHA; else ID=$NODE_ID; URL=$NODE_URL; SHA=$NODE_SHA; fi
FINAL="$BASE/$KIND-$ID"
check_final() {
    [ ! -L "$FINAL" ] && [ -d "$FINAL" ] || return 1
    if [ "$KIND" = python ]; then
        "$FINAL/$PYTHON_EXE" -I -B "$RESOURCES/finish.py" --check "$FINAL"
    else
        "$FINAL/$NODE_EXE" "$RESOURCES/finish.cjs" --check "$FINAL"
    fi
}
unavailable() {
    echo "Office environment unavailable: $FINAL" >&2
    echo 'Manual recovery: stop all tasks and scripts using this directory, then exit MetaWork.' >&2
    echo 'Confirm no consumers remain before explicitly choosing to remove only this exact directory.' >&2
    echo 'Do not remove its parent directory. Reopen MetaWork and request preparation again.' >&2
    exit 1
}
if [ -e "$FINAL" ] || [ -L "$FINAL" ]; then check_final || unavailable; exit 0; fi
# A completed Node checks itself and never needs Python; only a fresh publish does.
if [ "$KIND" = node ]; then
    if [ -L "$PYTHON_FINAL" ] || [ ! -d "$PYTHON_FINAL" ]; then
        echo 'First prepare the fixed private Python environment; Node has not been downloaded.' >&2; exit 3
    fi
    "$PYTHON_FINAL/$PYTHON_EXE" -I -B "$RESOURCES/finish.py" --check "$PYTHON_FINAL" || {
        echo "Required private Python unavailable: $PYTHON_FINAL" >&2; exit 1;
    }
fi
STAGE=$(/usr/bin/mktemp -d "$BASE/.$KIND.XXXXXXXX")
CHILD=''
cleanup() {
    if [ -n "$CHILD" ]; then
        kill -TERM "$CHILD" 2>/dev/null || :
        wait "$CHILD" 2>/dev/null || :
        CHILD=''
    fi
    if [ -f "$STAGE/.process-not-stopped" ]; then
        echo "Office preparation stopped without confirmed child exit; stage preserved: $STAGE" >&2
    else
        /bin/rm -rf "$STAGE"
    fi
}
trap cleanup EXIT
trap 'trap "" INT TERM; exit 130' INT TERM
run_owned() {
    "$@" & CHILD=$!
    if wait "$CHILD"; then RESULT=0; else RESULT=$?; fi
    CHILD=''
    return "$RESULT"
}
run_owned /usr/bin/curl --fail --silent --show-error --location --proto =https --proto-redir =https --connect-timeout 30 --speed-limit 1024 --speed-time 90 --max-time 1800 --output "$STAGE/download.tar.gz" "$URL"
run_owned /usr/bin/shasum -a 256 "$STAGE/download.tar.gz" > "$STAGE/download.sha256"
IFS=' ' read -r ACTUAL REST < "$STAGE/download.sha256"
[ "$ACTUAL" = "$SHA" ] || { echo 'Office runtime SHA-256 mismatch' >&2; exit 1; }
run_owned /usr/bin/tar -xf "$STAGE/download.tar.gz" -C "$STAGE"
/bin/rm "$STAGE/download.tar.gz" "$STAGE/download.sha256"
if [ "$KIND" = python ]; then
    if run_owned "$STAGE/$PYTHON_EXE" -I -B "$RESOURCES/finish.py" "$STAGE" "$FINAL" "$RESOURCES"; then :; else
        if [ -e "$FINAL" ] || [ -L "$FINAL" ]; then unavailable; fi
        echo 'Office dependency preparation failed; completed environments were preserved.' >&2; exit 1
    fi
else
    if run_owned "$PYTHON_FINAL/$PYTHON_EXE" -I -B "$RESOURCES/finish.py" --node "$STAGE" "$FINAL" "$RESOURCES"; then :; else
        if [ -e "$FINAL" ] || [ -L "$FINAL" ]; then unavailable; fi
        echo 'Office dependency preparation failed; completed environments were preserved.' >&2; exit 1
    fi
fi
# Only a new process at the final path can prove relocatability.
check_final || unavailable
