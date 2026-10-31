#!/usr/bin/env bash
# Run a command (or an interactive shell) in the kamui-isa dev container, on the build host.
#
#   tools/dev.sh                      interactive bash in the current directory
#   tools/dev.sh 'clang --version'    run one command
#
# Builds, tests and containers run on the build host (iacoma231 by default), never on the machine where you
# edit. Called on any other machine, this script runs itself again on the build host over ssh, in the same
# directory (the home directory is shared over NFS). See docs/development.md.
#
# What the container sees:
#   the main repository root, at its own host path (git works in worktrees)
#   the build area, at its own path
#   <build area>/build/<checkout>                   mounted over <checkout>/build
#   every path in KAMUI_EXTRA_MOUNTS, at its own path
# <checkout> is "main" for the main checkout and <name> for the worktree .worktrees/<name>.
#
# Environment:
#   KAMUI_BUILD_HOST     build host (default iacoma231); "local" means this machine (for CI)
#   KAMUI_BUILD_AREA     build area on the build host (default /scratch/$USER/kamui-isa)
#   KAMUI_DEV_IMAGE      image (default kamui-isa-dev:0.2)
#   KAMUI_DEV_MEMORY     memory cap of the container (default 128g)
#   KAMUI_EXTRA_MOUNTS   colon-separated host paths to mount as well (default none)
#   KAMUI_DOCKER         docker command (default docker)
set -euo pipefail

host="${KAMUI_BUILD_HOST:-iacoma231}"
image="${KAMUI_DEV_IMAGE:-kamui-isa-dev:0.2}"
memory="${KAMUI_DEV_MEMORY:-128g}"
extra="${KAMUI_EXTRA_MOUNTS:-}"
self="$(realpath "$0")"

# 1. Not on the build host: run this same script there, in the same directory.
if [ "$host" != local ] && [ "$(hostname -s)" != "${host%%.*}" ]; then
  ssh_flags=(-o BatchMode=yes)
  [ -t 0 ] && [ -t 1 ] && ssh_flags+=(-t)
  remote="cd $(printf %q "$PWD") && KAMUI_BUILD_HOST=local"
  for v in KAMUI_BUILD_AREA KAMUI_DEV_IMAGE KAMUI_DEV_MEMORY KAMUI_EXTRA_MOUNTS KAMUI_DOCKER; do
    [ -n "${!v:-}" ] && remote+=" $v=$(printf %q "${!v}")"
  done
  remote+=" exec $(printf %q "$self")"
  [ $# -gt 0 ] && remote+=" $(printf '%q ' "$@")"
  exec ssh "${ssh_flags[@]}" "$host" "$remote"
fi

# 2. Which checkout is this? The script lives in <checkout>/tools/.
top="$(dirname "$(dirname "$self")")"
case "$top" in
  */.worktrees/*) root="${top%%/.worktrees/*}"; checkout="${top#"$root"/.worktrees/}"; checkout="${checkout//\//-}" ;;
  *) root="$top"; checkout=main ;;
esac

# 3. The build area on this host's local disk.
area="${KAMUI_BUILD_AREA:-/scratch/$USER/kamui-isa}"
mkdir -p "$area/build/$checkout" "$area/keep" "$top/build"   # $top/build is only the mount point

tty_flags=(-i)
[ -t 0 ] && [ -t 1 ] && tty_flags=(-it)

mounts=(-v "$root":"$root" -v "$area":"$area" -v "$area/build/$checkout":"$top/build")
if [ -n "$extra" ]; then
  IFS=: read -r -a extra_paths <<< "$extra"
  for p in "${extra_paths[@]}"; do
    [ -n "$p" ] && mounts+=(-v "$p":"$p")
  done
fi

read -r -a docker <<< "${KAMUI_DOCKER:-docker}"
run=("${docker[@]}" run --rm --init "${tty_flags[@]}"
  --name "kamui-isa-$USER-$checkout-$$"
  --memory "$memory" --memory-swap "$memory"
  "${mounts[@]}"
  -w "$PWD" "$image")

if [ $# -eq 0 ]; then
  exec "${run[@]}" bash
fi
exec "${run[@]}" bash -lc "$*"
