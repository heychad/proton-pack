#!/usr/bin/env bash
# proton-pack installer. Idempotent; never overwrites your existing config.
set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CFG="${XDG_CONFIG_HOME:-$HOME/.config}/proton-pack"
RC="${ZDOTDIR:-$HOME}/.zshrc"
SRC_FILE="$SRC_DIR/proton-pack.zsh"
SRC_LINE="source \"$SRC_FILE\""

mkdir -p "$CFG/accounts"
chmod 700 "$CFG" "$CFG/accounts"

if [ ! -e "$CFG/profiles.conf" ]; then
  cp "$SRC_DIR/profiles.conf.example" "$CFG/profiles.conf"
  echo "Created $CFG/profiles.conf — edit it to define your profiles."
else
  echo "Kept existing $CFG/profiles.conf"
fi

if grep -Fq "$SRC_FILE" "$RC" 2>/dev/null; then
  echo "Already sourced in $RC"
else
  printf '\n# proton-pack\n%s\n' "$SRC_LINE" >> "$RC"
  echo "Added source line to $RC"
fi

echo
echo "Done. Open a new terminal (or run: source \"$SRC_FILE\")."
echo "Then:  edit $CFG/profiles.conf  ->  pp doctor  ->  pp profiles"
