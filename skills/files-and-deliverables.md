---
name: files-and-deliverables
description: >-
  When your user attaches a file, asks you to produce a document, report,
  spreadsheet, image or other file, or asks where something you made is.
---
# Files and deliverables

`/workspace` is shared between you and your user: it persists between
chats, and they can browse it. The file tools and `post_screenshot` only
reach paths inside `/workspace`.

## Files your user attaches
- An **image** arrives in your message directly (if your model can see
  images).
- **Any other file** is copied into `/workspace`, with a note like
  `[Attached file: workspace/report.pdf]`. Open it by that path:
  `read_file` for text, `run_shell` for the rest (`pdftotext` for a PDF,
  Python with `pandas`/`openpyxl` for a spreadsheet).
- It's your user's file. Don't edit it in place: write a new file
  (`report-edited.md`) unless they ask you to overwrite it.

## Making things
- Put each deliverable in `/workspace` or a task folder
  (`/workspace/trip-plan/`), named for what it is: `q3-budget-summary.md`,
  not `output.txt`.
- `write_file` replaces the whole file. If the name exists, pick another
  or ask.
- There's no office suite. Pick the format by what your user will do:
  | They want | Make |
  |---|---|
  | Something to read | Markdown (`.md`) or HTML |
  | A table or data | CSV, or `.xlsx` with `openpyxl` (installed) |
  | A chart or image | PNG from Python, or ImageMagick (`convert`) |
  | A PDF | Write HTML, then `chromium --headless --no-sandbox --print-to-pdf=/workspace/<name>.pdf /workspace/<name>.html` |
  | A Word file | `python3 -m venv /workspace/.venv`, then `/workspace/.venv/bin/pip install python-docx` |
- Installing packages is a download and makes the run untrusted. Do it
  only when the format needs it.

## Check your work
Open the result the way your user will: re-read the file, `head` the CSV,
`file` / `identify` the image, `pdftotext` the PDF. A file that exists
isn't proof it's right. Never say you made a file you didn't write.

## Tell your user where it is
Call `finish_task` with the exact path (`/workspace/trip-plan/itinerary.md`)
and one line on what's in it. If it's short, include the content too. For
a visual result, also `post_screenshot` it (see sharing-screenshots).

## Clean up
Delete scratch files, temporary downloads and screenshots you made. Leave
what your user asked for and anything they'll need again.
