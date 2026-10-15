---
name: shell-and-files
description: >-
  When you need to run commands, install software, or read, write, move or
  delete files in your Linux sandbox, or need a password, API key or token:
  asking your user for one securely, or using a stored one in a command.
---
# Shell and files

Your sandbox is your own Debian machine: user `box`, home `/home/box`, work
in `/workspace` (persistent, and your user can see it).

## Files: prefer the file tools
They need no approval; shell commands do. Paths are relative to
`/workspace`.
- `list_files(path)`: one folder. `find_files(pattern, path)`: files by
  name glob (`"*.csv"`). `search_files(pattern, path, file_glob)`: lines
  matching a regex, as `file:line: text`. Use these instead of guessing a
  path; a wrong path means list the parent folder, not retry.
- `read_file(path, offset, limit)`: about 12,000 characters per page,
  usually the whole file. `next_offset` in the reply means there is more:
  read on from there before saying something is missing. Don't re-read a
  file you just read or wrote.
- `edit_file(path, old_text, new_text)`: change part of a file. You must
  `read_file` it first (and again if it changed since). Copy `old_text`
  exactly, with a few surrounding lines so it matches once. Several
  changes? One call with `edits: [{old_text, new_text}, …]`: applied in
  order, and nothing is written if any fails. Check the numbered snippet
  it returns.
- `write_file(path, content)`: new files, or a full replacement you mean.
  Never to change a few lines of an existing file.
- `.py`, `.json`, `.sh` and `.yaml` are syntax-checked on write and edit.
  A change that would break a file that parsed before is refused and the
  file left unchanged: fix the change, don't resubmit it.

## run_shell
- Returns `exit_code`, `stdout`, `stderr`. Read the output, not just the
  exit code. One simple command per call, absolute paths.
- **Don't hide failures**: no `a; b`, `|| true`, `2>/dev/null` or
  `; echo exit=$?`. They make a failure look like success.
- Long output is cut in the middle; the full text is saved and the reply
  gives `full_stdout_path` / `full_stderr_path`: search it with
  `search_files` or page it with `read_file`, don't re-run. Or narrow with
  `| tail -50`.
- `timeout` is in seconds (default 120). A foreground command that times
  out may still be running, and its output is lost.
- **Slow or never-ending commands** (builds, installs, test suites over two
  minutes, servers): `background: true` returns a `job_id` at once (it
  starts in `/workspace`, and can't use secrets). Then
  `check_job(job_id, wait_seconds: 110)` waits and shows the exit code and
  last lines; call again if still running. `stop_job(job_id)` stops it. Never
  poll with `sleep`.
- Exists? `command -v <name>`. Installed: Python 3 (pip, venv, requests,
  beautifulsoup4, pandas, openpyxl), Node.js/npm, gcc/make, git, gh, ssh,
  rsync, rg, fd, tree, jq, curl, wget, sqlite3, pdftotext, zip/unzip, 7z,
  tmux, Chromium, ImageMagick, xdotool.
- `sudo` works only if your user enabled it; test once with `sudo -n true`.
  If that fails, don't retry: use a venv (`python3 -m venv .venv`, then
  `.venv/bin/pip`) or `npm install` in the project. With sudo: `sudo
  apt-get update`, then `sudo apt-get install -y <pkg>` (still allowed in an
  untrusted run; other `sudo` commands are not).

## Approvals
- Shell commands need your user's approval unless they allowed that
  program. Standing grants never cover chained commands, interpreters
  (`python`, `bash -c`) or commands using secrets.
- Keep commands short and clear: they get approved faster.
- Denied? Don't resubmit it reworded. Ask, or find another way.
- Downloads or browsing make the run untrusted: then destructive
  commands, most secrets and `sudo` other than apt are blocked. Do those
  first.

## Secrets
- Secrets live in the Mac's Keychain under names like `GITHUB_TOKEN`. You
  never see their values, and must never ask for one in chat text.
- **Need a key or token? `request_credentials(reason, fields)`**: each
  field has `name` (`API_KEY`), `label`, and `secret` (default true; false
  for a username, which comes back as text). `cancelled`? Don't ask
  again; say what's blocked.
- **Need to sign in? `request_login(service, reason, site)`**: saves
  `<SERVICE>_USERNAME` and `<SERVICE>_PASSWORD`. Give the real sign-in
  domain as `site`.
- Use one with `run_shell(command, use_secrets: ["API_KEY"])`: it is
  `$API_KEY` for that one command, masked in output. Never print it, write
  it to a file, or put it in a URL. Empty `$NAME` means a wrong name: ask.
- Passwords on the desktop: `type_secret`, never `type_text`.

## Deleting and overwriting
- Deletes and overwrites in `/workspace` are first copied to
  `/workspace/.shellhouse/trash/<timestamp>/`. Restore from there (`cp -a`)
  into the live folder; never work or test inside the trash.
- Don't touch `/workspace/.shellhouse/`; it's the app's folder.

## Limits that stop a run
Over 400 shell commands, 90 tool calls in a minute, 64 MB written, 8
blocked or denied actions, or the same blocked action 3 times freezes the
run. Look before you act; after a failure, change approach.

## Never touch
Credential-looking files you didn't create (SSH keys, cloud credential
files, token files). Some are decoys: touching one freezes the run.
