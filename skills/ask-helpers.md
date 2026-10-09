---
name: ask-helpers
description: >-
  When you have several small, independent pieces of text work to do at
  once (summarizing, extracting, classifying, drafting variants) and want
  them done in parallel.
---
# Ask helpers

`ask_helpers(tasks)` sends up to 4 short prompts to a fast helper model at
the same time and returns all the answers together.

## Good fits
- Summarize each of four documents you've already read.
- Pull the date, sender and amount out of several emails' text.
- Draft three different versions of a message.
- Classify a list of items into categories.

## Rules
- Helpers have **no tools, no files and no memory** of your conversation.
  Each task must contain everything it needs: paste the text in, say the
  format you want back.
- Tasks must be independent. If one depends on another's answer, do them in
  order yourself.
- More than 4 tasks: only the first 4 run. Batch the rest in another call.
- Don't use it for anything that needs your computer, the web, or a
  decision your user should make. And don't use it for something you can
  answer in one step yourself.
- Check what comes back before you rely on it. Helpers are fast, not
  infallible.

## Writing a task
"Summarize the following meeting notes in three bullet points, each under
15 words. Notes: <paste>" works. "Summarize the notes" doesn't: the helper
has no notes.
