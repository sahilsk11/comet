# Comet fork development

## Preserve stable Zeron

- Treat `/Applications/Zeron.app`, bundle id `sh.zeron.app`, `~/.zeron`, and IPC port `27654` as the untouched stable baseline.
- Never replace, re-sign, or launch a worktree build as `Zeron.app`.

## Worktrees get named apps

- For macOS app or UI work in a git worktree, provision that worktree as its own app with `./scripts/provision-dev-app.sh`.
- The default name is derived from the branch. Use `--name "Readable Variant Name"` when the user names a concept, and `--icon /absolute/path/to/icon.png` when it has dedicated artwork.
- Rerun the same command after changes to rebuild the same isolated app. Pass `--no-open` only when visual testing is not yet appropriate.
- Use `--harness hamilton` for a Hamilton-first test app. Do not hand-roll app bundles, reuse Zeron's data directory, or guess alternate ports.
- Each provisioned app must retain its generated bundle id, `~/.zeron-dev/...` data directory, IPC port, callback port, and worktree directory so multiple variants can run concurrently.

## Integration discipline

- Keep experimental implementation on `codex/` branches until checks pass.
- Before merging to `main`, verify the combined branch rather than only the feature branch in isolation.
- Preserve the native Codex session-fork path and the Hamilton harness registration when updating from upstream.
