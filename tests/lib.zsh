# tests/lib.zsh: sandbox, assertions and helpers for the emjay test suite.
# Sourced at the top of every tests/test_*.zsh file, which runs under `zsh -f`.
# See docs/DESIGN.md section 8.

# 1. Options.
setopt extendedglob

# 2. Repo root (this file lives in <root>/tests).
typeset -g EMJAY_ROOT=${${(%):-%x}:A:h:h}

# 3. Clean environment. EMJAY_TEST_* are harness controls (filter, skip-perf),
#    not theme configuration, so they survive.
() {
  local v
  for v in ${(k)parameters[(I)EMJAY_*]}; do
    [[ $v == EMJAY_ROOT || $v == EMJAY_TEST_* ]] && continue
    unset $v
  done
  for v in ${(k)parameters[(I)GIT_CONFIG*]}; do unset $v; done
}
unset KUBECONFIG GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY \
  GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_NAMESPACE \
  GIT_CEILING_DIRECTORIES GIT_DISCOVERY_ACROSS_FILESYSTEM GIT_OPTIONAL_LOCKS \
  GIT_AUTHOR_DATE GIT_COMMITTER_DATE GIT_TRACE \
  XDG_CONFIG_HOME    # else git reads the real $XDG_CONFIG_HOME/git/ignore

# 4. UTF-8 locale.
if [[ ${(L)${LC_ALL:-${LC_CTYPE:-$LANG}}} != *(utf-8|utf8)* ]]; then
  case $OSTYPE in
    (darwin*) export LC_ALL=en_US.UTF-8 ;;
    (*)       export LC_ALL=C.UTF-8 ;;
  esac
fi

zmodload zsh/datetime zsh/system 2>/dev/null

# 5. Per-file sandbox, removed on exit. EXIT traps do not run in ( ) subshells
#    or <( ) workers, so only this shell removes it.
typeset -g T
T=$(mktemp -d "${${TMPDIR:-/tmp}%/}/emjay-test.XXXXXX") || {
  print -ru2 -- "lib.zsh: mktemp failed"; exit 1
}
T=${T:A}    # canonical path (macOS: /var -> /private/var, /tmp -> /private/tmp)
trap 'builtin cd -q /; rm -rf -- "$T"' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

# 7. Isolated git configuration.
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=$T/gitconfig GIT_EDITOR=: GIT_PAGER=cat
export GIT_TERMINAL_PROMPT=0

# 8. The gitconfig.
print -r -- '[user]
	name = Emjay Test
	email = emjay-test@example.invalid
[init]
	defaultBranch = main
[advice]
	detachedHead = false
[commit]
	gpgSign = false
[tag]
	gpgSign = false
[protocol "file"]
	allow = always
[core]
	autocrlf = false
[gc]
	auto = 0' > $T/gitconfig

# 9. The theme. Sourced after the environment is clean, since its glyph
#    selection runs at load and reads the locale.
if ! source $EMJAY_ROOT/zsh/emjay.zsh-theme; then
  print -ru2 -- "lib.zsh: sourcing $EMJAY_ROOT/zsh/emjay.zsh-theme failed"
  exit 1
fi
typeset -g EMJAY_GIT_ASYNC=0

# 6. Abort if the sandbox is inside a git repo. This step needs the theme's
#    _emjay_git_find_root, so it runs after step 9.
if (( ! $+functions[_emjay_git_find_root] )); then
  print -ru2 -- "lib.zsh: theme does not define _emjay_git_find_root"
  exit 1
fi
if _emjay_git_find_root $T; then
  print -ru2 -- "lib.zsh: sandbox $T is inside a git repo ($REPLY); set TMPDIR elsewhere"
  exit 1
fi
REPLY=

# Unicode glyphs from section 3.2, for building expected strings.
typeset -gA UG=(
  branch   $'\u2387'  detached $'\u27a6'  ahead    $'\u2191'  behind   $'\u2193'
  staged   $'\u25cf'  modified $'\u271a'  untracked $'\u2026' stash    $'\u2691'
  conflict $'\u2716'  clean    $'\u2714'  kube     $'\u2388'  error    $'\u2718'
  took     'took'     prompt   $'\u276f'
)

# ---------------------------------------------------------------- runner

typeset -g TT= _t_name=
typeset -gi _t_failed=0

run_tests() {
  local name
  local -i n=0 rc=0 st
  local -a names
  names=(${(ok)functions[(I)test_*]})
  if [[ -n $EMJAY_TEST_FILTER ]]; then
    names=(${(M)names:#${~EMJAY_TEST_FILTER}})
  fi
  for name in $names; do
    (( ++n ))
    _t_name=$name
    TT=$T/$name
    mkdir -p -- $TT/home
    ( export HOME=$TT/home; builtin cd -q -- $TT || exit 1; _t_failed=0; $name; exit $_t_failed )
    st=$?
    if (( st == 0 )); then
      print -r -- "ok $n - $name"
    else
      print -r -- "not ok $n - $name"
      rc=1
    fi
  done
  _t_name=
  return rc
}

# ------------------------------------------------------------ assertions
# On failure: print "  FAIL: <test>: <msg>: expected 'x' got 'y'" to stderr,
# set _t_failed=1 and return 1. They never exit.

_t_fail() {   # <msg> <expected-text> <got-text>
  print -ru2 -- "  FAIL: ${_t_name:+$_t_name: }$1: expected '${(V)2}' got '${(V)3}'"
  _t_failed=1
  return 1
}

assert_eq() {          # <actual> <expected> [msg]
  [[ $1 == "$2" ]] && return 0
  _t_fail "${3:-assert_eq}" "$2" "$1"
}

assert_ne() {          # <actual> <unexpected> [msg]
  [[ $1 != "$2" ]] && return 0
  _t_fail "${3:-assert_ne}" "not $2" "$1"
}

assert_match() {       # <actual> <zsh-glob> [msg]
  emulate -L zsh
  setopt extendedglob
  [[ $1 == ${~2} ]] && return 0
  _t_fail "${3:-assert_match}" "glob $2" "$1"
}

assert_empty() {       # <actual> [msg]
  [[ -z $1 ]] && return 0
  _t_fail "${2:-assert_empty}" "" "$1"
}

assert_nonempty() {    # <actual> [msg]
  [[ -n $1 ]] && return 0
  _t_fail "${2:-assert_nonempty}" "non-empty" "$1"
}

assert_contains() {    # <haystack> <needle> [msg]
  [[ $1 == *"$2"* ]] && return 0
  _t_fail "${3:-assert_contains}" "containing $2" "$1"
}

assert_not_contains() {  # <haystack> <needle> [msg]
  [[ $1 != *"$2"* ]] && return 0
  _t_fail "${3:-assert_not_contains}" "not containing $2" "$1"
}

assert_ok() {          # <cmd...>  (runs in the current shell)
  "$@"
  local -i _ao_rc=$?
  (( _ao_rc == 0 )) && return 0
  _t_fail "assert_ok ${(j: :)${(q-)@}}" "status 0" "status $_ao_rc"
}

assert_fail() {        # <cmd...>  (runs in the current shell)
  "$@"
  local -i _af_rc=$?
  (( _af_rc != 0 )) && return 0
  _t_fail "assert_fail ${(j: :)${(q-)@}}" "non-zero status" "status 0"
}

# --------------------------------------------------------------- helpers

# strip_prompt <raw> -> REPLY. Left-to-right scan: a %% pair is kept as is,
# %F{...} %f %B %b are dropped, everything else is kept. Then ${(%)...}
# expands %~ and turns each kept %% into % (the only %% -> % conversion).
# So escaped user data such as "a%%b" is never mistaken for a %b code.
strip_prompt() {
  emulate -L zsh
  local s=$1 out= rest
  local -i i=1 n=${#1}
  while (( i <= n )); do
    if [[ $s[i] == '%' ]]; then
      case $s[i+1] in
        ('%') out+='%%'; (( i += 2 )); continue ;;
        (f|B|b) (( i += 2 )); continue ;;
        (F)
          if [[ $s[i+2] == '{' ]]; then
            rest=${s[i+3,n]}
            if [[ $rest == *'}'* ]]; then
              (( i += 3 + ${#rest%%\}*} + 1 ))
              continue
            fi
          fi ;;
      esac
    fi
    out+=$s[i]
    (( i++ ))
  done
  REPLY=${(%)out}
}

# seg_text <dir|git|kube|status|took|char|line1|prompt> -> REPLY
seg_text() {
  case $1 in
    (dir|git|kube|status|took|char)
      local _st_v=_emjay_seg_$1
      strip_prompt "${(P)_st_v}" ;;
    (line1)  strip_prompt "$_emjay_line1" ;;
    (prompt) strip_prompt "$_emjay_prompt" ;;
    (*) print -ru2 -- "seg_text: unknown segment '$1'"; REPLY=; return 2 ;;
  esac
}

# mkrepo <dir> [branch=main]: init, a.txt containing "a", one commit "init".
mkrepo() {
  local dir=$1 br=${2:-main}
  mkdir -p -- $dir &&
    git init -q -b $br -- $dir &&
    print -r -- a > $dir/a.txt &&
    git -C $dir add a.txt &&
    git -C $dir commit -qm init
}

# mkrepo_empty <dir>: init only (default branch main via the test gitconfig).
mkrepo_empty() {
  mkdir -p -- $1 && git init -q -- $1
}

# kube_fixture <name> -> REPLY (read-only; copy into $TT before modifying).
kube_fixture() {
  REPLY=$EMJAY_ROOT/tests/fixtures/kube/$1.yaml
}

# capture_err <cmd...>: run in the current shell with stderr to $TT/.err;
# REPLY = that output, byte for byte. Returns the command's status.
capture_err() {
  local -i _ce_rc
  "$@" 2> $TT/.err
  _ce_rc=$?
  REPLY=
  IFS= read -r -d '' REPLY < $TT/.err
  return _ce_rc
}
