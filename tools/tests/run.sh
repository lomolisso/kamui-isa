#!/usr/bin/env bash
# Tests for tools/dev.sh and tools/build-area.sh. They use stub docker and ssh commands and a throwaway build
# area under build/tool-tests, so they need neither Docker nor the build host.
#
#   tools/tests/run.sh
set -euo pipefail

top="$(cd "$(dirname "$0")/../.." && pwd)"
work="$top/build/tool-tests"
rm -rf "$work"
mkdir -p "$work/bin" "$work/area"
export USER="${USER:-tester}"

# Stub docker: logs its arguments, one per line; "ps" prints $STUB_PS.
cat > "$work/bin/docker" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = ps ]; then printf '%s' "${STUB_PS:-}"; exit 0; fi
printf '%s\n' "$@" > "$STUB_LOG"
EOF
# Stub ssh: runs the remote command locally, the way a remote login shell would.
cat > "$work/bin/ssh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$STUB_SSH_LOG"
cmd="${!#}"
exec bash -c "$cmd"
EOF
chmod +x "$work/bin/docker" "$work/bin/ssh"

export STUB_LOG="$work/docker.log" STUB_SSH_LOG="$work/ssh.log"
export KAMUI_DOCKER="$work/bin/docker" KAMUI_BUILD_AREA="$work/area" KAMUI_LOAD_HOSTS=""
pass=0 fail=0
check() {   # check <description> <command...>
  local what="$1"; shift
  if "$@"; then pass=$((pass + 1)); echo "ok    $what"; else fail=$((fail + 1)); echo "FAIL  $what"; fi
}
has_line() { grep -qxF -- "$2" "$1"; }

checkout=main
case "$top" in */.worktrees/*) checkout="${top##*/.worktrees/}"; checkout="${checkout//\//-}" ;; esac

# dev.sh, run locally
KAMUI_BUILD_HOST=local "$top/tools/dev.sh" 'echo "a b"' >/dev/null
check "dev.sh mounts the build area over build/" has_line "$STUB_LOG" "$work/area/build/$checkout:$top/build"
check "dev.sh mounts the build area itself" has_line "$STUB_LOG" "$work/area:$work/area"
check "dev.sh passes the command to bash -lc" has_line "$STUB_LOG" 'echo "a b"'
check "dev.sh names the container" grep -q "^kamui-isa-$USER-$checkout-[0-9]*\$" "$STUB_LOG"
check "dev.sh creates the build directory" test -d "$work/area/build/$checkout"

KAMUI_BUILD_HOST=local KAMUI_EXTRA_MOUNTS="/opt/one:/opt/two" "$top/tools/dev.sh" true
check "dev.sh adds extra mounts" has_line "$STUB_LOG" "/opt/two:/opt/two"

# dev.sh, through the ssh hop: the arguments must survive the remote shell unchanged.
PATH="$work/bin:$PATH" KAMUI_BUILD_HOST=elsewhere "$top/tools/dev.sh" printf '%s|' 'x y' "it's" >/dev/null
check "dev.sh calls ssh with the build host" has_line "$STUB_SSH_LOG" elsewhere
check "dev.sh forwards the build area" grep -q "KAMUI_BUILD_AREA=" "$STUB_SSH_LOG"
check "dev.sh keeps quoting across ssh" has_line "$STUB_LOG" "printf %s| x y it's"

# build-area.sh
mkdir -p "$work/area/build/$checkout" "$work/area/build/gone-worktree" "$work/area/build/main"
touch "$work/area/build/gone-worktree/f"
out="$(KAMUI_BUILD_HOST=local "$top/tools/build-area.sh" status)"
check "status lists build dirs" grep -q "build/gone-worktree" <<< "$out"
check "status prints the budget" grep -q "GB budget" <<< "$out"

KAMUI_BUILD_HOST=local "$top/tools/build-area.sh" prune >/dev/null
check "prune removes builds of missing worktrees" test ! -e "$work/area/build/gone-worktree"
check "prune keeps main" test -d "$work/area/build/main"

mkdir -p "$work/area/build/busy"
if STUB_PS="kamui-isa-$USER-busy-42" KAMUI_BUILD_HOST=local "$top/tools/build-area.sh" clean busy >/dev/null 2>&1; then
  refused=no
else
  refused=yes
fi
check "clean refuses while a container runs" test "$refused" = yes
check "clean kept the busy build" test -d "$work/area/build/busy"

KAMUI_BUILD_HOST=local "$top/tools/build-area.sh" clean busy >/dev/null
check "clean removes a build" test ! -e "$work/area/build/busy"

if KAMUI_BUILD_HOST=local "$top/tools/build-area.sh" clean ../etc >/dev/null 2>&1; then bad=accepted; else bad=rejected; fi
check "clean rejects path names" test "$bad" = rejected

rm -rf "$work"
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
