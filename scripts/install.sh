#!/bin/zsh
# Installs the latest successful cloud build to ~/Applications, signed with the same stable local identity as
# Audrey Mail and Top Shelf, so macOS keeps the Microphone and Speech Recognition permissions across updates.
# The chat starts the app itself when talk mode is turned on; nothing runs at login.
set -euo pipefail
cd "$(dirname "$0")/.."
APP="build/Audrey Talk.app"
DEST="$HOME/Applications/Audrey Talk.app"
RUN=$(gh run list -R B0xfan/audrey-talk --workflow build.yml --status success --limit 1 --json databaseId -q '.[0].databaseId')
[ -n "$RUN" ] || { echo "No successful cloud build yet."; exit 1; }
rm -rf build; mkdir -p build/cloud
gh run download "$RUN" -R B0xfan/audrey-talk -n AudreyTalk-app -D build/cloud
ditto -x -k build/cloud/AudreyTalk.zip build
SUPPORT="$HOME/Library/Application Support/Audrey Mail"
SIGNKC="$SUPPORT/signing.keychain-db"
[ -f "$SIGNKC" ] || { echo "Signing keychain missing: $SIGNKC"; exit 1; }
security unlock-keychain -p "$(cat "$SUPPORT/signing.pw")" "$SIGNKC"
codesign --force --keychain "$SIGNKC" --sign "Audrey Mail Local Signing" -i com.johnhesch.audreytalk "$APP"
codesign --verify --verbose=2 "$APP"
pkill -x AudreyTalk || true
mkdir -p "$HOME/Applications"
rm -rf "$DEST"; ditto "$APP" "$DEST"; rm -rf build
echo "Installed $DEST (cloud run $RUN)"
