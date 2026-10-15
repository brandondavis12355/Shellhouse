---
name: shell-and-files
description: >-
  When you need to run commands, install software, or read, write, move or
  delete files in your Linux sandbox, or need a password, API key or token:
  asking your user for one securely, or using a stored one in a command.
---
# Shell and files

Your sandbox is your own Debian machine: user `box`, home `/home/box`, work
in `/workspace`. `/workspace` is a persistent volume, so what you save there
is still there next time. Your user can see it too.

## Files: prefer the file tools
None of these need approval; shell commands do. Use them whenever they can
do the job. Paths are relative to `/workspace`.
- `list_files(path)`: what's in one folder.
- `find_files(pattern, path)`: files whose name matches a glob, e.g.
  `"*.csv"`.
- `search_files(pattern, path, file_glob)`: lines matching a regular
  expression, as `file:line: text`. Too many matches? Narrow the pattern,
  path or `file_glob`.
- `read_file(path, offset, limit)`: one page (about 12,000 characters) at a
  time. When it returns `next_offset`, there is more: read on from there.
  If it errors, list the parent folder before guessing again.
- `edit_file(path, old_text, new_text)`: change part of a file. Read the
  file first. Copy `old_text` exactly from it, with a few surrounding lines
  so it matches once. The reply shows a numbered snippet of the result:
  check it.
- `write_file(path, content)`: create a file, or replace one completely.
  Don't use it to change a few lines of a big file; use `edit_file`.
- `.py`, `.json`, `.sh` and `.yaml` files are syntax-checked on every write
  and edit. A change that would break a file that parsed before is refused
  and the file is left unchanged: fix the change, don't resubmit it.

## run_shell
- Returns `exit_code`, `stdout` and `stderr`. Read the output, not just the
  exit code: `a; b` can exit 0 even though `a` failed.
- One simple command per call works best. Use absolute paths, and
  `| head -50` or `| tail -50` for long output. Output too long to show is
  saved in full: the reply gives `full_stdout_path`, which you can page
  through with `read_file` or search with `search_files`.
- `timeout` is in seconds (default 120). For anything slower (builds,
  installs, servers, long downloads) use `background: true`: you get a
  `job_id` at once. Then `check_job(job_id, wait_seconds: 110)` waits for
  it to finish (call again if it's still running) and shows its exit code
  and last lines of output; `stop_job` stops it. Don't poll with `sleep`. A
  command that times out in the foreground may still be running, but its
  output is lost.
- To check whether a program exists: `command -v <name>`.
- Already installed (check with `command -v` before installing anything):
  - languages: Python 3 (pip, venv; requests, beautifulsoup4, pandas,
    openpyxl), Node.js and npm, gcc/make (`build-essential`), pkg-config;
  - code and remote: git, gh, ssh, scp, rsync, gpg;
  - files: rg (ripgrep), fd, tree, file, less, nano, vim, sqlite3,
    pdftotext, bc, patch;
  - archives: zip, unzip, xz, bzip2, zstd, 7z;
  - network and processes: curl, wget, jq, ping, dig, nc, ip,
    traceroute, lsof, htop, tmux;
  - desktop: Chromium, ImageMagick, xdotool.
- `sudo` only works if your user has enabled it for sandboxes, and every
  `sudo` command needs a strict approval. It's blocked entirely once the
  run is untrusted, so do anything needing root first. Test once with
  `sudo -n true`. If that fails, don't keep trying: install without root
  instead (`python3 -m venv /workspace/.venv` then its `pip`, or
  `npm install` inside a project folder), or tell your user what you need.
- With sudo: `sudo apt-get update` first, then `sudo apt-get install -y
  <pkg>`. Packages from Debian's own repositories don't make the run
  untrusted; downloads from the internet (curl, wget, git clone, pip, npm)
  do.

## Approvals for shell
- Every `run_shell` call needs your user's approval by default. They see
  the exact command.
- Your user can allow a specific program, or all shell commands for you.
  Those standing grants never cover chained commands, interpreters (python,
  bash -c, …) or commands that use secrets, which always ask.
- Commands that use a secret need a strict approval, and are blocked once
  the run is untrusted (after browsing or downloading). Run them early.
- Write commands your user can understand at a glance. A clear, single
  command gets approved quickly; a long chain of `&&` gets questioned.
- If a command is denied, don't resubmit it reworded. Ask what they'd
  prefer, or find another way.

## Secrets
- Secrets live in the Mac's Keychain under names like `GITHUB_TOKEN`
  (capital letters, digits and `_`). You never see their values.
- **Need a password, key or token you don't have? Call
  `request_credentials(reason, fields)`**. Never ask for one in chat text.
  It opens a secure form in your 1:1 chat and waits. Each field has a
  `name` (`SITE_PASSWORD`), a `label` your user reads, and `secret`
  (true by default; false for a username, which then comes back to you as
  plain text). The result lists the secret names you can now use. If it
  says `cancelled`, don't ask again; tell your user what's blocked.
- Name things clearly and reuse names: if a secret is already saved, your
  user can keep it without retyping.
- **Need to sign in somewhere? Call `request_login(service, reason, site)`**
  instead: a sign-in card with Username and Password, saved as
  `<SERVICE>_USERNAME` and `<SERVICE>_PASSWORD` (e.g. `JIRA_PASSWORD`).
  The username comes back to you; the password never does. Give the real
  sign-in domain as `site` so your user can check it.
- Use one with `run_shell(command, use_secrets: ["GITHUB_TOKEN"])`. It's
  available to that one command as the environment variable
  `$GITHUB_TOKEN`.
- The value never appears in your context: it's masked in the output.
  Never try to print it, write it to a file, or put it in a URL you show.
- A name that doesn't exist is simply not set. If `$NAME` comes out empty,
  the name is wrong. Ask, don't guess.
- To enter a password into a login page or app on the desktop, use
  `type_secret` (see the desktop-control skill), never `type_text`.

## Deleting and overwriting
- Before a delete or overwrite inside `/workspace` runs, a copy of the
  affected paths goes to `/workspace/.shellhouse/trash/<timestamp>/`. If you or
  your user made a mistake, restore from there.
- Don't delete or edit `/workspace/.shellhouse/` itself; it's the app's own
  folder.

## Limits that stop a run
A run is frozen if it goes over 400 shell commands, 90 tool calls in a
minute, 64 MB written, or 3 blocked or denied actions. Plan the work so you
don't need brute force: look before you act, and change approach after a
failure instead of retrying.

## Never touch
Credential-looking files you didn't create (SSH keys, cloud credential
files, token files in your home folder). Some are decoys: touching one
freezes the run and alerts your user.
