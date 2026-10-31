# tools/

| Script | Purpose |
|---|---|
| `dev.sh` | Run a command or a shell in the dev container on the build host (works in worktrees; does the ssh hop itself) |
| `build-area.sh` | Show and clean the build area `/scratch/$USER/kamui-isa` on the build host (`status`, `clean`, `prune`, `ps`, `stop`) |
| `tests/run.sh` | Tests for the two scripts above (stub `docker` and `ssh`, no build host needed) |
| `catalog/` | Build and check the PTX feature catalog and generate `spec/ptx-table.md` (see [catalog/README.md](catalog/README.md)) |

Both scripts are described in [docs/development.md](../docs/development.md). Python code targets Python 3.12 (the
dev container venv); its unit tests run with `python -m pytest tools/`. Every script has a `--help` or a usage comment at the top.
