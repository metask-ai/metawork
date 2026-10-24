#!/bin/sh
set -eu
case "${1-}" in python|node) KIND=$1 ;; *) echo 'Usage: run.sh python | node script [arguments]' >&2; exit 2 ;; esac
[ "$#" -ge 2 ] || exit 2
RESOURCES=$(CDPATH= cd -P "$(/usr/bin/dirname "$0")" && /bin/pwd -P)
. "$RESOURCES/environment.sh"
export NODE_OPTIONS='' NODE_PATH=''
case "${HOME-}" in /*) ;; *) echo 'Office requires an absolute HOME' >&2; exit 2 ;; esac
[ -d "$HOME" ] || exit 2
USER_HOME=$(CDPATH= cd -P "$HOME" && /bin/pwd -P)
BASE="$USER_HOME/Library/Application Support/$OFFICE_NAMESPACE"
if [ "$KIND" = python ]; then ID=$PYTHON_ID; EXE=$PYTHON_EXE; else ID=$NODE_ID; EXE=$NODE_EXE; fi
METAWORK_OFFICE_ENV="$BASE/$KIND-$ID"
export METAWORK_OFFICE_ENV
if [ -L "$METAWORK_OFFICE_ENV" ] || [ ! -d "$METAWORK_OFFICE_ENV" ] || [ ! -f "$METAWORK_OFFICE_ENV/$EXE" ]; then
    echo "Office environment missing or unavailable: $METAWORK_OFFICE_ENV. Ask the user before prepare.sh $KIND." >&2; exit 3
fi
if [ "$KIND" = python ]; then
    exec "$METAWORK_OFFICE_ENV/$EXE" -I -B "$RESOURCES/run.py" "$@"
else
    exec "$METAWORK_OFFICE_ENV/$EXE" "$RESOURCES/run.cjs" "$@"
fi
