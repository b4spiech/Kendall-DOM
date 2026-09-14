# Loads .env into the CURRENT shell. Must be sourced, not executed:
#   source scripts/load-env.sh
#   . scripts/load-env.sh
#
# Why sourcing matters: running this as ./scripts/load-env.sh (or
# bash scripts/load-env.sh) executes it in a child process. That child gets
# the exported variables, then exits, and they vanish with it — the parent
# shell (your terminal tab) never sees them. `source` runs the script's
# commands directly in your current shell instead of a child, so the
# exports stick around after the script "returns". This is also why
# `export` alone doesn't survive across terminal tabs: each tab is a
# separate shell process with its own environment, and there's no shared
# memory between them except what's re-loaded from a file like .env.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [ ! -f "$repo_root/.env" ]; then
  echo "load-env: $repo_root/.env not found." >&2
  return 1 2>/dev/null || exit 1
fi

set -a
source "$repo_root/.env"
set +a

if [ -z "${DOM1_URL:-}" ]; then
  echo "load-env: DOM1_URL is not set in .env." >&2
  return 1 2>/dev/null || exit 1
fi

echo "load-env: DOM1_URL loaded (make sure scripts/dom1-tunnel.sh is running in another tab)."
