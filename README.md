# claude-on-termux

> **Claude Code native on Termux (Android aarch64) — no root, no dieseling through proot.**

Single-command install that stitches Anthropic's `linux-arm64` Claude Code binary into Termux's glibc environment, fixes `TMPDIR`/`CLAUDE_CODE_TMPDIR` for Android, and wires up a local-proxy (`ANTHROPIC_BASE_URL`) so you can swap models (OpenRouter, 9router, self-hosted).

Fork this, star it, open PRs. Tested on Termux `nodejs 26` + `attr-glibc` on Pixel/OnePlus aarch64.

## Quick start

```bash
curl -fsSL https://raw.githubusercontent.com/yashas-13/claude-on-termux/main/install.sh | bash
# or: bash install.sh
claude              # interactive TUI
claude -p "hello"   # headless / CI
```

If your device runs a model proxy at `http://localhost:20128` (9router, litellm, etc.), the installer auto-detects and configures it. Otherwise Claude authenticates against `api.anthropic.com` via the usual `/login` OAuth flow.

## What the installer does

1. `npm install -g @anthropic-ai/claude-code` (global, `@latest`, no `--omit=optional` — native `claude-code-linux-arm64` is required)
2. Runs `node install.cjs` postinstall (hardlinks/copies `claude.exe` → native `claude`)
3. Drops a glibc-aware shell shim at `~/.local/bin/claude` that executes via `$PREFIX/glibc/lib/ld-linux-aarch64.so.1 --library-path $PREFIX/glibc/lib` (mirrors Termux's own glibc node wrapper), unsets `LD_PRELOAD` (which breaks glibc ELFs), and aligns `TMPDIR`/`CLAUDE_CODE_TMPDIR` to `$PREFIX/tmp` so Claude's sandbox and the shell agree
4. Patches `~/.bashrc` with an idempotent block (`claude-code-termux-tmpdir`) so interactive shells export the same `TMPDIR`/`CLAUDE_CODE_TMPDIR`/`CLAUDE_TMPDIR`
5. Ensures `~/.local/bin` is on `PATH`

Idempotent — run it repeatedly, it will update the binary and rewrite the shim.

## Local proxy / model proxy

The repo ships a ready-to-go `settings.json` for an OpenAI-compatible proxy at `http://localhost:20128/v1`:

```jsonc
// ~/.claude/settings.json
{
  "env": {
    "ANTHROPIC_BASE_URL": "http://localhost:20128/v1",
    "ANTHROPIC_API_KEY": "sk_9router",
    "CLAUDE_CODE_DISABLE_UNKNOWN_MODEL_WINDOW_ENFORCEMENT": "1"
  },
  "model": "oc",
  "skipDangerousModePermissionPrompt": true
}
```

`oc` is a proxy-side alias — map it to whatever upstream model you run behind the proxy (Opus, Sonnet, local OSS models). `CLAUDE_CODE_DISABLE_UNKNOWN_MODEL_WINDOW_ENFORCEMENT=1` is harmless when `oc` isn't in Anthropic's model catalog. Override `ANTHROPIC_BASE_URL`/`ANTHROPIC_API_KEY`/`ANTHROPIC_MODEL` in your shell env to bypass settings.

## Common issues

| Symptom | Fix |
|---|---|
| `claude: cannot execute: required file not found` | Binary needs the glibc loader — run `install.sh` again, or fix `~/.local/bin/claude` shim |
| `Not logged in · Please run /login` (interactive only, `-p` works) | Check `~/.claude.json` `customApiKeyResponses` — move your key from `rejected[]` to `approved[]` |
| `[claude-code:unrecognized_model] {"model":"oc"}` | Cosmetic — `oc` isn't in Anthropic's catalog. The `CLAUDE_CODE_DISABLE_UNKNOWN_MODEL_WINDOW_ENFORCEMENT=1` env silences enforcement; ignore the warning |
| `Error: claude native binary not installed.` | npm was installed with `--ignore-scripts` or `--omit=optional` — reinstall with `npm install -g @anthropic-ai/claude-code` (no flags), then `node $PREFIX/lib/node_modules/@anthropic-ai/claude-code/install.cjs` |

## Files

- `install.sh` — idempotent installer / updater (bash, depends only on Node + npm)
- `bin/claude` — source of the `~/.local/bin/claude` shim (symlink target)
- `.claude/settings.json` — example settings (proxy-aware)
- `.bashrc.patch` — lines appended idempotently to `~/.bashrc` if absent

## Dev

```bash
git clone https://github.com/yashas-13/claude-on-termux.git
bash install.sh --dry-run   # print what would change
bash install.sh             # actually install
claude --version
claude -p "Reply exactly: INSTALL_OK" --model oc
```

PRs welcome — especially device-specific quirks (Bionic vs glibc, `/proc/stat` SELinux, seccomp `lefthook`, etc.).

## License

MIT — see `LICENSE`. Claude Code itself remains Anthropic's proprietary binary distributed via npm; this repo only ships shims and patches.

## Changelog

- **2026-09-08** — initial release (`2.1.263`), glibc shim, proxy profile, reusable installer
