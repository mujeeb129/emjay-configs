#!/bin/sh
# emjay installer (POSIX sh; macOS and Linux/WSL).
#   1. symlinks zsh/emjay.zsh-theme into ${ZSH_CUSTOM:-$ZSH/custom}/themes/
#   2. sets ZSH_THEME="emjay" in ${ZDOTDIR:-$HOME}/.zshrc, after backing it up
#      to .zshrc.bak. Idempotent: if the theme is already set, nothing is touched.
set -eu

src="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)/zsh/emjay.zsh-theme"
if [ ! -f "$src" ]; then
  echo "emjay: theme file not found at $src" >&2
  exit 1
fi

ZSH=${ZSH:-$HOME/.oh-my-zsh}
if [ ! -d "$ZSH" ]; then
  echo "emjay: oh-my-zsh not found at $ZSH" >&2
  exit 1
fi

ZSH_CUSTOM=${ZSH_CUSTOM:-$ZSH/custom}
mkdir -p "$ZSH_CUSTOM/themes"
ln -sfn "$src" "$ZSH_CUSTOM/themes/emjay.zsh-theme"
echo "emjay: linked $ZSH_CUSTOM/themes/emjay.zsh-theme -> $src"

rc=${ZDOTDIR:-$HOME}/.zshrc
if [ ! -f "$rc" ]; then
  echo "emjay: $rc not found; add ZSH_THEME=\"emjay\" to your zshrc yourself" >&2
  exit 1
fi

# "set": every uncommented ZSH_THEME= line already selects emjay (and one exists)
# "replace": some uncommented ZSH_THEME= line selects something else
# "insert": no uncommented ZSH_THEME= line at all
action=$(awk '
  /^[ \t]*ZSH_THEME=/ {
    n++
    v = $0
    sub(/^[ \t]+/, "", v)
    sub(/[ \t\r]+$/, "", v)
    if (v != "ZSH_THEME=\"emjay\"" && v != "ZSH_THEME='\''emjay'\''" && v != "ZSH_THEME=emjay") bad++
  }
  END {
    if (n > 0 && bad == 0) print "set"
    else if (n > 0) print "replace"
    else print "insert"
  }
' "$rc")

if [ "$action" = set ]; then
  echo "emjay: already set (ZSH_THEME=\"emjay\" in $rc)"
  exit 0
fi

cp -p "$rc" "$rc.bak"

tmp=$(mktemp "$(dirname -- "$rc")/.zshrc.emjay.XXXXXX")
trap 'rm -f "$tmp"' EXIT HUP INT TERM

awk -v mode="$action" '
  /^[ \t]*ZSH_THEME=/ { print "ZSH_THEME=\"emjay\""; next }
  mode == "insert" && !done && /^[ \t]*(source|\.)[ \t].*oh-my-zsh\.sh/ {
    print "ZSH_THEME=\"emjay\""
    done = 1
  }
  { print }
  END { if (mode == "insert" && !done) print "ZSH_THEME=\"emjay\"" }
' "$rc" > "$tmp"

# Write through any symlink and keep the original file's permissions.
cat "$tmp" > "$rc"
rm -f "$tmp"
trap - EXIT HUP INT TERM

echo "emjay: set ZSH_THEME=\"emjay\" in $rc (backup: $rc.bak)"
