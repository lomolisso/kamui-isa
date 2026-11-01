# jobs/

Job scripts for the H100 server. Only work that needs the GPU goes here: golden outputs, NVBit traces,
`compute-sanitizer`, `ncu`, litmus sanity runs. Everything else (clang to PTX, `ptxas -v`, SASS dumps) runs in
the dev container. The full workflow, the job image and how results come back are in
[docs/tools/h100-jobs.md](../docs/tools/h100-jobs.md).

| Script | What it does | Results go to |
|---|---|---|
| `env-probe.sh` | Records the driver, toolkit and library versions; checks that the driver JIT accepts our PTX 8.7, and that NVBit, `compute-sanitizer` and `ncu` work in the job container | `evidence/env/` |
| `goldens.sh` | Runs every corpus entry on the GPU (3 runs plus a poisoned run, compute-sanitizer, the JIT cubin dump) and writes the golden outputs | `tests/goldens/`, `evidence/jit-comparison.tsv` |

## Rules for a job script

- Self-contained and non-interactive. It runs from the repository root of a clean checkout of a committed
  revision, and reads only committed files (PTX, descriptors, seeded generators).
- It writes only under `$OUT` (default `$HOME/kamui-jobs/<job>/<JOB_ID>/`) and ends with `manifest.yaml`, which
  records the git commit, the GPU (name, UUID, driver) and the result of each step.
- `REPO`, `OUT` and `JOB_ID` can be set from the environment, so the script also runs by hand.
- Never write SASS or per-instruction traces of NVIDIA library kernels into the results; aggregate them first.
