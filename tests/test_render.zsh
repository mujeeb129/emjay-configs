# tests/test_render.zsh: segment renderers, line assembly and the precmd hook.
source ${0:A:h}/lib.zsh

# _t_clear_segs: every raw segment empty.
_t_clear_segs() {
  _emjay_seg_dir= _emjay_seg_git= _emjay_seg_kube= _emjay_seg_status= _emjay_seg_took= _emjay_seg_char=
}

# _t_seg <name> <expected stripped> <label>
_t_seg() {
  seg_text $1
  assert_eq "$REPLY" "$2" "$3: $1 segment"
}

# _t_took <duration> <expected took text> <label>
_t_took() {
  _emjay_cmd_duration=$1
  _emjay_render_status
  _t_seg took "$2" "$3"
}

test_requirements_line() {
  mkdir -p $HOME/projects/api
  cd $HOME/projects/api
  _emjay_git=(repo 1 bare 0 branch main detached 0 ahead 2 behind 1 staged 3 modified 1
              untracked 2 stash 1 conflicts 1 op 'REBASE 2/5')
  _emjay_kube=(ctx eks-prod ns payments)
  _emjay_last_status=1 _emjay_cmd_duration=4
  _emjay_render_dir
  _emjay_render_git
  _emjay_render_kube
  _emjay_render_status
  _emjay_assemble
  local want
  want="~/projects/api  ${UG[branch]} main ${UG[ahead]}2 ${UG[behind]}1 ${UG[staged]}3"
  want+=" ${UG[modified]}1 ${UG[untracked]}2 ${UG[stash]}1 ${UG[conflict]}1 REBASE 2/5"
  want+="  ${UG[kube]} eks-prod/payments  ${UG[error]} 1  took 4s"$'\n'"${UG[prompt]} "
  seg_text prompt
  assert_eq "$REPLY" "$want" "requirements example: full stripped prompt"
}

test_assemble_skips_empty() {
  _t_clear_segs
  _emjay_seg_dir='~/p'
  _emjay_seg_took='%F{178}took 4s%f'
  _emjay_seg_char="%F{76}${UG[prompt]}%f"
  _emjay_assemble
  _t_seg line1 '~/p  took 4s' "only dir and took set"
}

test_assemble_only_char() {
  _t_clear_segs
  _emjay_seg_char="%F{76}${UG[prompt]}%f"
  _emjay_assemble
  _t_seg prompt "${UG[prompt]} " "only char set"
  assert_not_contains "$_emjay_prompt" $'\n' "only char set: raw _emjay_prompt has no newline"
}

test_separator_override() {
  EMJAY_SEPARATOR=' | '
  _t_clear_segs
  _emjay_seg_dir='~/p'
  _emjay_seg_kube="%F{33}${UG[kube]} a/b%f"
  _emjay_seg_took='%F{178}took 4s%f'
  _emjay_seg_char="%F{76}${UG[prompt]}%f"
  _emjay_assemble
  _t_seg line1 "~/p | ${UG[kube]} a/b | took 4s" "EMJAY_SEPARATOR=' | '"
}

test_dir_home_abbrev() {
  mkdir -p $HOME/projects/api
  cd $HOME/projects/api
  _emjay_render_dir
  _t_seg dir '~/projects/api' "cwd \$HOME/projects/api"
}

test_dir_toggle_off() {
  EMJAY_SHOW_DIR=0
  _emjay_seg_dir=junk
  _emjay_render_dir
  assert_eq "$_emjay_seg_dir" "" "EMJAY_SHOW_DIR=0: raw _emjay_seg_dir"
}

test_status_render_error() {
  _emjay_last_status=1 _emjay_cmd_duration=0
  _emjay_render_status
  _t_seg status "${UG[error]} 1" "last status 1"
  _t_seg took "" "last status 1, duration 0"
  assert_contains "$_emjay_seg_char" '%F{196}' "last status 1: raw char uses PROMPT_ERR colour"
}

test_status_render_signal() {
  _emjay_last_status=130 _emjay_cmd_duration=0
  _emjay_render_status
  _t_seg status "${UG[error]} INT" "last status 130"
}

test_status_render_success() {
  _emjay_last_status=0 _emjay_cmd_duration=0
  _emjay_render_status
  _t_seg status "" "last status 0"
  _t_seg char "${UG[prompt]}" "last status 0"
  assert_contains "$_emjay_seg_char" '%F{76}' "last status 0: raw char uses PROMPT_OK colour"
}

test_took_threshold() {
  _emjay_last_status=0
  _t_took 3 '' "default threshold, duration 3"
  _t_took 4 'took 4s' "default threshold, duration 4"
  EMJAY_CMD_MAX_DURATION=10
  _t_took 5 '' "EMJAY_CMD_MAX_DURATION=10, duration 5"
  EMJAY_CMD_MAX_DURATION=x
  _t_took 4 'took 4s' "EMJAY_CMD_MAX_DURATION=x (falls back to 3), duration 4"
  EMJAY_CMD_MAX_DURATION=0
  _t_took 1 'took 1s' "EMJAY_CMD_MAX_DURATION=0, duration 1"
}

test_status_toggle_off() {
  EMJAY_SHOW_STATUS=0
  _emjay_last_status=1 _emjay_cmd_duration=0
  _emjay_render_status
  _t_seg status "" "EMJAY_SHOW_STATUS=0, last status 1"
  assert_contains "$_emjay_seg_char" '%F{196}' "EMJAY_SHOW_STATUS=0, last status 1: raw char still red"
}

test_duration_toggle_off() {
  EMJAY_SHOW_DURATION=0
  _emjay_last_status=0
  _t_took 99 '' "EMJAY_SHOW_DURATION=0, duration 99"
}

test_precmd_nonrepo_minimal() {
  mkdir -p $TT/plain
  cd $TT/plain
  _emjay_precmd
  _t_seg prompt "${(%):-%~}"$'\n'"${UG[prompt]} " "precmd in plain dir, no kubeconfig"
}

test_precmd_failure_then_empty_enter() {
  _emjay_preexec
  false
  _emjay_precmd
  _t_seg status "${UG[error]} 1" "precmd after 'false'"
  _emjay_precmd
  _t_seg status "" "precmd after an empty Enter"
  assert_contains "$_emjay_seg_char" '%F{76}' "precmd after an empty Enter: raw char is green"
}

test_precmd_took() {
  _emjay_preexec
  _emjay_cmd_start=$(( EPOCHREALTIME - 5 ))
  true
  _emjay_precmd
  _t_seg took 'took 5s' "precmd 5s after preexec"
}

test_precmd_works_with_empty_path() {
  kube_fixture basic
  assert_ok mkdir -p $HOME/.kube $TT/plain $TT/emptybin
  assert_ok cp -- $REPLY $HOME/.kube/config
  cd $TT/plain
  PATH=$TT/emptybin
  capture_err _emjay_precmd
  assert_eq "$REPLY" "" "precmd with empty PATH: stderr"
  _t_seg kube "${UG[kube]} dev/team-a" "precmd with empty PATH"
}

test_prompt_wiring() {
  source $EMJAY_ROOT/zsh/emjay.zsh-theme
  assert_eq "$PROMPT" '${_emjay_prompt}' "PROMPT after sourcing the theme twice"
  [[ -o prompt_subst ]]
  assert_eq "$?" 0 "[[ -o prompt_subst ]] after sourcing the theme twice: status"
  assert_eq "${#${(@M)precmd_functions:#_emjay_precmd}}" 1 "times _emjay_precmd is in precmd_functions (${precmd_functions[*]})"
  assert_eq "${#${(@M)preexec_functions:#_emjay_preexec}}" 1 "times _emjay_preexec is in preexec_functions (${preexec_functions[*]})"
}

test_perf_nonrepo() {
  if [[ ${EMJAY_TEST_SKIP_PERF-} == 1 ]]; then
    print -r -- "  # skipped: EMJAY_TEST_SKIP_PERF=1"
    return 0
  fi
  kube_fixture basic
  assert_ok mkdir -p $HOME/.kube $TT/plain
  assert_ok cp -- $REPLY $HOME/.kube/config
  cd $TT/plain
  _emjay_precmd     # warm-up: parses the kubeconfig once
  local -F t0=$EPOCHREALTIME
  local -i i
  for (( i = 0; i < 50; i++ )); do _emjay_precmd; done
  local -F avg=$(( (EPOCHREALTIME - t0) * 1000.0 / 50 ))
  local shown
  printf -v shown '%.3f' $avg
  assert_eq "$(( avg < 10 ))" 1 "average non-repo precmd ${shown}ms over 50 runs, budget 10ms"
}

run_tests
