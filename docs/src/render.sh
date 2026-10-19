#!/usr/bin/env bash
# Renders docs/hero.png and docs/hero-dark.png from hero.html with headless Chrome.
set -euo pipefail
cd "$(dirname "$0")"
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
sed 's/<html>/<html class="dark">/' hero.html > hero-dark.html
for name in hero hero-dark; do
  "$CHROME" --headless=new --disable-gpu --hide-scrollbars --force-device-scale-factor=2 \
    --window-size=800,400 --screenshot="$PWD/../$name.png" "file://$PWD/$name.html" 2>/dev/null
done
rm hero-dark.html
