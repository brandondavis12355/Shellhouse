#!/bin/bash
# Double-click this file in Finder to install Shellhouse: it opens Terminal and runs ./initial_setup.sh, which sets
# up this Mac, your Linux box and the app, asking its questions in dialogs. Run it from Terminal with options if you
# like, e.g.  ./"Install Shellhouse.command" --host 192.0.2.10 --user alice   (see ./initial_setup.sh --help).
#
# If macOS says it can't be opened because it's from an unidentified developer (it can happen with a downloaded
# copy), right-click the file, choose Open, then Open again.
#
# Drafted with AI assistance (Claude Code); read it before you run it.

# Always from this folder, wherever Terminal started.
cd "$(dirname "$0")" || { echo "Can't find the Shellhouse folder."; read -n 1 -s -r -p "Press any key to close."; exit 1; }

[ -t 1 ] && printf '\033]0;Shellhouse setup\007'      # the Terminal window's title
if [ "$(uname -s)" != "Darwin" ]; then
  echo "Run this on your Mac: it sets up the Linux box over SSH."
  [ -t 0 ] && read -n 1 -s -r -p "Press any key to close."
  exit 1
fi

./initial_setup.sh "$@"
status=$?

echo
if [ "$status" -eq 0 ]; then
  echo "Shellhouse setup finished."
else
  echo "Setup stopped (exit $status). Fix what's shown above and double-click this file again: it picks up where it left off."
fi
# Keep the window open so the result can be read (only when someone is there to close it).
[ -t 0 ] && read -n 1 -s -r -p "Press any key to close this window."
echo
exit "$status"
