#!/bin/sh
_cdir=$(cd -- "$(dirname "$0")" && pwd)
_err() { echo "err: $1" >&2 && exit 1; }

export PATH="$HOME/.cabal/bin:$HOME/bin:$PATH:"
command -v shellcheck >/dev/null 2>&1 || _err "shellcheck not found."
if [ -z "$1" ]; then
	set -- "${_cdir}/../rpm-repo.sh"
fi
shellcheck "$@"
