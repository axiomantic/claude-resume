# claude-resume

Surface Claude Code sessions that were running when your machine last shut
down, so you can resume them after a reboot.

Built for the case where you juggle many concurrent Claude Code sessions
across many repos, then have to reboot. Claude persists every conversation
in `~/.claude/projects/`, but the mapping of "which terminal tab was driving
which session" is lost. This tool restores that mapping by logging every
session's start and end, then comparing against the system boot time.

## How it works

1. A `SessionStart` hook records `{session_id, cwd, transcript_path}` to an
   append-only log on disk.
2. A `SessionEnd` hook records the close so we know which sessions ended
   cleanly.
3. After a reboot, the tool finds sessions whose last logged event is a
   start (no end), whose transcript file was last modified before the
   current boot (proving the process is gone), and whose mtime is recent
   enough to care about.
4. The transcript file's mtime — updated by Claude on every message —
   doubles as the activity heartbeat, so no background daemon is needed.

There's no PID tracking. PIDs are recycled across boots and even within a
boot, and the boot-time fence makes the question "is this process still
alive?" trivially answerable for anything from before the last boot.

## Install

The script is a single Python file (`claude-resume`) using only the
standard library. Run the included installer to symlink it onto `PATH`,
wire up the Claude Code hooks, and add a shell rc nudge:

    git clone git@github.com:axiomantic/claude-resume.git
    cd claude-resume
    ./install.sh

The installer is idempotent — safe to re-run, and it never touches an
existing hook entry it didn't add.

If you have `CLAUDE_CONFIG_DIR` set to a non-default value, the installer
will detect it and confirm whether to wire hooks into that directory
before proceeding. The `claude-resume` script itself reads from the same
directory at runtime, so backfill, list, and here all stay consistent
with whatever you chose at install time.

If you've already been using Claude Code and want past sessions to be
recoverable on the next reboot, seed the log from existing transcripts:

    claude-resume backfill --days 7        # last 7 days (default)
    claude-resume backfill --all           # everything
    claude-resume backfill --dry-run       # preview without writing

## Usage

    claude-resume list                  # all orphans across all repos
    claude-resume here                  # interactive picker for $PWD
    claude-resume here --quiet          # one-line nudge (used in shell rc)
    claude-resume here --auto           # auto-resume in restored shells
    claude-resume launch                # resume all orphans in Ghostty (macOS)
    claude-resume backfill [--days N]   # seed log from existing transcripts
    claude-resume prune --keep-days 30  # compact the event log

### Auto-resume in restored shells

Ghostty's `window-save-state = always` restores tabs to the working
directories they had at shutdown. With auto-resume enabled, each restored
shell that lands in a cwd with a matching orphan offers to resume it: a
3-second countdown, then `claude --resume <id>` runs in that very shell.
Press any key during the countdown to skip.

To enable, edit the line `install.sh` adds to your `.zshrc`:

    # default (just a nudge):
    claude-resume here --quiet 2>/dev/null

    # auto-resume (replace the line above with this):
    claude-resume here --auto 2>/dev/null

**Auto-resume is bounded to a post-reboot window** — by default the first
30 minutes after boot. Outside that window, `--auto` silently falls
through to `--quiet` behavior (nudge only). This means a fresh shell you
open three days later in a repo with a stale orphan does not trigger a
surprise countdown. Tune with `--auto-window-minutes N`.

Other safeguards:
- The first restored shell in a cwd writes a `claim` event to the log;
  subsequent shells in the same cwd see no orphan and stay quiet.
- Non-TTY stdin (`ssh host zsh -c …`, scripts) suppresses auto-resume.
- `$CLAUDECODE` set (i.e. you're already inside a Claude session)
  suppresses auto-resume so opening a shell from within Claude doesn't
  recurse.

### `launch` (Ghostty, macOS)

After a reboot, `claude-resume launch` resumes every orphan session at once.
Default behavior:

1. Reads the active Ghostty window's terminals via AppleScript.
2. For each orphan, looks for an idle Ghostty tab whose working directory
   matches the orphan's `cwd`. "Idle" is detected heuristically — a tab
   whose title looks like a path or a bare shell name.
3. Idle match found: types `claude --resume <id>` into that tab and
   presses Enter.
4. No match: opens a new tab in the front window with the cwd preset and
   the resume command pre-typed.

Flags:

    --dry-run            Print the plan without doing anything.
    --yes / -y           Skip the confirmation prompt.
    --here               Only orphans whose cwd matches $PWD.
    --all                Ignore CLAUDE_CONFIG_DIR scoping.
    --new-tabs-only      Never inject into existing tabs; always open new.

The injection heuristic is intentionally conservative — if it can't tell
that a tab is idle, it opens a new tab instead. Pass `--new-tabs-only`
if you don't trust the heuristic in your setup.

## Files

    ~/.local/state/claude-resume/log.jsonl    # event log (append-only)

## Environment

- `CLAUDE_CONFIG_DIR` — overrides the location of Claude Code's config
  directory (default `~/.claude`). Both the `claude-resume` script and
  `install.sh` honor it:
  - **`claude-resume`**: reads transcripts from
    `$CLAUDE_CONFIG_DIR/projects/` for `backfill`, and scopes `list` /
    `here` output to entries captured from that config dir. Pass `--all`
    to see every config dir at once.
  - **`install.sh`**: writes hooks into `$CLAUDE_CONFIG_DIR/settings.json`,
    but when the value differs from the default it asks for confirmation
    first — easy to mis-set, easy to wire hooks into the wrong place.

## Multiple Claude config dirs

If you run Claude Code with more than one `CLAUDE_CONFIG_DIR` (e.g. a
personal config and a work config), all events go to a single log at
`~/.local/state/claude-resume/log.jsonl`. There's no risk of corruption
— Claude session IDs are UUIDs, transcript paths are absolute, and each
event records the config dir that captured it.

By default `list` and `here` filter to the currently active config dir,
so you only see orphans relevant to the environment you're in. Use
`--all` to see every session ever captured. Entries written before this
filtering existed have no recorded config dir and are treated as
matching any scope.

## Caveats

- macOS-only as written (uses `sysctl kern.boottime`). Linux port is a
  one-line change to read `/proc/stat`'s `btime`.
- The "active before last boot" rule means sessions force-killed mid-boot
  without a SessionEnd are not offered for restore. Adding that case
  reintroduces ambiguity (was it killed because the user lost interest,
  or because the terminal crashed?). The simpler rule wins.
- Multiple orphans in the same `cwd` are all listed; you pick which to
  resume. With `claude-resume here`, the picker shows the first user
  prompt of each as a hint.
