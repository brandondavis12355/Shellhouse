#!/bin/bash
# Generates the dark wallpaper with a soft diagonal light sweep, so the
# desktop matches the reference environment without shipping a binary image.
set -e
mkdir -p /usr/share/backgrounds
OUT=/usr/share/backgrounds/agent-wallpaper.png

magick -size 1920x1200 \
  gradient:'#1a1a1c-#0a0a0b' \
  \( -size 1920x1200 xc:black \
     -fill 'gradient:#4a4a50-#000000' \
     -draw 'path "M 0,1200 C 700,900 1100,500 1920,150 L 1920,420 C 1100,760 760,1060 300,1200 Z"' \
     -blur 0x60 \) \
  -compose screen -composite \
  -attenuate 0.4 +noise Gaussian \
  "$OUT"

echo "wallpaper written to $OUT"
