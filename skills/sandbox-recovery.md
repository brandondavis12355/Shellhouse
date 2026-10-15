---
name: sandbox-recovery
description: >-
  When your computer misbehaves: screenshots fail or come back black, the
  browser or an app freezes, windows won't respond, commands hang or time
  out, or the disk is full.
---
# Sandbox recovery

Diagnose first, fix one thing, check it, and stop after two failed
attempts. Repeating a failing or blocked action freezes the run.

## First, what's actually wrong?
- `run_shell("echo ok")` works → the VM is up; the problem is one app or
  the desktop.
- `screenshot` errors or is black → the display may be restarting by
  itself. Wait once (`run_shell("sleep 5")`), then one more screenshot.
- Commands time out → something is hogging the machine:
  `ps aux --sort=-%cpu | head -8`.
- "No space left" → `df -h /workspace`, then
  `du -sh /workspace/* | sort -h | tail`.

## An app is frozen
1. `list_windows` to see what's open, then `focus_window` on it.
2. Still stuck: stop just that process. `pgrep -o -x chromium` gives the
   main browser process id, then `kill <id>`.
3. Reopen it: `open_app("browser", url)`, `open_app("terminal")` or
   `open_app("files")`.

Use `kill` with one process id. `pkill` and `killall` need a strict
approval and are blocked in an untrusted run (for example, after
browsing).

## A command hangs
- Never start interactive programs that wait for input (editors, `top`,
  `less`, prompts). Use `-y`, `--no-pager`, `--yes` style flags.
- Servers and long jobs: `run_shell` with `background: true`, then
  `check_job(job_id, wait_seconds: 110)` for progress and
  `stop_job(job_id)` to stop it. A timed-out foreground command may still
  be running: find it with `ps aux | grep <name>` and `kill <id>`.

## Disk full
Delete only what you created and don't need: old screenshots, downloads,
build output, `.venv` folders you're done with. Never delete your user's
files to make room; ask them.

## When to stop and ask
If the desktop won't come back, or nothing responds after two targeted
attempts, stop: `finish_task` with outcome `blocked`, saying what you saw,
and ask your user to use **Reset sandbox… → Reset, keep files** in your
settings. That restarts the VM and keeps `/workspace`. Don't suggest
"Reset and wipe files" unless they want to start over; it deletes the
workspace.
