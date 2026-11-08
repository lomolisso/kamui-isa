# Build the Rocq proof of the PTX 8.7 to Kamui lowering out of tree: the sources and the relation library hahn
# (deps/hahn) are copied to $(OUT) and compiled there, so that no build output lands in the checkout. Inside
# tools/dev.sh, build/ is the build area on the build host.
#
#   tools/dev.sh 'make -C proofs/rocq'          # build hahn (once per hahn version) and every file
#   tools/dev.sh 'make -C proofs/rocq checker'  # also the extracted checker, build/rocq/src/checker
#   tools/dev.sh 'make -C proofs/rocq clean'    # remove build/rocq
#
# Needs Rocq 9.2.0 (`rocq` on the PATH; the dev image and CI have it).

ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))/../..)
OUT ?= $(ROOT)/build/rocq
JOBS ?= 4
# hahn is rebuilt only when its sources change (the CI cache keeps $(OUT)/hahn between runs).
HAHN_KEY := $(shell cat $(ROOT)/deps/hahn/_CoqProject $(ROOT)/deps/hahn/*.v 2>/dev/null | sha256sum | cut -c1-16)

.PHONY: all hahn checker clean

all: hahn
	mkdir -p $(OUT)/src
	cp -pr $(ROOT)/proofs/rocq/. $(OUT)/src/
	cd $(OUT)/src && rocq makefile -f _CoqProject -o Makefile.rocq && $(MAKE) -f Makefile.rocq -j$(JOBS)

# The checker extracted from Rocq (extract/Extract.v writes checker_core.ml) with its driver.
checker: all
	cd $(OUT)/src && ocamlopt -w -a -o checker checker_core.mli checker_core.ml extract/driver.ml

hahn: $(OUT)/hahn/.built-$(HAHN_KEY)

$(OUT)/hahn/.built-$(HAHN_KEY):
	@test -f $(ROOT)/deps/hahn/Hahn.v || { echo "deps/hahn is empty: git submodule update --init --depth 1 deps/hahn"; exit 1; }
	rm -rf $(OUT)/hahn && mkdir -p $(OUT)/hahn
	cp -r $(ROOT)/deps/hahn/. $(OUT)/hahn/
	$(MAKE) -C $(OUT)/hahn -j$(JOBS)
	touch $@

clean:
	rm -rf $(OUT)
