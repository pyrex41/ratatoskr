#!/usr/bin/env bash
# Yggdrasil 2.0 - stage-2 Common Lisp (SBCL) builder.
#
#   builders/lisp/build.sh <shaken-dir> <output-exe>
#
# <shaken-dir> is a directory produced by (yggdrasil.shake ...): kernel.kl,
# user .kl files and yggdrasil.manifest.  Produces a self-contained native
# executable at <output-exe>.
#
# Overridable environment:
#   SHEN_BIN  - shen-cl binary       (default: $SHEN_CL/bin/sbcl/shen)
#   SBCL_BIN  - sbcl binary          (default: sbcl on PATH)
#   SHEN_CL   - shen-cl checkout     (default: sibling ../shen-cl)
set -euo pipefail

if [ $# -ne 2 ]; then
    echo "usage: $0 <shaken-dir> <output-exe>" >&2
    exit 2
fi

YGG_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SHEN_CL="${SHEN_CL:-$(cd "$YGG_ROOT/../shen-cl" && pwd)}"
SHEN_BIN="${SHEN_BIN:-$SHEN_CL/bin/sbcl/shen}"
SBCL_BIN="${SBCL_BIN:-sbcl}"

DIR="$1"
EXE="$2"
case "$DIR" in /*) ;; *) DIR="$PWD/$DIR" ;; esac
case "$EXE" in /*) ;; *) EXE="$PWD/$EXE" ;; esac

# Stage: compile KL -> Lisp, copy the shen-cl runtime + driver into DIR.
cd "$YGG_ROOT"
"$SHEN_BIN" eval -q \
    -l yggdrasil.shen \
    -l builders/lisp/build.shen \
    -e "(set lsp.*shen-cl* \"$SHEN_CL/\")" \
    -e "(lsp.build \"$DIR\" \"$EXE\")"

# Build: load the runtime + shaken kernel + user code, initialise, save.
cd "$DIR"
"$SBCL_BIN" --non-interactive --no-userinit --no-sysinit --load driver.lsp

rm -f "$DIR"/*.fasl
echo "yggdrasil/lisp: built $EXE"
