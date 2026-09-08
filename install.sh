#!/data/data/com.termux/files/usr/bin/bash
# claude-on-termux — idempotent installer/updater for Claude Code on Termux (Android aarch64)
# Usage:
#   bash install.sh              # install or update
#   bash install.sh --force      # reinstall even if latest already present
#   bash install.sh --dry-run    # print what would change
#   bash install.sh --test       # run self-test (no install), requires prior install
set -euo pipefail

DRY_RUN=0
FORCE=0
TEST_ONLY=0
RETRIES=5
RETRY_DELAY=5
for arg in "$@"; do
  case "$arg" in
    --dry-run)       DRY_RUN=1 ;;
    --force)         FORCE=1 ;;
    --test)          TEST_ONLY=1 ;;
    --retries=*)     RETRIES="${arg#*=}" ;;
    --retry-delay=*) RETRY_DELAY="${arg#*=}" ;;
    *) echo "unknown arg: $arg" >&2; exit 64 ;;
  esac
done

# ── helpers ────────────────────────────────────────────────────
say()  { printf '\033[1;34m[claude-on-termux]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[fatal]\033[0m %s\n' "$*" >&2; exit 1; }

# retry <label> <cmd> [args...]
retry() {
  local label="$1"; shift
  local attempt=1 delay="$RETRY_DELAY" rc
  while true; do
    if "$@" ; then rc=0; break; fi
    rc=$?
    if [ "$attempt" -ge "$RETRIES" ]; then
      die "$label failed after $attempt attempts (last exit=$rc)"
    fi
    warn "$label attempt $attempt/$RETRIES failed (exit=$rc). retrying in ${delay}s..."
    sleep "$delay"
    delay=$(( delay * 2 ))
    attempt=$(( attempt + 1 ))
  done
  return 0
}

assert_file() { [ -f "$1" ] || die "expected file missing: $1"; [ -s "$1" ] || die "expected file empty: $1"; }
assert_exec() { [ -x "$1" ] || die "expected executable missing: $1"; }

# ── paths ──────────────────────────────────────────────────────
PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
HOME_DIR="${HOME:-/data/data/com.termux/files/home}"
LOCAL_BIN="$HOME_DIR/.local/bin"
GCC_PKG="attr-glibc/glibc"
LDSO="$PREFIX/glibc/lib/ld-linux-aarch64.so.1"
GREP_BIN=grep

# ── Termux checks ───────────────────────────────────────────────
[ -d "$PREFIX" ] || die "not a Termux prefix ($PREFIX)"
ARCH="$(uname -m)"
[ "$ARCH" = "aarch64" ] || [ "$ARCH" = "arm64" ] || die "unsupported arch: $ARCH (need aarch64)"
command -v node >/dev/null || die "node not found — run: pkg install nodejs"
command -v npm  >/dev/null || die "npm not found — run: pkg install nodejs"

# ── self-test mode (no install) ────────────────────────────────
if [ "$TEST_ONLY" -eq 1 ]; then
  say "self-test mode"
  assert_exec "$LOCAL_BIN/claude"
  assert_exec "$PREFIX/glibc/lib/ld-linux-aarch64.so.1"
  assert_file  "$HOME_DIR/.bashrc"
  "$GREP_BIN" -q "claude-code-termux-tmpdir" "$HOME_DIR/.bashrc" 2>/dev/null || die ".bashrc not patched"
  assert_file  "$HOME_DIR/.claude/settings.json"
  VER="$(claude --version 2>&1 || true)"
  echo "$VER" | grep -q "Claude Code" || die "claude --version failed: $VER"
  say "version: $VER"
  OUT="$(timeout 60 claude -p "Reply exactly: SELFTEST_OK" 2>&1 || true)"
  echo "$OUT" | grep -q "SELFTEST_OK" || die "headless prompt failed:\n$OUT"
  say "self-test passed ✓"
  exit 0
fi

# ── glibc loader ──────────────────────────────────────────────
if [ ! -x "$LDSO" ]; then
  warn "glibc loader missing at $LDSO — installing $GCC_PKG"
  if [ "$DRY_RUN" -eq 1 ]; then
    say "(dry-run) would run: pkg install -y $GCC_PKG"
  else
    command -v pkg >/dev/null || die "pkg not found"
    retry "pkg install $GCC_PKG" pkg install -y "$GCC_PKG"
  fi
fi

# ── version check ─────────────────────────────────────────────
CURRENT=""
if command -v claude >/dev/null 2>&1; then
  CURRENT="$(claude --version 2>/dev/null | awk '{print $1}' || true)"
fi
LATEST="$(npm view @anthropic-ai/claude-code version 2>/dev/null || true)"
say "current=$CURRENT  latest=$LATEST"
if [ -n "$LATEST" ] && [ "$CURRENT" = "$LATEST" ] && [ "$FORCE" -eq 0 ]; then
  say "already at latest ($LATEST). use --force to reinstall."
  [ "$DRY_RUN" -eq 1 ] && say "(dry-run would stop here)"
  exit 0
fi

# ── npm install ───────────────────────────────────────────────
if [ "$DRY_RUN" -eq 1 ]; then
  say "(dry-run) npm install -g @anthropic-ai/claude-code"
else
  say "installing @anthropic-ai/claude-code → $PREFIX"
  export TMPDIR="${TMPDIR:-$PREFIX/tmp}"
  retry "npm install -g @anthropic-ai/claude-code" npm install -g @anthropic-ai/claude-code
fi

# ── resolve native binary ─────────────────────────────────────
PKG_DIR="$PREFIX/lib/node_modules/@anthropic-ai/claude-code"
NATIVE_ELF="$PKG_DIR/node_modules/@anthropic-ai/claude-code-linux-arm64/claude"
NATIVE_STUB="$PKG_DIR/bin/claude.exe"
if [ -x "$NATIVE_ELF" ]; then
  NATIVE_SRC="$NATIVE_ELF"
elif [ -x "$NATIVE_STUB" ]; then
  NATIVE_SRC="$NATIVE_STUB"
else
  if [ "$DRY_RUN" -eq 0 ]; then
    warn "native binary missing — running postinstall manually"
    retry "node install.cjs" node "$PKG_DIR/install.cjs"
    if [ -x "$NATIVE_ELF" ]; then
      NATIVE_SRC="$NATIVE_ELF"
    elif [ -x "$NATIVE_STUB" ]; then
      NATIVE_SRC="$NATIVE_STUB"
    else
      die "native binary still missing after postinstall"
    fi
  else
    die "native binary not found under $PKG_DIR"
  fi
fi
say "native binary: $NATIVE_SRC"

# ── shim (native ELF first — the .exe is a Node stub, not ELF) ─
mkdir -p "$LOCAL_BIN"
SHIM="$LOCAL_BIN/claude"
if [ "$DRY_RUN" -eq 1 ]; then
  say "(dry-run) write shim → $SHIM"
else
  cat > "$SHIM" <<'SH'
#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail
PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
LDSO="$PREFIX/glibc/lib/ld-linux-aarch64.so.1"
LIBPATH="$PREFIX/glibc/lib"
# Native ELF first — .exe is a Node stub, not executable directly
CANDIDATES=(
  "$PREFIX/lib/node_modules/@anthropic-ai/claude-code/node_modules/@anthropic-ai/claude-code-linux-arm64/claude"
  "$PREFIX/lib/node_modules/@anthropic-ai/claude-code/bin/claude.exe"
)
BIN=""
for c in "${CANDIDATES[@]}"; do [ -x "$c" ] && { BIN="$c"; break; }; done
if [ -z "$BIN" ]; then echo "claude: native binary not found. Run: bash install.sh" >&2; exit 1; fi
if [ -d "$PREFIX/tmp" ]; then
  export TMPDIR="${TMPDIR:-$PREFIX/tmp}"
  export CLAUDE_CODE_TMPDIR="${CLAUDE_CODE_TMPDIR:-$TMPDIR}"
fi
unset LD_PRELOAD 2>/dev/null || true
if [ -x "$LDSO" ]; then
  exec "$LDSO" --library-path "$LIBPATH" "$BIN" "$@"
else
  exec "$BIN" "$@"
fi
SH
  chmod 755 "$SHIM"
  case ":$PATH:" in
    *":$LOCAL_BIN:"*) ;;
    *) export PATH="$LOCAL_BIN:$PATH" ;;
  esac
  say "shim → $SHIM (chmod 755)"
fi

# ── .bashrc patch (idempotent) ────────────────────────────────
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

# ── settings.json (proxy-aware, only if absent) ────────────────
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

# ── verify (real check — run the binary, not just "which") ─────
if [ "$DRY_RUN" -eq 0 ]; then
  say "verifying installation..."
  hash -r
  OK=0
  if command -v claude >/dev/null && OUT="$(claude --version 2>&1)" && [ -n "$OUT" ]; then
    say "installed: $OUT"
    OK=1
  fi
  if [ "$OK" -eq 0 ]; then
    warn "shim verification failed — trying native ELF directly"
    if [ -x "$NATIVE_ELF" ] && OUT="$("$LDSO" --library-path "$(dirname "$LDSO")" "$NATIVE_ELF" --version 2>&1)" && [ -n "$OUT" ]; then
      say "installed (native direct): $OUT"
    else
      die "could not verify claude installation. manual check: claude --version"
    fi
  fi
fi
say "done."
