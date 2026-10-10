# tests/test_static.zsh: syntax, portability and hygiene checks on the sources.
source ${0:A:h}/lib.zsh

typeset -g THEME=$EMJAY_ROOT/zsh/emjay.zsh-theme INSTALL=$EMJAY_ROOT/install.sh

# _t_slurp <file> -> REPLY, byte for byte ('' if missing)
_t_slurp() {
  REPLY=
  [[ -r $1 ]] && IFS= read -r -d '' REPLY < $1
  return 0
}

test_theme_syntax() {
  assert_ok test -f $THEME
  capture_err zsh -f -n -- $THEME
  local -i rc=$?
  assert_eq "$rc" 0 "zsh -n zsh/emjay.zsh-theme: status (stderr: $REPLY)"
}

test_install_syntax() {
  assert_ok test -f $INSTALL
  capture_err sh -n $INSTALL
  local -i rc=$?
  assert_eq "$rc" 0 "sh -n install.sh: status (stderr: $REPLY)"
}

test_no_gnu_only_flags() {
  local f p
  local -a pats=('stat -c' 'date -d' 'sed -r' 'sed -i' 'readlink -f' 'grep -P') lines hits
  for f in $THEME $INSTALL; do
    if [[ ! -r $f ]]; then
      _t_fail "${f:t}" "a readable file" "missing"
      continue
    fi
    lines=("${(@f)$(<$f)}")
    for p in $pats; do
      # word boundary on the left, so e.g. "zstat -c" would not count as "stat -c"
      hits=("${(@M)lines:#(|*[^[:alnum:]_])${p}*}")
      assert_eq "${hits[1]-}" "" "${f:t} must not contain '$p'; first offending line"
    done
  done
}

test_no_subshell_on_sync_path() {
  local -a fns=(
    _emjay_precmd _emjay_preexec _emjay_status_update _emjay_glyphs_select _emjay_glyphs_load
    _emjay_fmt_duration _emjay_fmt_status _emjay_kube_update _emjay_kube_files
    _emjay_kube_cache_key _emjay_kube_load _emjay_kube_parse_file _emjay_yaml_unquote
    _emjay_kube_shorten _emjay_kube_is_prod _emjay_render_dir _emjay_render_git
    _emjay_render_kube _emjay_render_status _emjay_assemble _emjay_git_update
    _emjay_git_find_root
  )
  local f body rest bad
  for f in $fns; do
    if (( ! $+functions[$f] )); then
      _t_fail "$f" "a defined function" "undefined"
      continue
    fi
    body=${functions[$f]}
    assert_not_contains "$body" '`' "$f: body contains a backtick"
    rest=$body bad=
    while [[ $rest == *'$('* ]]; do
      rest=${rest#*'$('}
      # $(( ... )) is arithmetic, not a subshell; DESIGN 3.7 relies on it
      [[ $rest == '('* ]] && continue
      if [[ $rest != [[:space:]]#'<'* ]]; then
        bad='$('${rest[1,40]}
        break
      fi
    done
    assert_eq "$bad" "" "$f: every \$( must be \$(<file); first offender"
  done
}

test_source_silent_outside_omz() {
  zsh -f -c 'source $1' _ $THEME > $TT/out 2> $TT/err
  _t_slurp $TT/out
  assert_eq "$REPLY" "" "stdout of 'zsh -f -c source theme'"
  _t_slurp $TT/err
  assert_eq "$REPLY" "" "stderr of 'zsh -f -c source theme'"
}

test_namespace_hygiene() {
  zsh -f -c '
    typeset -a before after
    before=(${(k)functions})
    source $1
    after=(${(k)functions})
    print -rl -- ${after:|before}
  ' _ $THEME > $TT/new 2> $TT/err
  local -a new bad
  new=(${(f)"$(<$TT/new)"})
  assert_nonempty "${(@M)new:#_emjay_precmd}" "new functions after sourcing include _emjay_precmd"
  bad=(${new:#_emjay_*})
  # add-zsh-hook is zsh's own function, autoloaded by the theme's registration
  # code (DESIGN 3.7), so sourcing necessarily adds it.
  bad=(${bad:#add-zsh-hook})
  assert_eq "${(j: :)bad}" "" "functions added by sourcing the theme outside _emjay_*"
}

run_tests
