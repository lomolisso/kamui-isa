# Development environment

## Machines

| Machine | What runs there | Disk |
|---|---|---|
| **iacoma227** | editing files and git | NFS home only. Its local `/scratch` is almost full with other users' data. |
| **iacoma231** (build host) | every compile, image build, container, test and check, through `tools/dev.sh` | a large local `/scratch` (about 1 TB free in October 2026), the same disk as its `/srv/docker` |
| **H100 host** | only work that needs the GPU (see `tools/h100-jobs.md`) | its own disks; it does **not** share the NFS home |

The NFS home, and so your checkout, is the same path on iacoma227, iacoma231 and iacoma232. A file you edit on 227
is the file the container on 231 compiles. Local `/scratch` is different on every machine: a build made on 231
does not exist on 227.

Nothing heavy runs on iacoma227: no `docker run`, no `docker build`, no `cmake`, no test runs. Even a quick check
goes through `tools/dev.sh`, which costs about one second for the ssh hop.

iacoma231 and iacoma232 both have 96 cores and about 375 GB of RAM. They are shared with other users and reached
by passwordless ssh. The home directory is shared, so one key in `~/.ssh/authorized_keys` works on all of them:

```bash
ssh-keygen -t ed25519                                    # once, if you have no key
cat ~/.ssh/id_ed25519.pub >> ~/.ssh/authorized_keys
ssh -o BatchMode=yes iacoma231 docker image ls kamui-isa-dev   # must work without a password
```

You need to be in the `docker` group on iacoma231; ask the maintainers. 231 is the default build host. Use 232 only
when 231 is very loaded, and only after copying the image there (see "The image on another host").

## The dev container

The Docker image `kamui-isa-dev` holds every tool the project needs (clang 20, the CUDA toolkit without a driver,
the RISC-V toolchain, Spike, Sail, herdtools7, Alloy, Dartagnan, CMake, Python). How to build it, the pinned
versions, and the list of tools are in `tools/devcontainer.md`.

## The build area

Each user has one build area per repository on the build host:

```text
/scratch/$USER/kamui-isa/
  build/main/        build/ of the main checkout
  build/<name>/      build/ of the worktree .worktrees/<name>
  keep/<item>/       persistent, rebuildable items listed in the registry below
```

`tools/dev.sh` mounts `build/<checkout>` over the checkout's `build/` directory inside the container. So every
path like `build/sail-riscv` works unchanged, and the bytes land on 231's local disk, which is much faster than NFS
for builds with many small files (a Sail build takes 12.5 minutes there against 18 minutes on NFS).

On iacoma227, `build/` in the checkout is an empty directory (only the mount point). To read a build output from
227:

```bash
tools/dev.sh 'cat build/sail-riscv/config/rv64d_v512_e64.json'                       # through the container
ssh iacoma231 cat /scratch/$USER/kamui-isa/build/main/sail-riscv/config/rv64d_v512_e64.json   # or directly
```

Results that must survive go in committed files, never only in `build/`.

## tools/dev.sh

```bash
tools/dev.sh                                  # interactive shell in the container, same directory
tools/dev.sh 'cmake --version'                # one command
```

On any machine other than the build host it runs itself again on the build host with
`ssh -o BatchMode=yes iacoma231`, in the same directory. On the build host it starts `docker run --rm --init` with:

| Mount or option | Why |
|---|---|
| the main repository root at its own path | git works in worktrees |
| `/scratch/$USER/kamui-isa` at its own path | `keep/` items are reachable |
| `/scratch/$USER/kamui-isa/build/<checkout>` over `<checkout>/build` | build outputs go to local disk |
| each path in `KAMUI_EXTRA_MOUNTS` (colon-separated) at its own path | extra inputs outside the repository |
| `--name kamui-isa-$USER-<checkout>-<pid>` | your containers are easy to find and stop |
| `--memory 128g` | a runaway build cannot starve other users |

Environment variables: `KAMUI_BUILD_HOST` (default `iacoma231`; `local` runs on the current machine and is meant for
CI), `KAMUI_BUILD_AREA` (default `/scratch/$USER/kamui-isa`), `KAMUI_DEV_IMAGE` (default `kamui-isa-dev:0.2`),
`KAMUI_DEV_MEMORY` (default `128g`), `KAMUI_EXTRA_MOUNTS`.

Long runs: start them in the background and wait. Killing the local ssh client does not always stop the container
on 231; `tools/build-area.sh ps` lists yours and `tools/build-area.sh stop <name>` stops one.

## tools/build-area.sh

| Command | What it does |
|---|---|
| `tools/build-area.sh status` | size of each `build/*` and `keep/*`, total against the 50 GB budget, free disk, load of 231 and 232, your running containers; prints a WARNING when over budget or under 100 GB free |
| `tools/build-area.sh clean [<name>]` | deletes `build/<name>`; without a name, the checkout the script is called from |
| `tools/build-area.sh prune` | deletes `build/<name>` for every worktree that no longer exists |
| `tools/build-area.sh ps` / `stop [<container>]` | lists or stops your dev containers |

It also runs itself on the build host. It refuses to clean a checkout whose container is still running.

## Cleanup policy

Scratch is fast because it is local, and it is shared by everyone on the machine. We use it and give it back.

1. **Everything is throwaway by default.** Every build output goes under `build/`.
2. **Delete a build when it has served its purpose:** once the checks pass and the results are committed, run
   `tools/build-area.sh clean`. A failing build that you are still debugging may stay until it is fixed.
3. **Removing a worktree starts with `tools/build-area.sh clean <name>`.** `tools/build-area.sh prune` catches
   anything left behind.
4. **`keep/` holds only items listed in the registry below.** Add the registry row in the same change that starts
   using an item. When a new version replaces an item, delete the old one in the same step.
5. **Limits.** Keep `/scratch/$USER/kamui-isa` under 50 GB. Keep at least 100 GB free on 231's `/scratch` (the disk
   is shared with Docker's `/srv`); if a run would go below that, stop and ask the maintainers. Never touch another
   user's folder. Never run `docker system prune`, `docker image prune` or `docker builder prune` on these shared
   machines; remove only your own images and containers, by name.

## Registry of persistent items

Persistent means "kept because rebuilding is slow", never "cannot be rebuilt". Every item has a rebuild command.

| Item | Where | Size | Rebuild time | Rebuild |
|---|---|---|---|---|
| `kamui-isa-dev:0.2` (only the current tag) | Docker on iacoma231 (`/srv/docker`) | 16 GB | about 35 min | `docker build` on 231, see `tools/devcontainer.md` |

`keep/` is empty today. The Sail model build of `main` (about 12 minutes to rebuild) is expected to be the first
entry once the Kamui Sail model exists.

## The image on another host

Images do not move with the NFS home. Copy one by streaming it, with no temporary file:

```bash
docker save kamui-isa-dev:0.2 | ssh iacoma232 docker load              # run on the host that has it
ssh iacoma232 docker image inspect kamui-isa-dev:0.2 --format '{{.Id}}'  # must match the source
```

## H100 results

The H100 host does not share the NFS home. Job results are copied back over ssh into the committed paths where they
belong. Large raw outputs that only feed an analysis go to the build area on 231, not to NFS.
