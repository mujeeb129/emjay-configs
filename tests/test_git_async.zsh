# tests/test_git_async.zsh: the zle -F worker, run without ZLE. zle -F is
# inert in a script, so each request is drained by calling the callback.
source ${0:A:h}/lib.zsh

_t_async_setup() {
  assert_ok mkrepo $TT/A alpha
  assert_ok mkrepo $TT/B beta
  mkdir -p $TT/A/sub $TT/plain
  EMJAY_GIT_ASYNC=1
}

# _t_drain <label>: block until the pending worker finishes and apply it.
_t_drain() {
  if (( _emjay_git_fd > 0 )); then
    _emjay_git_callback $_emjay_git_fd
  else
    _t_fail "$1: drain needs a pending request" "_emjay_git_fd > 0" "$_emjay_git_fd"
  fi
}

# _t_seg_is <expected stripped git segment> <label>
_t_seg_is() {
  seg_text git
  assert_eq "$REPLY" "$1" "$2: git segment"
}

# _t_pending <label>: a worker is outstanding.
_t_pending() {
  assert_eq "$(( _emjay_git_fd > 0 ))" 1 "$1: _emjay_git_fd ($_emjay_git_fd) > 0"
}

typeset -g ALPHA="${UG[branch]} alpha ${UG[clean]}" BETA="${UG[branch]} beta ${UG[clean]}"

test_async_fills_after_callback() {
  _t_async_setup
  cd $TT/A
  _emjay_precmd
  _t_pending "precmd in A"
  _t_seg_is "" "precmd in A, before the callback"
  _t_drain "A"
  _t_seg_is "$ALPHA" "A after the callback"
  assert_eq "$_emjay_git_fd" 0 "A after the callback: _emjay_git_fd"
}

test_async_cd_clears_immediately() {
  _t_async_setup
  cd $TT/A
  _emjay_precmd
  _t_drain "A"
  _t_seg_is "$ALPHA" "A drained"
  cd $TT/B
  _emjay_precmd
  _t_seg_is "" "right after cd A -> B"
  assert_not_contains "$_emjay_prompt" alpha "right after cd A -> B: _emjay_prompt"
  _t_drain "B"
  _t_seg_is "$BETA" "B drained"
}

test_async_pending_cancelled() {
  _t_async_setup
  cd $TT/A
  _emjay_precmd
  local -i id=$_emjay_git_reqid
  cd $TT/B
  _emjay_precmd
  assert_eq "$_emjay_git_reqid" "$(( id + 1 ))" "reqid after A (pending) then B"
  _t_drain "B"
  _t_seg_is "$BETA" "B drained after cancelling A"
  _emjay_git_apply "$id"$'\nrepo=1\nbranch=alpha\nbare=0\ndetached=0'
  assert_eq "$?" 1 "late payload with A's reqid $id: _emjay_git_apply status"
  _t_seg_is "$BETA" "after the late A payload was offered"
}

test_async_same_repo_keeps_info() {
  _t_async_setup
  cd $TT/A
  _emjay_precmd
  _t_drain "A"
  cd $TT/A/sub
  _emjay_precmd
  _t_pending "precmd in A/sub"
  _t_seg_is "$ALPHA" "A/sub while the refresh is pending"
  _t_drain "A/sub"
  _t_seg_is "$ALPHA" "A/sub drained"
}

test_async_nonrepo_no_worker() {
  _t_async_setup
  cd $TT/A
  _emjay_precmd
  _t_drain "A"
  cd $TT/plain
  _emjay_precmd
  _t_seg_is "" "plain after A"
  assert_eq "$_emjay_git_fd" 0 "plain after A: _emjay_git_fd (no worker)"
}

test_worker_wire_format() {
  _t_async_setup
  local fd pid rest
  exec {fd}< <(_emjay_git_worker 42 $TT/A)
  read -u $fd pid
  IFS= read -r -u $fd -d '' rest
  exec {fd}<&-
  assert_match "$pid" '<->' "worker 42 on A: pid line"
  local -a lines
  lines=("${(@f)rest}")
  assert_eq "$lines[1]" 42 "worker 42 on A: payload line 1"
  assert_contains $'\n'"$rest"$'\n' $'\nrepo=1\n' "worker 42 on A: payload has the line repo=1"
  assert_contains $'\n'"$rest"$'\n' $'\nbranch=alpha\n' "worker 42 on A: payload has the line branch=alpha"
}

test_worker_nonrepo_payload() {
  _t_async_setup
  local fd pid rest
  exec {fd}< <(_emjay_git_worker 7 $TT/plain)
  read -u $fd pid
  IFS= read -r -u $fd -d '' rest
  exec {fd}<&-
  assert_match "$pid" '<->' "worker 7 on plain: pid line"
  local -a lines
  lines=(${(f)rest})
  assert_eq "${(j:|:)lines}" '7|repo=0' "worker 7 on plain: payload lines joined with |"
}

test_reqid_increments() {
  _t_async_setup
  cd $TT/A
  local -i start=$_emjay_git_reqid k
  for k in 1 2 3; do
    _emjay_precmd
    assert_eq "$_emjay_git_reqid" "$(( start + k ))" "reqid after precmd #$k in A"
    _t_drain "A #$k"
    _t_seg_is "$ALPHA" "A after drain #$k"
  done
}

run_tests
