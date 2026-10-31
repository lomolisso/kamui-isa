# tools/

| Script | Purpose |
|---|---|
| `dev.sh` | Run a command or a shell in the dev container on the build host (works in worktrees; does the ssh hop itself) |
| `build-area.sh` | Show and clean the build area `/scratch/$USER/kamui-isa` on the build host (`status`, `clean`, `prune`, `ps`, `stop`) |
| `tests/run.sh` | Tests for the two scripts above (stub `docker` and `ssh`, no build host needed) |

Both scripts are described in [docs/development.md](../docs/development.md). Python code targets Python 3.12 (the
dev container venv). Every script has a `--help` or a usage comment at the top.
