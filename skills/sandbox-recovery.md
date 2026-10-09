---
name: sandbox-recovery
description: >-
  When your computer misbehaves: screenshots fail or come back black, the
  browser or an app freezes, windows won't respond, commands hang or time
  out, or the disk is full.
---
# Sandbox recovery

Most problems clear up with a small, targeted fix. Diagnose first, fix one
thing, check, and stop after two failed attempts. Repeated blocked or
failing actions freeze the run.

## First, what's actually wrong?
- `run_shell("echo ok")` works → your computer is up; the problem is one
  app or the desktop.
- `screenshot` errors or comes back black → the display may be restarting.
  The desktop processes restart themselves automatically: wait a few
  seconds (`run_shell("sleep 5")`) and take another screenshot.
- Commands time out → something is hogging the machine. Check with
  `ps aux --sort=-%cpu | head -8`.
- Errors mentioning "No space left" → check `df -h /workspace` and
  `du -sh /workspace/* | sort -h | tail`.

## An app is frozen
1. `list_windows` to see what's open, then try `focus_window` on it.
2. Still stuck: find its process and stop just that one.
   `pgrep -o -x chromium` gives the main browser process id, then
   `kill <id>`.
3. Reopen it: `open_app("browser", url)`, `open_app("terminal")` or
   `open_app("files")`.

Use `kill` with one specific process id. `pkill` and `killall` can take
down many processes; they need a strict approval, and are blocked
entirely in an untrusted run (for example, after browsing).

## A command hangs
- Give long jobs an explicit `timeout`, and don't start interactive
  programs that wait for input (editors, `top`, prompts). Use flags like
  `-y` and `--no-pager` instead.
- To run something long in the background:
  `nohup <cmd> > /workspace/<job>.log 2>&1 &`, then check the log with
  `tail` later.

## Disk full
Delete what you created and don't need: old screenshots, downloads,
build output, `/workspace/.venv` folders you're done with. Never delete
your user's own files to make room. Ask them instead.

## When to stop and ask
If the desktop still won't come back, or nothing responds after two
targeted attempts, stop. Tell your user what you saw and ask them to use
**Reset sandbox → Reset, keep files** in your settings. That restarts your
computer and keeps everything in `/workspace`. Don't suggest "Reset and
wipe files" unless they want to start over; that deletes the workspace.
