#!/usr/bin/env bash
# Build the Dartagnan fork in deps/dat3m, which adds the PTX ISA 8.7 model (cat/ptx-v8.7.cat), into build/dat3m/.
# Run in the dev container (it needs Maven, image 0.3 or later):
#
#   tools/dev.sh 'tools/dat3m/build.sh'          # build dartagnan.jar, skip the tests
#   tools/dev.sh 'tools/dat3m/build.sh test'     # also run the fork's PTX litmus tests (LitmusPTX*)
#
# Maven keeps its downloads in the build area (keep/m2, see docs/development.md), so a rebuild needs no network
# once the cache is filled. The upstream Dartagnan release in /opt/dat3m (used for the PTX 6.0 and 7.5 models) is
# not touched.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
src="$root/deps/dat3m"
out="$root/build/dat3m"
m2="${KAMUI_BUILD_AREA:?run through tools/dev.sh}/keep/m2"
[ -f "$src/pom.xml" ] || { echo "deps/dat3m is missing: git submodule update --init deps/dat3m" >&2; exit 1; }
mkdir -p "$out" "$m2" "$out/output"
# the fork's tests and runs read their configuration and cat files from DAT3M_HOME, which in the image points to the
# upstream release in /opt/dat3m
export DAT3M_HOME="$src" DAT3M_OUTPUT="$out/output"
mvn=(mvn -q -B -Dmaven.repo.local="$m2" -Djacoco.skip=true -f "$src/pom.xml")
if [ "${1:-}" = test ]; then
  "${mvn[@]}" install -DskipTests
  "${mvn[@]}" -pl dartagnan test -Dtest='LitmusPTX*' -Dsurefire.failIfNoSpecifiedTests=false
else
  "${mvn[@]}" install -DskipTests
fi
cp "$src/dartagnan/target/dartagnan.jar" "$out/dartagnan.jar"
git -C "$src" rev-parse --short=12 HEAD > "$out/commit"
echo "built $out/dartagnan.jar from deps/dat3m $(cat "$out/commit")"
