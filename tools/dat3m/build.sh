#!/usr/bin/env bash
# Build the Dartagnan fork in deps/dat3m, which adds the PTX ISA 8.7 model (cat/ptx-v8.7.cat), into build/dat3m/.
# Run in the dev container (it needs Maven, image 0.3 or later):
#
#   tools/dev.sh 'tools/dat3m/build.sh'          # build build/dat3m/dartagnan.jar (and its libs/), skip the tests
#   tools/dev.sh 'tools/dat3m/build.sh test'     # also run the fork's PTX litmus tests (LitmusPTX*)
#
# The sources are copied to build/dat3m/src (the build area on the build host's local disk) and built there, so no
# build output lands in deps/dat3m. Maven keeps its downloads in the build area (keep/m2, see
# docs/development.md). The upstream Dartagnan release in /opt/dat3m (used for the PTX 6.0 and 7.5 models) is not
# touched. To run the jar: DAT3M_HOME=deps/dat3m java -jar build/dat3m/dartagnan.jar <cat file> <test> [options].
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
src="$root/deps/dat3m"
out="$root/build/dat3m"
m2="${KAMUI_BUILD_AREA:?run through tools/dev.sh}/keep/m2"
[ -f "$src/pom.xml" ] || { echo "deps/dat3m is missing: git submodule update --init deps/dat3m" >&2; exit 1; }
rm -rf "$out/src"
mkdir -p "$out/src" "$out/output" "$m2"
tar -C "$src" --exclude=.git --exclude=target -cf - . | tar -C "$out/src" -xf -
# the fork's tests read their configuration, cat files and litmus tests from DAT3M_HOME, which in the image points
# to the upstream release in /opt/dat3m
export DAT3M_HOME="$out/src" DAT3M_OUTPUT="$out/output"
mvn=(mvn -q -B -Dmaven.repo.local="$m2" -Djacoco.skip=true -Dmaven.gitcommitid.skip=true -f "$out/src/pom.xml")
"${mvn[@]}" install -DskipTests
if [ "${1:-}" = test ]; then
  "${mvn[@]}" -pl dartagnan test -Dtest='LitmusPTX*' -Dsurefire.failIfNoSpecifiedTests=false
fi
rm -rf "$out/libs"
cp -r "$out/src/dartagnan/target/libs" "$out/libs"
cp "$out/src/dartagnan/target/dartagnan.jar" "$out/dartagnan.jar"
git -C "$src" rev-parse --short=12 HEAD > "$out/commit"
[ -z "$(git -C "$src" status --porcelain)" ] || echo "+dirty" >> "$out/commit"
echo "built $out/dartagnan.jar from deps/dat3m $(tr '\n' ' ' < "$out/commit")"
