#!/bin/sh
# emjay installer (POSIX sh; macOS and Linux/WSL).
#   1. symlinks zsh/emjay.zsh-theme into <ZSH_CUSTOM>/themes/
#   2. sets ZSH_THEME="emjay" in <ZDOTDIR or HOME>/.zshrc, after a backup.
#      Idempotent: when the theme is already set, nothing is touched.
#
# Locations: the environment wins. Otherwise ZDOTDIR is taken from an
# uncommented assignment in ~/.zshenv, and ZSH and ZSH_CUSTOM from the zshrc,
# when the value is a plain path built only from ~, $HOME, ${HOME}, $ZSH,
# ${ZSH} or ${XDG_CONFIG_HOME:-$HOME/.config}. Anything else stops the install,
# before any file is touched, with instructions.
set -eu

warn() { printf 'emjay: %s\n' "$*" >&2; }
die() { warn "$@"; exit 1; }

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
src=$here/zsh/emjay.zsh-theme
[ -f "$src" ] || die "theme file not found at $src"

# ----------------------------------------------------------------- awk parts
# Kept in single-quoted strings (\047 is a single quote), not heredocs inside
# $(...), which old shells such as macOS /bin/sh (bash 3.2) misparse.

# code_part(line): the line without its comment (quote-aware).
# is_omz_source(code): the code sources oh-my-zsh.sh ("source" or "." as a word),
# also when guarded, as in: [ -f $ZSH/oh-my-zsh.sh ] && source $ZSH/oh-my-zsh.sh
COMMON_AWK='
function code_part(line,    i, n, c, q) {
  q = ""; n = length(line)
  for (i = 1; i <= n; i++) {
    c = substr(line, i, 1)
    if (q != "") {
      if (c == q) q = ""
      else if (c == "\\" && q == "\"") i++
      continue
    }
    if (c == "\"" || c == "\047") { q = c; continue }
    if (c == "\\") { i++; continue }
    if (c == "#" && (i == 1 || substr(line, i - 1, 1) ~ /[ \t;&|(]/)) return substr(line, 1, i - 1)
  }
  return line
}
function is_omz_source(code) {
  if (index(code, "oh-my-zsh.sh") == 0) return 0
  return ((" " code " ") ~ /[ \t;&|({](source|\.)[ \t]/)
}
function value_token(s,    c, j) {
  c = substr(s, 1, 1)
  if (c == "\"" || c == "\047") {
    j = index(substr(s, 2), c)
    return j ? substr(s, 1, j + 1) : s
  }
  match(s, /^[^ \t;&|)\r]*/)
  return substr(s, 1, RLENGTH)
}
'

# VAR_AWK (EMJAY_VAR=NAME): the effective "NAME=value" or "export NAME=value"
# at the start of an uncommented line (the last one before oh-my-zsh.sh is
# sourced, or the last one when nothing sources it). Prints "ok:<path>" when the
# value resolves to a plain absolute path, "bad:<raw value>" when it does not,
# and nothing when NAME is not assigned (or assigned an empty value).
VAR_AWK='
function lit_replace(s, pat, rep,    out, i) {
  out = ""
  while ((i = index(s, pat)) > 0) { out = out substr(s, 1, i - 1) rep; s = substr(s, i + length(pat)) }
  return out s
}
function var_replace(s, pat, rep,    out, i, nx) {
  out = ""
  while ((i = index(s, pat)) > 0) {
    nx = substr(s, i + length(pat), 1)
    if (nx ~ /[A-Za-z0-9_]/) out = out substr(s, 1, i + length(pat) - 1)
    else out = out substr(s, 1, i - 1) rep
    s = substr(s, i + length(pat))
  }
  return out s
}
function expand(tok,    q, v, home, zsh, xdg) {
  home = ENVIRON["EMJAY_HOME"]; zsh = ENVIRON["EMJAY_ZSH"]; xdg = ENVIRON["EMJAY_XDG"]
  if (xdg == "") xdg = home "/.config"
  q = substr(tok, 1, 1)
  if (q == "\"" || q == "\047") {
    if (length(tok) < 2 || substr(tok, length(tok), 1) != q) return ""
    v = substr(tok, 2, length(tok) - 2)
    if (q == "\047") return (v ~ /^\// && v !~ /[\\]/) ? v : ""
  } else {
    q = ""; v = tok
  }
  if (q == "" && (v == "~" || substr(v, 1, 2) == "~/")) v = home substr(v, 2)
  v = lit_replace(v, "${XDG_CONFIG_HOME:-$HOME/.config}", xdg)
  v = lit_replace(v, "${HOME}", home)
  v = var_replace(v, "$HOME", home)
  if (zsh != "") { v = lit_replace(v, "${ZSH}", zsh); v = var_replace(v, "$ZSH", zsh) }
  if (v ~ /[$`\\]/ || v !~ /^\//) return ""
  if (q == "" && v ~ /[*?[~]/) return ""
  return v
}
BEGIN { re = "^[ \t]*(export[ \t]+)?" ENVIRON["EMJAY_VAR"] "="; found = 0; frozen = 0 }
/^[ \t]*#/ { next }
{
  code = code_part($0)
  if (!frozen && match(code, re)) { found = 1; last = value_token(substr(code, RSTART + RLENGTH)) }
  if (is_omz_source(code)) frozen = 1
}
END {
  if (!found || last == "" || last == "\"\"" || last == "\047\047") exit 0
  v = expand(last)
  if (v != "") print "ok:" v
  else print "bad:" last
}
'

# THEME_AWK. Only a ZSH_THEME= that starts a statement counts (line start,
# after ; & | or export), and values containing $ or a backquote are left
# alone (e.g. ZSH_THEME="$1" in a function body). Only the assignment token is
# rewritten: indentation, comments and other code on the line are kept.
#   EMJAY_MODE=check    prints "<set|replace|insert> <src|nosrc>"
#   EMJAY_MODE=replace  prints the file with every counted token set to emjay
#   EMJAY_MODE=insert   prints the file with ZSH_THEME="emjay" inserted before
#                       the line that sources oh-my-zsh.sh, or appended
THEME_AWK='
function scan(code, rewrite,    s, out, pre, tok, val, c) {
  s = ";" code; out = ""
  while (match(s, /[;&|][ \t]*(export[ \t]+)?ZSH_THEME=/)) {
    pre = substr(s, 1, RSTART + RLENGTH - 1)
    s = substr(s, RSTART + RLENGTH)
    tok = value_token(s)
    s = substr(s, length(tok) + 1)
    if (tok ~ /[$`]/) { out = out pre tok; continue }
    val = tok; c = substr(tok, 1, 1)
    if (c == "\"" || c == "\047") val = substr(tok, 2, length(tok) - 2)
    if (val == "emjay") nemjay++; else nother++
    out = out pre (rewrite ? "\"emjay\"" : tok)
  }
  return substr(out s, 2)
}
BEGIN { mode = ENVIRON["EMJAY_MODE"]; done = 0; src = 0; nemjay = 0; nother = 0 }
{
  line = $0
  if (line ~ /^[ \t]*#/) { if (mode != "check") print line; next }
  code = code_part(line)
  rest = substr(line, length(code) + 1)
  if (is_omz_source(code)) {
    src = 1
    if (mode == "insert" && !done) { print "ZSH_THEME=\"emjay\""; done = 1 }
  }
  code = scan(code, mode == "replace")
  if (mode != "check") print code rest
}
END {
  if (mode == "check") printf "%s %s\n", (nother ? "replace" : (nemjay ? "set" : "insert")), (src ? "src" : "nosrc")
  else if (mode == "insert" && !done) print "ZSH_THEME=\"emjay\""
}
'

# rc_var <file> <NAME> <value of $ZSH or ''>: sets RV (none|ok|bad) and RV_VAL.
rc_var() {
  RV=none RV_VAL=
  [ -f "$1" ] || return 0
  rv_out=$(EMJAY_VAR=$2 EMJAY_ZSH=$3 EMJAY_HOME=$HOME EMJAY_XDG=${XDG_CONFIG_HOME:-} \
    awk "$COMMON_AWK$VAR_AWK" "$1")
  case $rv_out in
    ok:*) RV=ok RV_VAL=${rv_out#ok:} ;;
    bad:*) RV=bad RV_VAL=${rv_out#bad:} ;;
  esac
}

# ----------------------------------------------------- where things live
# The zshrc: $ZDOTDIR, else a ZDOTDIR assignment in ~/.zshenv, else $HOME.
if [ -n "${ZDOTDIR:-}" ]; then
  zdot=$ZDOTDIR
else
  zdot=$HOME
  rc_var "$HOME/.zshenv" ZDOTDIR ""
  case $RV in
    ok)
      zdot=$RV_VAL
      [ "$zdot" = "$HOME" ] || warn "ZDOTDIR is not set in the environment; using $zdot from $HOME/.zshenv" ;;
    bad)
      die "$HOME/.zshenv sets ZDOTDIR=$RV_VAL, which install.sh cannot resolve.
  Re-run with it set, e.g.:  ZDOTDIR=/path/to/zdotdir sh $0" ;;
  esac
fi
rc=$zdot/.zshrc

# oh-my-zsh: $ZSH, else a ZSH assignment in the zshrc, else ~/.oh-my-zsh.
if [ -z "${ZSH:-}" ]; then
  ZSH=$HOME/.oh-my-zsh
  rc_var "$rc" ZSH ""
  case $RV in
    ok) ZSH=$RV_VAL ;;
    bad)
      die "$rc sets ZSH=$RV_VAL, which install.sh cannot resolve.
  Re-run with it set, e.g.:  ZSH=/path/to/oh-my-zsh sh $0" ;;
  esac
fi
[ -d "$ZSH" ] || die "oh-my-zsh not found at $ZSH"

# Custom dir: $ZSH_CUSTOM, else a ZSH_CUSTOM assignment in the zshrc, else $ZSH/custom.
if [ -n "${ZSH_CUSTOM:-}" ]; then
  custom=$ZSH_CUSTOM
else
  custom=$ZSH/custom
  rc_var "$rc" ZSH_CUSTOM "$ZSH"
  case $RV in
    ok) custom=$RV_VAL ;;
    bad)
      die "$rc sets ZSH_CUSTOM=$RV_VAL, which install.sh cannot resolve. Nothing was changed.
  Link the theme yourself:   ln -s '$src' <your ZSH_CUSTOM>/themes/emjay.zsh-theme
  or re-run with it set:     ZSH_CUSTOM=/path/to/custom sh $0" ;;
  esac
fi

link=$custom/themes/emjay.zsh-theme
if [ -e "$link" ] && [ ! -L "$link" ]; then
  die "$link exists and is not a symlink (it may hold local edits); move it aside and re-run. Nothing was changed."
fi

# ------------------------------------------------------------------ link
mkdir -p "$custom/themes"
ln -sfn "$src" "$link"
echo "emjay: linked $link -> $src"

# ---------------------------------------------------------------- zshrc
[ -f "$rc" ] || die "$rc not found; add ZSH_THEME=\"emjay\" to your zshrc, before the line that sources oh-my-zsh.sh"

set -- $(EMJAY_MODE=check awk "$COMMON_AWK$THEME_AWK" "$rc")
action=$1 has_src=$2

if [ "$action" = set ]; then
  echo "emjay: already set (ZSH_THEME=\"emjay\" in $rc)"
  exit 0
fi

# Back up first; never overwrite an older backup that differs.
bak=$rc.bak
if [ -e "$bak" ] && ! cmp -s "$rc" "$bak"; then
  bak=$rc.bak.$(date +%s)
  [ ! -e "$bak" ] || bak=$bak.$$
fi
cp -p "$rc" "$bak"

# Rewrite through a temp file in the same directory, then copy the bytes back
# so a symlinked zshrc stays a symlink and keeps its permissions.
tmp=$(mktemp "$(dirname -- "$rc")/.zshrc.emjay.XXXXXX")
trap 'rm -f "$tmp"' EXIT HUP INT TERM
EMJAY_MODE=$action awk "$COMMON_AWK$THEME_AWK" "$rc" > "$tmp"
cat "$tmp" > "$rc"
rm -f "$tmp"
trap - EXIT HUP INT TERM

echo "emjay: set ZSH_THEME=\"emjay\" in $rc (backup: $bak)"
if [ "$action" = insert ] && [ "$has_src" = nosrc ]; then
  warn "no line in $rc sources oh-my-zsh.sh, so ZSH_THEME=\"emjay\" was appended at the end; it only takes effect if it comes before oh-my-zsh.sh is sourced"
fi
