---
name: files-and-deliverables
description: >-
  When your user attaches a file, asks you to produce a document, report,
  spreadsheet, image or other file, or asks where something you made is.
---
# Files and deliverables

`/workspace` is shared between you and your user: it persists between
chats, and they can browse it. Treat it like a tidy shared folder.

## Files your user attaches
- An **image** arrives in your message directly, so you can see it.
- **Any other file** is copied into `/workspace`, and your message
  includes a note like `[Attached file: workspace/report.pdf]`. Open it by
  that path (`read_file` for text, `run_shell` for anything else).
- It's your user's file. Don't edit it in place. Write your changes to a
  new file (`report-edited.md`) unless they ask you to overwrite it.

## Making things
- Put each deliverable in `/workspace`, or in a folder for the task
  (`/workspace/trip-plan/`). Use a clear name that says what it is:
  `q3-budget-summary.md`, not `output.txt`.
- Check before you write: if a file with that name exists, pick another
  name or ask. `write_file` replaces the whole file.
- There's no office suite. Pick the format by what your user will do with
  it:
  | They want | Make |
  |---|---|
  | Something to read | Markdown (`.md`) or HTML |
  | A table or data | CSV (opens in any spreadsheet app) |
  | A chart or image | PNG from Python, or ImageMagick (`convert`) |
  | A Word/Excel/PDF file | Python in a venv: `python3 -m venv /workspace/.venv`, then `/workspace/.venv/bin/pip install python-docx openpyxl reportlab` |
- Installing Python packages is a download, so it makes the run
  untrusted. Do it only when the format really needs it.

## Check your work
Before saying it's done, open the result the way your user will see it:
re-read the file, `head` the CSV, `file` / `identify` the image, or open
it on the desktop and take a screenshot. A file that exists isn't proof
it's right.

## Tell your user where it is
Give the exact path (`/workspace/trip-plan/itinerary.md`) and one line on
what's in it. If it's short, include the content in your reply too.

## Clean up
Delete scratch files, temporary downloads and screenshots you made along
the way. Leave only what your user asked for and anything they'll need
again.
