#!/usr/bin/env bash
# Idempotent installer for claude-resume.
# - Symlinks the script onto $PATH at ~/.local/bin/claude-resume
# - Adds SessionStart and SessionEnd hooks to ~/.claude/settings.json
#   without disturbing existing hooks (e.g. spellbook-managed ones)
# - Appends a one-line nudge to ~/.zshrc
#
# Safe to re-run.

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$PROJECT_DIR/claude-resume"
BIN="$HOME/.local/bin/claude-resume"
ZSHRC="$HOME/.zshrc"
ZSHRC_MARKER="# claude-resume: auto-resume orphan Claude session in this cwd"
ZSHRC_OLD_MARKER="# claude-resume: nudge if there's an orphan Claude session in this dir"

# Resolve Claude config dir. If CLAUDE_CONFIG_DIR is set and differs from the
# default, confirm with the user before using it — easy to mis-set this and
# write hooks into the wrong place.
DEFAULT_CLAUDE_DIR="$HOME/.claude"
if [ -n "${CLAUDE_CONFIG_DIR:-}" ] && [ "$CLAUDE_CONFIG_DIR" != "$DEFAULT_CLAUDE_DIR" ]; then
  printf "CLAUDE_CONFIG_DIR is set to: %s\n" "$CLAUDE_CONFIG_DIR"
  printf "Default would be:        %s\n" "$DEFAULT_CLAUDE_DIR"
  printf "Install hooks into CLAUDE_CONFIG_DIR? [y/N] "
  read -r reply
  case "$reply" in
    y|Y|yes|YES) CLAUDE_DIR="$CLAUDE_CONFIG_DIR" ;;
    *) CLAUDE_DIR="$DEFAULT_CLAUDE_DIR"
       echo "using default: $CLAUDE_DIR" ;;
  esac
else
  CLAUDE_DIR="$DEFAULT_CLAUDE_DIR"
fi
SETTINGS="$CLAUDE_DIR/settings.json"

if [ ! -x "$SCRIPT" ]; then
  echo "error: $SCRIPT not found or not executable" >&2
  exit 1
fi

# 1. Symlink onto PATH
mkdir -p "$(dirname "$BIN")"
if [ -L "$BIN" ] && [ "$(readlink "$BIN")" = "$SCRIPT" ]; then
  echo "symlink already correct: $BIN"
elif [ -e "$BIN" ]; then
  echo "error: $BIN exists and is not the expected symlink; remove it manually" >&2
  exit 1
else
  ln -s "$SCRIPT" "$BIN"
  echo "linked $BIN -> $SCRIPT"
fi

# 2. Settings.json hooks
python3 - "$SETTINGS" "$BIN" <<'PY'
import json, sys, pathlib

settings_path = pathlib.Path(sys.argv[1])
bin_path = sys.argv[2]
hook_cmd = f"{bin_path} hook"

settings_path.parent.mkdir(parents=True, exist_ok=True)
if settings_path.exists():
    with settings_path.open() as f:
        data = json.load(f)
else:
    data = {}

hooks = data.setdefault("hooks", {})

def has_our_entry(matchers):
    for m in matchers or []:
        for h in m.get("hooks", []):
            if h.get("command") == hook_cmd:
                return True
    return False

def add_entry(event_name):
    matchers = hooks.setdefault(event_name, [])
    if has_our_entry(matchers):
        print(f"  {event_name}: already wired")
        return
    matchers.append({
        "hooks": [
            {"type": "command", "command": hook_cmd, "timeout": 5}
        ]
    })
    print(f"  {event_name}: added")

print(f"updating {settings_path}:")
add_entry("SessionStart")
add_entry("SessionEnd")

with settings_path.open("w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PY

# 3. Zshrc auto-resume hook
if [ -f "$ZSHRC" ] && grep -qF "$ZSHRC_MARKER" "$ZSHRC"; then
  echo "zshrc auto-resume already present"
elif [ -f "$ZSHRC" ] && grep -qF "$ZSHRC_OLD_MARKER" "$ZSHRC"; then
  # Upgrade an old --quiet block to the new --auto block in-place.
  python3 - "$ZSHRC" "$ZSHRC_OLD_MARKER" "$ZSHRC_MARKER" <<'PY'
import sys, pathlib, re
zshrc, old_marker, new_marker = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3]
text = zshrc.read_text()
# Match: blank line + old marker + the if-fi block, replace with new marker block.
pattern = re.compile(
    r"\n?" + re.escape(old_marker) + r"\n"
    r"if command -v claude-resume >/dev/null 2>&1; then\n"
    r"  claude-resume here --quiet 2>/dev/null\n"
    r"fi\n",
    re.MULTILINE,
)
new_block = (
    "\n" + new_marker + "\n"
    "if command -v claude-resume >/dev/null 2>&1; then\n"
    "  claude-resume here --auto\n"
    "fi\n"
)
new_text, n = pattern.subn(new_block, text, count=1)
if n:
    zshrc.write_text(new_text)
    print(f"upgraded {zshrc} (--quiet -> --auto)")
else:
    print(f"warning: old marker found but block did not match expected layout; leaving alone")
PY
else
  cat >>"$ZSHRC" <<EOF

$ZSHRC_MARKER
if command -v claude-resume >/dev/null 2>&1; then
  claude-resume here --auto
fi
EOF
  echo "appended auto-resume hook to $ZSHRC"
fi

echo
echo "Done. Open a new terminal (or source ~/.zshrc) and the wiring is live."
echo "Sessions you start from now on will be tracked."
