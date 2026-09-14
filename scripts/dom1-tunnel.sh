#!/usr/bin/env bash
# Opens the Railway tunnel to DOM1 and keeps it in the foreground.
#
# Run this in its own terminal tab and leave it running:
#   bash scripts/dom1-tunnel.sh
# Ctrl+C in that tab closes the tunnel.
#
# The local port Railway assigns is NOT stable across runs. Rather than
# making you copy the new port into .env by hand every time, this script
# watches its own output and rewrites the DOM1_URL line in .env to match
# the live port as soon as the tunnel comes up. That keeps .env correct
# for every other terminal tab, for as long as this tunnel stays open.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

ENV_FILE=.env
touch "$ENV_FILE"

# stdbuf -oL/-eL: without it, output can sit in a pipe buffer instead of
# appearing line-by-line, which would delay .env being updated. The 2>&1
# matters too — Railway's CLI prints its connection banner (including the
# URL line we need) to stderr, not stdout, so it must be merged in before
# the pipe or this loop never sees it.
stdbuf -oL -eL railway connect DOM1 --tunnel-only 2>&1 | while IFS= read -r line; do
  echo "$line"
  # Strip ANSI color codes before matching, in case the CLI adds them.
  clean_line=$(printf '%s' "$line" | sed -r 's/\x1b\[[0-9;]*m//g')
  if [[ "$clean_line" =~ ^\ *URL:\ *(postgresql://.*)$ ]]; then
    url="${BASH_REMATCH[1]}"
    if grep -q '^DOM1_URL=' "$ENV_FILE" 2>/dev/null; then
      sed -i "s#^DOM1_URL=.*#DOM1_URL=${url}#" "$ENV_FILE"
    else
      echo "DOM1_URL=${url}" >> "$ENV_FILE"
    fi
    echo ">> .env updated with the current tunnel URL."
  fi
done
