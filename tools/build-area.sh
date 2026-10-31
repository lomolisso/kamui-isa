#!/usr/bin/env bash
# Look after the kamui-isa build area, /scratch/$USER/kamui-isa on the build host (see docs/development.md).
#
#   tools/build-area.sh status            sizes against the budget, free disk, load of iacoma231 and 232,
#                                         our running dev containers
#   tools/build-area.sh clean [<name>]    delete build/<name>; default: the checkout this script is in
#   tools/build-area.sh prune             delete build/<name> of every worktree that no longer exists
#   tools/build-area.sh ps                list our running dev containers
#   tools/build-area.sh stop [<name>]     stop our dev containers (all of them, or one by container name)
#
# Like tools/dev.sh, it runs itself on the build host over ssh when called anywhere else.
#
# Environment:
#   KAMUI_BUILD_HOST       build host (default iacoma231); "local" means this machine
#   KAMUI_BUILD_AREA       build area (default /scratch/$USER/kamui-isa)
#   KAMUI_BUILD_BUDGET_GB  soft limit for the whole build area (default 50)
#   KAMUI_MIN_FREE_GB      free space to keep on the build area's disk (default 100)
#   KAMUI_LOAD_HOSTS       hosts whose load "status" prints (default "iacoma231 iacoma232")
#   KAMUI_DOCKER           docker command (default docker)
set -euo pipefail

host="${KAMUI_BUILD_HOST:-iacoma231}"
budget="${KAMUI_BUILD_BUDGET_GB:-50}"
min_free="${KAMUI_MIN_FREE_GB:-100}"
self="$(realpath "$0")"

if [ "$host" != local ] && [ "$(hostname -s)" != "${host%%.*}" ]; then
  remote="cd $(printf %q "$PWD") && KAMUI_BUILD_HOST=local"
  for v in KAMUI_BUILD_AREA KAMUI_BUILD_BUDGET_GB KAMUI_MIN_FREE_GB KAMUI_LOAD_HOSTS KAMUI_DOCKER; do
    [ -n "${!v:-}" ] && remote+=" $v=$(printf %q "${!v}")"
  done
  remote+=" exec $(printf %q "$self")"
  [ $# -gt 0 ] && remote+=" $(printf '%q ' "$@")"
  exec ssh -o BatchMode=yes "$host" "$remote"
fi

top="$(dirname "$(dirname "$self")")"
case "$top" in
  */.worktrees/*) root="${top%%/.worktrees/*}"; here="${top#"$root"/.worktrees/}"; here="${here//\//-}" ;;
  *) root="$top"; here=main ;;
esac
area="${KAMUI_BUILD_AREA:-/scratch/$USER/kamui-isa}"
prefix="kamui-isa-$USER-"
load_hosts="${KAMUI_LOAD_HOSTS-iacoma231 iacoma232}"
read -r -a docker <<< "${KAMUI_DOCKER:-docker}"

ours() { "${docker[@]}" ps --filter "name=^$prefix" --format '{{.Names}}\t{{.Status}}\t{{.Command}}'; }

check_name() {
  case "$1" in
    ''|.|..|*/*) echo "build-area.sh: bad checkout name '$1'" >&2; exit 2 ;;
  esac
}

remove_build() {   # remove_build <name>
  local name="$1" dir="$area/build/$1"
  check_name "$name"
  if "${docker[@]}" ps --filter "name=^$prefix$name-[0-9]+\$" --format '{{.Names}}' | grep -q .; then
    echo "build-area.sh: a dev container of '$name' is still running; stop it first (tools/build-area.sh ps)" >&2
    exit 1
  fi
  if [ -d "$dir" ]; then
    echo "removing $dir ($(du -sh "$dir" | cut -f1))"
    rm -rf "$dir"
  else
    echo "nothing to remove: $dir does not exist"
  fi
}

cmd="${1:-status}"
[ $# -gt 0 ] && shift
case "$cmd" in
  status)
    echo "build area: $(hostname -s):$area"
    if [ -d "$area" ]; then
      for d in "$area"/build/* "$area"/keep/*; do
        [ -e "$d" ] && printf '  %-8s %s\n' "$(du -sh "$d" | cut -f1)" "${d#"$area"/}"
      done
      used_gb=$(( $(du -sk "$area" | cut -f1) / 1048576 ))
    else
      echo "  (does not exist yet)"
      used_gb=0
    fi
    echo "total: ${used_gb} GB of a ${budget} GB budget"
    disk="$area"; [ -d "$disk" ] || disk="$(dirname "$area")"
    df -h "$disk" | sed 's/^/  /'
    free_gb=$(df -BG --output=avail "$disk" | tail -1 | tr -dc 0-9)
    echo "load (1, 5, 15 min):"
    echo "  $(hostname -s): $(cut -d' ' -f1-3 /proc/loadavg)"
    for h in $load_hosts; do
      [ "$h" = "$(hostname -s)" ] && continue
      echo "  $h: $(ssh -o BatchMode=yes -o ConnectTimeout=5 "$h" "cut -d' ' -f1-3 /proc/loadavg" 2>/dev/null || echo unreachable)"
    done
    echo "our dev containers:"
    ours | sed 's/^/  /'
    [ "$used_gb" -gt "$budget" ] && echo "WARNING: the build area is over its ${budget} GB budget; clean up (docs/tools/build-host.md)"
    [ "$free_gb" -lt "$min_free" ] && echo "WARNING: only ${free_gb} GB free on the build disk (keep ${min_free} GB); stop and ask the maintainers"
    true
    ;;
  clean)
    remove_build "${1:-$here}"
    ;;
  prune)
    [ -d "$area/build" ] || { echo "nothing to prune"; exit 0; }
    for d in "$area"/build/*; do
      [ -d "$d" ] || continue
      name="${d##*/}"
      [ "$name" = main ] && continue
      [ -d "$root/.worktrees/$name" ] || remove_build "$name"
    done
    ;;
  ps)
    ours
    ;;
  stop)
    if [ $# -gt 0 ]; then
      case "$1" in "$prefix"*) "${docker[@]}" stop "$1" ;; *) echo "build-area.sh: not one of ours: $1" >&2; exit 2 ;; esac
    else
      names=$("${docker[@]}" ps --filter "name=^$prefix" --format '{{.Names}}')
      if [ -n "$names" ]; then
        # shellcheck disable=SC2086
        "${docker[@]}" stop $names
      else
        echo "no dev containers running"
      fi
    fi
    ;;
  -h|--help|help)
    sed -n '2,20p' "$self" | sed 's/^# \{0,1\}//'
    ;;
  *)
    echo "build-area.sh: unknown command '$cmd' (try --help)" >&2
    exit 2
    ;;
esac
