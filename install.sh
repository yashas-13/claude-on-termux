#!/data/data/com.termux/files/usr/bin/bash
# claude-on-termux — idempotent installer/updater for Claude Code on Termux (Android aarch64)
# Usage:
#   bash install.sh            # install or update
#   bash install.sh --dry-run  # print what would change, change nothing
#   bash install.sh --force    # reinstall even if latest already present
set -euo pipefail

DRY_RUN=0
FORCE=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --force) FORCE=1 ;;
    *) echo "unknown arg: $arg" >&2; exit 64 ;;
  esac
done

say()  { printf '\033[1;34m[claude-on-termux]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[fatal]\033[0m %s\n' "$*" >&2; exit 1; }

PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
HOME_DIR="${HOME:-/data/data/com.termux/files/home}"
LOCAL_BIN="$HOME_DIR/.local/bin"
GCC_PKG="attr-glibc/glibc"        # provides ld-linux-aarch64.so.1
LDSO="$PREFIX/glibc/lib/ld-linux-aarch64.so.1"
GREP_BIN=grep                     # glibc grep not needed; bionic fine here

# ── Termux checks ───────────────────────────────────────────────
[ -d "$PREFIX" ] || die "not a Termux prefix ($PREFIX)"
ARCH="$(uname -m)"
[ "$ARCH" = "aarch64" ] || [ "$ARCH" = "arm64" ] || die "unsupported arch: $ARCH (need aarch64)"
command -v node >/dev/null || die "node not found — run: pkg install nodejs"
command -v npm  >/dev/null || die "npm not found — run: pkg install nodejs"
command -v uname >/dev/null || die "uname missing"

# ── glibc loader (required by Claude's native ELF) ──────────────
if [ ! -x "$LDSO" ]; then
  warn "glibc loader missing at $LDSO — installing $GCC_PKG"
  if [ "$DRY_RUN" -eq 1 ]; then
    say "(dry-run) would run: pkg install -y $GCC_PKG"
  else
    command -v pkg >/dev/null || die "pkg not found"
    pkg install -y "$GCC_PKG" || die "failed to install $GCC_PKG"
  fi
fi

# ── VERSION parse ───────────────────────────────────────────────
CURRENT=""
if command -v claude >/dev/null 2>&1; then
  CURRENT="$(claude --version 2>/dev/null | awk '{print $1}' || true)"
fi
LATEST="$(npm view @anthropic-ai/claude-code version 2>/dev/null || true)"
say "current=$CURRENT  latest=$LATEST"
if [ -n "$LATEST" ] && [ "$CURRENT" = "$LATEST" ] && [ "$FORCE" -eq 0 ]; then
  say "already at latest ($LATEST). use --force to reinstall."
  [ "$DRY_RUN" -eq 1 ] && say "(dry-run would stop here, nothing to do)"
  exit 0
fi

# ── npm install (global, keep optional deps, run postinstall) ──
if [ "$DRY_RUN" -eq 1 ]; then
  say "(dry-run) npm install -g @anthropic-ai/claude-code"
else
  say "installing @anthropic-ai/claude-code → $PREFIX"
  # TMPDIR workaround: npm sometimes chokes on Android temp paths
  export TMPDIR="${TMPDIR:-$PREFIX/tmp}"
  npm install -g @anthropic-ai/claude-code
fi

# ── resolve native binary ──────────────────────────────────────
PKG_DIR="$PREFIX/lib/node_modules/@anthropic-ai/claude-code"
NATIVE_SRC="$PKG_DIR/node_modules/@anthropic-ai/claude-code-linux-arm64/claude"
if [ -x "$NATIVE_SRC" ]; then
  :
elif [ -x "$PKG_DIR/bin/claude.exe" ]; then
  NATIVE_SRC="$PKG_DIR/bin/claude.exe"
else
  die "native binary not found under $PKG_DIR — reinstall without --ignore-scripts/--omit=optional"
fi
say "native binary: $NATIVE_SRC"

# ── shim ───────────────────────────────────────────────────────
mkdir -p "$LOCAL_BIN"
SHIM="$LOCAL_BIN/claude"
shim_body=$(cat <<SH
#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail
PREFIX="\${PREFIX:-/data/data/com.termux/files/usr}"
LDSO="\$PREFIX/glibc/lib/ld-linux-aarch64.so.1"
LIBPATH="\$PREFIX/glibc/lib"
CANDIDATES=(
  "\$PREFIX/lib/node_modules/@anthropic-ai/claude-code/bin/claude.exe"
  "\$PREFIX/lib/node_modules/@anthropic-ai/claude-code/node_modules/@anthropic-ai/claude-code-linux-arm64/claude"
)
BIN=""
for c in "\${CANDIDATES[@]}"; do [ -x "\$c" ] && { BIN="\$c"; break; }; done
if [ -z "\$BIN" ]; then echo "claude: native binary not found. Run: bash install.sh" >&2; exit 1; fi
if [ -d "\$PREFIX/tmp" ]; then
  export TMPDIR="\${TMPDIR:-\$PREFIX/tmp}"
  export CLAUDE_CODE_TMPDIR="\${CLAUDE_CODE_TMPDIR:-\$TMPDIR}"
fi
unset LD_PRELOAD 2>/dev/null || true
if [ -x "\$LDSO" ]; then
  exec "\$LDSO" --library-path "\$LIBPATH" "\$BIN" "\$@"
else
  exec "\$BIN" "\$@"
fi
SH
)
if [ "$DRY_RUN" -eq 1 ]; then
  say "(dry-run) write shim → $SHIM"
else
  printf '%s\n' "$shim_body" > "$SHIM"
  chmod 755 "$SHIM"
  # PATH guard (idempotent)
  case ":$PATH:" in
    *":$LOCAL_BIN:"*) ;;
    *) export PATH="$LOCAL_BIN:$PATH" ;;
  esac
  say "shim → $SHIM (chmod 755)"
fi

# ── .bashrc patch (idempotent block) ───────────────────────────
BASHRC="$HOME_DIR/.bashrc"
block_marker="claude-code-termux-tmpdir"
if [ -f "$BASHRC" ] && "$GREP_BIN" -q "$block_marker" "$BASHRC" 2>/dev/null; then
  say ".bashrc already patched (marker: $block_marker)"
else
  if [ "$DRY_RUN" -eq 1 ]; then
    say "(dry-run) append TMPDIR+PATH block to $BASHRC"
  else
    printf '%s\n' '' \
      '# >>> claude-code-termux-tmpdir >>>' \
      '# Keep interactive shells aligned with the Termux TMPDIR workaround.' \
      'if [ -n "${PREFIX:-}" ] && [ -d "$PREFIX/tmp" ]; then' \
      '    export TMPDIR="${TMPDIR:-$PREFIX/tmp}"' \
      '    export CLAUDE_CODE_TMPDIR="${CLAUDE_CODE_TMPDIR:-$TMPDIR}"' \
      '    export CLAUDE_TMPDIR="${CLAUDE_TMPDIR:-$TMPDIR/claude}"' \
      'fi' \
      '# <<< claude-code-termux-tmpdir <<<' \
      '' \
      '# >>> cc-termux PATH >>>' \
      'case ":$PATH:" in' \
      '    *":$HOME/.local/bin:"*) ;;' \
      '    *) export PATH="$HOME/.local/bin:$PATH" ;;' \
      'esac' \
      '# <<< cc-termux PATH <<<' \
      '' >> "$BASHRC"
    say ".bashrc patched: $BASHRC"
  fi
fi

# ── settings.json (proxy-aware, only if unset/absent) ──────────
SETTINGS_DIR="$HOME_DIR/.claude"
SETTINGS="$SETTINGS_DIR/settings.json"
if [ -f "$SETTINGS" ]; then
  say "settings.json exists — leaving untouched: $SETTINGS"
else
  if [ "$DRY_RUN" -eq 1 ]; then
    say "(dry-run) write default settings.json → $SETTINGS"
  else
    mkdir -p "$SETTINGS_DIR"
    cat > "$SETTINGS" <<'JSON'
{
  "env": {
    "ANTHROPIC_BASE_URL": "http://localhost:20128/v1",
    "ANTHROPIC_API_KEY": "sk_9router",
    "CLAUDE_CODE_DISABLE_UNKNOWN_MODEL_WINDOW_ENFORCEMENT": "1"
  },
  "model": "oc",
  "skipDangerousModePermissionPrompt": true,
  "theme": "auto"
}
JSON
    chmod 600 "$SETTINGS"
    say "default settings.json → $SETTINGS (chmod 600)"
  fi
fi

# ── verify ────────────────────────────────────────────────────
if [ "$DRY_RUN" -eq 0 ]; then
  hash -r
  if command -v claude >/dev/null; then
    say "installed: $(claude --version)"
    say "run:  claude   (interactive)  |  claude -p \"hello\" --model oc   (headless)"
  else
    warn "claude not on PATH yet — open a new shell or: export PATH=\"$LOCAL_BIN:\$PATH\""
  fi
fi
say "done."