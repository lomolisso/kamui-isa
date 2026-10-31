# tools/catalog/

Scripts that build and check the PTX feature catalog (`tests/corpus/catalog.yaml`) and generate the PTX side of
`spec/ptx-table.md`. Run them in the dev container from the repository root (`tools/dev.sh '<command>'`).

| Script | Purpose |
|---|---|
| `fetch_sources.sh` | Downloads the PTX ISA 8.7 manual and a sparse clone of the LLVM 20.1.8 NVPTX back end into `$KAMUI_SOURCES` (default `build/catalog/sources`) |
| `toc.py` | Manual to `snapshots/sections.tsv`: every heading, and per instruction section the oldest PTX version, oldest target and syntax tokens |
| `llvm_opcodes.py` | LLVM TableGen records and clang's CUDA headers to `snapshots/llvm-opcodes.tsv`: every opcode clang 20 can print |
| `release_notes.py` | Chapter 12 of the manual to `snapshots/release-notes.tsv`: every feature the release notes name |
| `check_coverage.py` | Checks A (manual), B (`--llvm`), C (`--release-notes`) and the catalog's fields (`--validate`); `--all` runs everything |
| `gen_table.py` | Writes `spec/ptx-table.md`; `--check` fails if it is out of date |
| `coverage-exceptions.yaml` | Accepted mismatches of checks B and C, each with a reason |
| `tests/` | Unit tests (`python -m pytest tools/`) |

The snapshots hold facts only (section numbers and titles, versions, targets, syntax tokens, opcode names), never
text of the manual. To refresh them after a change of the sources or the parsers:

```bash
tools/catalog/fetch_sources.sh
python tools/catalog/toc.py --refresh
python tools/catalog/llvm_opcodes.py --refresh       # runs llvm-tblgen into build/catalog/
python tools/catalog/release_notes.py --refresh
python -m pytest tools/catalog                        # includes a test that the snapshots reproduce
```
