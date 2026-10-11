# tests/test_glyphs.zsh: glyph mode selection and the three glyph tables.
source ${0:A:h}/lib.zsh

# Expected tables, DESIGN section 3.2. All values quoted: several are glob or
# redirection characters.
typeset -gA want_unicode=(
  branch   $'\u2387'  detached $'\u27a6'  ahead     $'\u2191'  behind $'\u2193'
  staged   $'\u25cf'  modified $'\u271a'  untracked $'\u2026'  stash  $'\u2691'
  conflict $'\u2716'  clean    $'\u2714'  kube      $'\u2388'  error  $'\u2718'
  took     'took'     prompt   $'\u276f'
)
typeset -gA want_nerd=(
  branch   $'\ue0a0'  detached $'\uf417'  ahead     $'\uf062'  behind $'\uf063'
  staged   $'\uf055'  modified $'\uf06a'  untracked $'\uf059'  stash  $'\uf01c'
  conflict $'\uf071'  clean    $'\uf00c'  kube      $'\U000f10fe' error $'\uf00d'
  took     $'\uf252'  prompt   $'\u276f'
)
typeset -gA want_ascii=(
  branch   'git'  detached '@'   ahead     '^'  behind 'v'
  staged   '+'    modified '*'   untracked '?'  stash  '$'
  conflict '!'    clean    'ok'  kube      'k8s' error 'x'
  took     'took' prompt   '>'
)

# _t_check_glyphs <mode> <name of expected assoc>
_t_check_glyphs() {
  local mode=$1 slot
  local -A want
  want=("${(@kvP)2}")
  assert_eq "$_emjay_glyph_mode" "$mode" "_emjay_glyph_mode"
  local -a have_slots want_slots
  have_slots=(${(ok)_emjay_glyph})
  want_slots=(${(ok)want})
  assert_eq "$have_slots" "$want_slots" "$mode: sorted set of glyph slots"
  for slot in ${(ok)want}; do
    assert_eq "${_emjay_glyph[$slot]-<unset>}" "$want[$slot]" "$mode glyph slot '$slot'"
  done
}

test_default_unicode() {
  _emjay_glyphs_select
  _t_check_glyphs unicode want_unicode
}

test_nerd_mode() {
  EMJAY_NERD_FONT=1
  _emjay_glyphs_select
  _t_check_glyphs nerd want_nerd
}

test_ascii_forced() {
  EMJAY_ASCII=1
  _emjay_glyphs_select
  _t_check_glyphs ascii want_ascii
}

test_ascii_auto_c_locale() {
  LC_ALL=C
  _emjay_glyphs_select
  assert_eq "$_emjay_glyph_mode" ascii "mode with LC_ALL=C"
  assert_eq "${_emjay_glyph[prompt]}" '>' "prompt glyph with LC_ALL=C"
}

test_ascii_zero_overrides_locale() {
  LC_ALL=C EMJAY_ASCII=0
  _emjay_glyphs_select
  assert_eq "$_emjay_glyph_mode" unicode "mode with LC_ALL=C EMJAY_ASCII=0"
}

test_nerd_beats_ascii() {
  EMJAY_NERD_FONT=1 EMJAY_ASCII=1
  _emjay_glyphs_select
  assert_eq "$_emjay_glyph_mode" nerd "mode with EMJAY_NERD_FONT=1 EMJAY_ASCII=1"
}

test_switch_back_without_resource() {
  EMJAY_NERD_FONT=1
  _emjay_glyphs_select
  assert_eq "$_emjay_glyph_mode" nerd "mode after EMJAY_NERD_FONT=1"
  unset EMJAY_NERD_FONT
  _emjay_glyphs_select
  assert_eq "$_emjay_glyph_mode" unicode "mode after unset EMJAY_NERD_FONT"
  assert_eq "${_emjay_glyph[branch]}" "$want_unicode[branch]" "branch glyph after switching back"
}

test_render_git_nerd() {
  EMJAY_NERD_FONT=1
  _emjay_glyphs_select
  _emjay_git=(repo 1 bare 0 branch main detached 0)
  _emjay_render_git
  seg_text git
  assert_eq "$REPLY" $'\ue0a0 main \uf00c' "nerd git segment for clean main"
}

test_ascii_when_codeset_not_utf8() {             # m2: effective codeset, not the variable's spelling
  zmodload zsh/langinfo 2>/dev/null
  if (( ! ${+langinfo} )); then
    print -r -- "  # skipped: zsh/langinfo unavailable"
    return 0
  fi
  LC_ALL=C
  # No such locale anywhere: setlocale fails and the shell stays in C (ASCII),
  # although the name says UTF-8. zsh then edits the line as ASCII too.
  capture_err eval 'LC_ALL=xx_XX.UTF-8'
  assert_eq "$REPLY" "" "stderr of setting LC_ALL to a locale that does not exist"
  _emjay_glyphs_select
  assert_eq "$_emjay_glyph_mode" ascii "mode with LC_ALL=xx_XX.UTF-8 (codeset ${langinfo[CODESET]})"
  EMJAY_ASCII=0
  _emjay_glyphs_select
  assert_eq "$_emjay_glyph_mode" unicode "EMJAY_ASCII=0 still forces Unicode"
  assert_eq "${_emjay_glyph[branch]}" "$want_unicode[branch]" "branch glyph loaded under a non-UTF-8 codeset"
}

test_precmd_applies_mode() {
  EMJAY_NERD_FONT=1
  _emjay_precmd
  assert_eq "$_emjay_glyph_mode" nerd "mode after _emjay_precmd with EMJAY_NERD_FONT=1"
}

run_tests
