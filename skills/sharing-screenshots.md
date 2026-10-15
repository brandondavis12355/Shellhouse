---
name: sharing-screenshots
description: >-
  Show your user what you made or what's on your screen with
  post_screenshot: when they ask to see something, and when you finish
  visual work (a web page, UI, chart, design, document) they'd want to see.
  How to capture the desktop, a web page, or an image file.
---
# Sharing screenshots

`post_screenshot(caption, path)` puts an image into the chat you're in
(1:1, or the group during a group turn). It is the only way your user
sees an image: `screenshot` shows the screen to you, not to them.

## When they ask for one
"Show me", "send a screenshot", "what does the site look like": you're
not done until `post_screenshot` returns `posted: true`. Make the tool
calls; writing "Let me take a screenshot" does nothing. Never describe the
page instead, and never claim you posted an image you didn't. No
`post_screenshot` tool (a routine, a message from another bot)? Save a PNG
in `/workspace` and give the path.

Also post one when you finish visual work, or when an on-screen error
explains a problem. Not for text output (paste it), not the same view twice.

## How to capture
- **The desktop as it is now**: `post_screenshot` with just a caption.
- **A live site, in the desktop browser**: `open_app("browser", "<url>")`,
  `run_shell("sleep 5")`, `screenshot` to check it, then `post_screenshot`
  with no `path`.
- **Any page, headless** (a site, or your own server started with
  `run_shell` and `background: true`):
  `chromium --headless --no-sandbox --disable-gpu --hide-scrollbars --window-size=1280,800 --virtual-time-budget=5000 --screenshot=/workspace/shot.png <url>`
  then `post_screenshot` with `path: "/workspace/shot.png"`.
  Phone-sized: `--window-size=390,844`.
- **An image file you made**: its `path` (PNG, JPEG, GIF, WebP, inside
  `/workspace`).

## Check before you post
- Desktop: the address bar shows the right URL, and the page isn't
  blank, half-loaded, an error, a 404 or a login page. Not loaded? Wait
  and take another `screenshot`.
- Headless (you can't see the file):
  `curl -sL -o /dev/null -w '%{http_code} %{url_effective}\n' '<url>'`
  must print `200` and the right address, and `identify /workspace/shot.png`
  must show 1280x800.
- Wrong page? Fix it, or tell your user what you got instead.

## The caption
One or two plain lines: "example.com home page at 1280×800, after the 2.1
deploy." Then `finish_task`, without describing the image again.
