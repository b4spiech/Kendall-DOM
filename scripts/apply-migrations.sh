#!/usr/bin/env bash
# Applies migrations/*.sql to DOM1_URL in numeric order, stopping at the
# first failure and reporting exactly which file failed.
#
# Requires:
#   - scripts/dom1-tunnel.sh running in another terminal tab
#   - DOM1_URL loaded in THIS shell: source scripts/load-env.sh
#
# This script never drops, resets, or wipes anything. It only runs the
# migration files present in migrations/, in order.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

if [ -z "${DOM1_URL:-}" ]; then
  echo "DOM1_URL is not set. Run: source scripts/load-env.sh" >&2
  exit 1
fi

shopt -s nullglob
files=(migrations/*.sql)
shopt -u nullglob

if [ ${#files[@]} -eq 0 ]; then
  echo "No .sql files found in migrations/." >&2
  exit 1
fi

for f in "${files[@]}"; do
  echo "==> Applying $f"
  if ! psql "$DOM1_URL" -v ON_ERROR_STOP=1 -f "$f"; then
    echo "" >&2
    echo "FAILED: $f" >&2
    echo "Stopped here. Files before this one in the list above already committed (each migration is its own BEGIN/COMMIT transaction, per DATABASE-HANDBOOK.md)." >&2
    exit 1
  fi
done

echo ""
echo "All migrations applied successfully."
