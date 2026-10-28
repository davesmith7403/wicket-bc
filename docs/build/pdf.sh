#!/bin/sh
# Print docs/Wicket-Product-Guide.html to docs/Wicket-Product-Guide.pdf with headless Chrome (macOS).
# Chrome's new headless mode does not always exit after --print-to-pdf here, so poll for a stable file and kill it.
set -e
HERE=$(cd "$(dirname "$0")" && pwd); DOCS=$(cd "$HERE/.." && pwd)
CH="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
OUT="$DOCS/Wicket-Product-Guide.pdf"; PROFILE="$HERE/out/chrome-profile"
rm -f "$OUT"; rm -rf "$PROFILE"; mkdir -p "$PROFILE"
"$CH" --headless=new --disable-gpu --no-first-run --user-data-dir="$PROFILE" --no-pdf-header-footer \
  --virtual-time-budget=20000 --print-to-pdf="$OUT" "file://$DOCS/Wicket-Product-Guide.html" >/dev/null 2>&1 &
CPID=$!
for i in $(seq 1 90); do
  sleep 2
  if [ -s "$OUT" ]; then s1=$(stat -f%z "$OUT"); sleep 2; s2=$(stat -f%z "$OUT"); [ "$s1" = "$s2" ] && break; fi
done
kill $CPID 2>/dev/null || true; pkill -f "$PROFILE" 2>/dev/null || true
ls -la "$OUT"
