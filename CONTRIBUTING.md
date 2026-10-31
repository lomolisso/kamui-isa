# Contributing

## Workflow

1. **One change, one branch, one worktree.** Branches are named `<type>/<topic>`, for example `feat/shfl-sync`:
   ```bash
   git worktree add .worktrees/feat-shfl-sync -b feat/shfl-sync
   git -C .worktrees/feat-shfl-sync submodule update --init
   ```
2. **Build and test through `tools/dev.sh`**, never directly on iacoma227 (see
   [docs/development.md](docs/development.md)).
3. **Push the branch for review:** `git push -u origin feat/shfl-sync`. Review fixes are new commits on the same
   branch; never force-push a branch under review. To undo a commit, use `git revert <sha>`.
4. **Open a pull request** to `main` once the change is approved. CI must pass before it can be merged. Pull
   requests are squash-merged, so the pull request title becomes the commit on `main`.
5. **Clean up** after the merge:
   ```bash
   git -C <main checkout> pull --ff-only
   tools/build-area.sh clean feat-shfl-sync
   git worktree remove .worktrees/feat-shfl-sync
   git branch -D feat/shfl-sync
   ```
   The remote branch is deleted automatically when the pull request is merged.
6. **Undo a merged change** with a pull request that reverts it (`revert: ...`). History on `main` is never
   rewritten.

## Commit messages

[Conventional Commits](https://www.conventionalcommits.org): `type(scope): subject`, imperative, lower case, at most
72 characters, no trailing period. Add a body only when the subject is not enough.

Types: `feat`, `fix`, `docs`, `test`, `refactor`, `perf`, `build`, `ci`, `chore`, `revert`. A breaking change adds
`!` after the type (`feat(spec)!: renumber custom CSRs`).

The pull request title follows the same format, because it becomes the commit message on `main`.

## Changelog

Every `feat` or `fix` pull request (and every breaking change) adds one short line under `## [Unreleased]` in
[CHANGELOG.md](CHANGELOG.md), in the section that fits (`Added`, `Changed`, `Fixed`, `Removed`). CI checks this.

## Releases

A release is a pull request titled `chore(release): vX.Y.Z` that moves the `Unreleased` lines under a new version
heading. After it is merged, tag it and publish the release:

```bash
git tag vX.Y.Z && git push origin vX.Y.Z
gh release create vX.Y.Z --title vX.Y.Z --notes-file <the changelog section>
```

## Writing

- Plain words, short sentences, concrete examples: the repository is read by undergraduate students.
- No em-dash characters (U+2014). CI checks this.
- `docs/` documents the project and the third-party tools it uses.
