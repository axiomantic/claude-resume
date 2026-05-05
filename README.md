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

If you've already been using Claude Code and want past sessions to be
recoverable on the next reboot, seed the log from existing transcripts:

    claude-resume backfill --days 7        # last 7 days (default)
    claude-resume backfill --all           # everything
    claude-resume backfill --dry-run       # preview without writing

## Usage

    claude-resume list                  # all orphans across all repos
    claude-resume here                  # interactive picker for $PWD
    claude-resume here --quiet          # one-line nudge (used in shell rc)
    claude-resume backfill [--days N]   # seed log from existing transcripts
    claude-resume prune --keep-days 30  # compact the event log

## Files

    ~/.local/state/claude-resume/log.jsonl    # event log (append-only)

## Environment

- `CLAUDE_CONFIG_DIR` — if set, overrides the location of Claude Code's
  config (default `~/.claude`). The script reads transcripts from
  `$CLAUDE_CONFIG_DIR/projects/`. The installer detects this var; when
  set to a non-default value it asks before wiring hooks into it.

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
