---
name: sharing-screenshots
description: >-
  Show your user what you made or what's on your screen with
  post_screenshot: when they ask to see something, and when you finish
  visual work (a web page, UI, chart, design, document) they'd want to see.
  How to capture the desktop, a web page, or an image file.
---
# Sharing screenshots

`post_screenshot` puts an image into the chat you're working in: your 1:1
chat, or the group during a group turn. Your user sees it right away.

## When to post one
- **They ask**: "show me", "what does it look like", "send a screenshot".
- **You finished something visual**: a web page or app UI, a chart, a
  rendered document, a design. Post one when the work is done, not for
  every intermediate step.
- **Something on screen explains a problem** better than words: an error
  dialog, a broken layout.

Don't post screenshots of plain text output (paste the few lines instead),
and don't post the same view twice.

## How to capture
- **Your desktop as it is now**: `post_screenshot` with just a caption.
- **A web page or app you built** (no browser window needed): start the
  server if it isn't running (`run_shell` with `background: true`), then
  render the page headlessly:
  `chromium --headless --no-sandbox --disable-gpu --hide-scrollbars --window-size=1280,800 --screenshot=/workspace/shot.png http://localhost:5000`
  and post it: `post_screenshot` with `path: "/workspace/shot.png"`.
  For a phone-sized view use `--window-size=390,844`.
- **An image file you made** (a chart, an export): pass its `path`.
  PNG, JPEG, GIF and WebP work.

Check the file exists (`ls -la`) before posting. A blank or tiny image
usually means the page hadn't loaded: add `--virtual-time-budget=3000`.

## The caption
One or two plain lines saying what it shows and anything to notice:
"The game board at 1280×800: the AI just won on the diagonal." Not a
report.
