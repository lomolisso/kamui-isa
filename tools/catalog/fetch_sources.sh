#!/usr/bin/env bash
# Download the inputs of the catalog scripts: the PTX ISA 8.7 manual (single-page HTML) and a sparse, shallow
# clone of the LLVM 20.1.8 NVPTX back end. Idempotent: existing copies are kept.
#
#   tools/catalog/fetch_sources.sh                  # into $KAMUI_SOURCES, default build/catalog/sources
#
# Run it in the dev container (tools/dev.sh), so the files land in the build area of the build host. The
# manual is NVIDIA's and is never committed; cite it by section number.
set -euo pipefail

top="$(cd "$(dirname "$0")/../.." && pwd)"
dest="${KAMUI_SOURCES:-$top/build/catalog/sources}"
manual_url="https://docs.nvidia.com/cuda/archive/12.8.1/parallel-thread-execution/index.html"
llvm_url="https://github.com/llvm/llvm-project.git"
llvm_tag="llvmorg-20.1.8"

mkdir -p "$dest/specs"

if [ -s "$dest/specs/ptx_isa_8.7.html" ]; then
  echo "manual: $dest/specs/ptx_isa_8.7.html (kept)"
else
  curl -fsSL --retry 3 -o "$dest/specs/ptx_isa_8.7.html.part" "$manual_url"
  mv "$dest/specs/ptx_isa_8.7.html.part" "$dest/specs/ptx_isa_8.7.html"
  echo "manual: downloaded $dest/specs/ptx_isa_8.7.html"
fi

llvm="$dest/llvm-20.1.8"
if [ -d "$llvm/llvm/lib/Target/NVPTX" ]; then
  echo "llvm: $llvm (kept)"
else
  rm -rf "$llvm"
  git -c advice.detachedHead=false clone --depth 1 --branch "$llvm_tag" --filter=blob:none --sparse --no-recurse-submodules \
    "$llvm_url" "$llvm"
  git -C "$llvm" sparse-checkout set llvm/include/llvm llvm/lib/Target/NVPTX
  echo "llvm: cloned $llvm_tag into $llvm"
fi
