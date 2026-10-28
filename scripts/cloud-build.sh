#!/bin/zsh
# Starts a cloud build on GitHub (workflow build.yml) and prints the run URL. Does not wait. No compiling on this Mac.
set -euo pipefail
cd "$(dirname "$0")/.."
BRANCH="${1:-$(git branch --show-current)}"
gh workflow run build.yml -R B0xfan/audrey-talk --ref "$BRANCH"
sleep 4   # the new run needs a moment to appear in the list
gh run list -R B0xfan/audrey-talk --workflow build.yml --branch "$BRANCH" --limit 1 --json url -q '.[0].url'
