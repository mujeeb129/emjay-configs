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

# ------------------------------------------------------------ review fixes

zmodload zsh/zselect

# _t_wait_ready <label>: block (up to 10 s) until the pending worker's pipe is
# readable, i.e. it has written its payload, but leave it undrained.
_t_wait_ready() {
  local -a reply
  if (( _emjay_git_fd <= 0 )); then
    _t_fail "$1: wait needs a pending request" "_emjay_git_fd > 0" "$_emjay_git_fd"
    return 1
  fi
  zselect -t 1000 -r $_emjay_git_fd || _t_fail "$1: worker pipe readable within 10 s" readable timeout
}

test_cancel_spares_finished_worker_pid() {               # M1
  _t_async_setup
  cd $TT/A
  _emjay_precmd
  _t_wait_ready "A"
  # The worker has written its payload and is gone; pretend its pid was reused
  # by an unrelated process (not our child, so a TERM would really end it).
  local decoy
  decoy=$( sleep 30 >/dev/null 2>&1 & print -r -- $! )
  assert_match "$decoy" '<->' "decoy pid"
  _emjay_git_pid=$decoy
  _emjay_git_cancel
  sleep 0.3
  kill -0 $decoy 2>/dev/null
  assert_eq "$?" 0 "a process holding the finished worker's (reused) pid survives _emjay_git_cancel"
  kill $decoy 2>/dev/null
  return 0
}

test_cancel_applies_finished_result_same_repo() {        # M1: "cd slowrepo; long-command"
  _t_async_setup
  cd $TT/A
  _emjay_precmd
  _t_seg_is "" "A, first precmd"
  _t_wait_ready "A"
  _emjay_precmd           # the callback never ran (a command was running)
  _t_seg_is "$ALPHA" "A, next precmd shows the finished result at once"
  _t_pending "A, next precmd"
  _t_drain "A refresh"
  _t_seg_is "$ALPHA" "A after the refresh"
}

test_cancel_discards_finished_result_other_repo() {      # M1
  _t_async_setup
  cd $TT/A
  _emjay_precmd
  _t_wait_ready "A"
  builtin cd -q $TT/B     # -q: no chpwd hook, so precmd is first to see the move
  _emjay_precmd
  _t_seg_is "" "B, with A's finished result unread"
  assert_not_contains "$_emjay_prompt" alpha "B: _emjay_prompt"
  _t_drain "B"
  _t_seg_is "$BETA" "B drained"
}

test_worker_pid_line_not_evaluated() {                   # M1: pid read into a validated scalar
  _t_async_setup
  cd $TT/A
  _emjay_git_worker() {
    print -r -- "path[\$(: > $TT/pwned)]"
    print -r -- "$1"$'\nrepo=0'
  }
  _emjay_precmd
  assert_eq "$_emjay_git_pid" 0 "_emjay_git_pid after a non-numeric pid line"
  _t_drain "A"
  assert_fail test -e $TT/pwned
}

test_callback_drops_result_after_cd_without_precmd() {   # m1: a widget ran cd + reset-prompt
  _t_async_setup
  cd $TT/A
  _emjay_precmd
  _t_drain "A"
  _emjay_precmd           # refresh for A pending
  builtin cd -q $TT/B     # no precmd, and -q skips chpwd as well
  _t_drain "A's late result while in B"
  _t_seg_is "" "B after A's late result"
  assert_eq "${#_emjay_git}" 0 "\${#_emjay_git} after A's late result arrived in B"
  assert_not_contains "$_emjay_prompt" alpha "_emjay_prompt after A's late result arrived in B"
}

test_chpwd_clears_git_segment() {                        # m1: chpwd hook
  _t_async_setup
  cd $TT/A
  _emjay_precmd
  _t_drain "A"
  _emjay_precmd           # refresh for A pending
  cd $TT/B                # chpwd only, no precmd
  _t_seg_is "" "right after cd A -> B (chpwd, no precmd)"
  assert_not_contains "$_emjay_prompt" alpha "_emjay_prompt right after cd A -> B"
  assert_eq "$_emjay_git_fd" 0 "A's pending request cancelled by chpwd"
  assert_eq "$_emjay_git_key" "$TT/B" "_emjay_git_key after chpwd"
  cd $TT/A
  _emjay_precmd
  _t_drain "A again"
  cd $TT/A/sub            # same repo: chpwd keeps the segment
  _t_seg_is "$ALPHA" "after cd A -> A/sub"
}

test_zle_busy_decision() {                               # m3: when to defer the redraw
  local w
  for w in expand-or-complete complete-word menu-complete menu-select menu-expand-or-complete \
           reverse-menu-complete history-search-backward; do
    ( LASTWIDGET=$w ISEARCHMATCH_ACTIVE=0; _emjay_zle_busy )
    assert_eq "$?" 0 "_emjay_zle_busy with LASTWIDGET=$w"
  done
  # an incremental search that has ended no longer blocks the redraw
  for w in self-insert accept-line vi-cmd-mode backward-delete-char zle-line-init \
           history-incremental-search-backward ''; do
    ( LASTWIDGET=$w ISEARCHMATCH_ACTIVE=0; _emjay_zle_busy )
    assert_eq "$?" 1 "_emjay_zle_busy with LASTWIDGET='$w'"
  done
  ( LASTWIDGET=zle-line-init ISEARCHMATCH_ACTIVE=1; _emjay_zle_busy )
  assert_eq "$?" 0 "_emjay_zle_busy with ISEARCHMATCH_ACTIVE=1"
}

test_callback_defers_redraw_when_busy() {                # m3: data applied, redraw deferred
  _t_async_setup
  cd $TT/A
  _emjay_precmd
  LASTWIDGET=expand-or-complete
  _t_drain "A during completion"
  _t_seg_is "$ALPHA" "result applied during completion"
  assert_eq "$_emjay_redraw_pending" 1 "_emjay_redraw_pending after a callback during completion"
  _emjay_line_pre_redraw  # still completing: keep waiting
  assert_eq "$_emjay_redraw_pending" 1 "pre-redraw hook while still completing"
  LASTWIDGET=self-insert
  _emjay_line_pre_redraw  # completion over: the hook does the deferred reset-prompt
  assert_eq "$_emjay_redraw_pending" 0 "pre-redraw hook after completion ended"
  cd $TT/B
  _emjay_precmd
  _t_drain "B while typing"
  assert_eq "$_emjay_redraw_pending" 0 "no deferral while typing"
  _emjay_redraw_pending=1
  _emjay_precmd
  assert_eq "$_emjay_redraw_pending" 0 "precmd clears a pending redraw"
}

test_cancelled_worker_leaves_no_git_running() {          # m8: no job control in this shell
  _t_async_setup
  [[ -o monitor ]] && unsetopt monitor
  local real=$commands[git]
  mkdir -p $TT/slowbin
  print -r -- "#!/bin/sh
case \"\$*\" in *status*) echo \$\$ >> '$TT/status.pids'; exec sleep 30 ;; esac
exec '$real' \"\$@\"" > $TT/slowbin/git
  chmod +x $TT/slowbin/git
  path=($TT/slowbin $path)
  rehash
  cd $TT/A
  _emjay_precmd
  local -i i
  for (( i = 0; i < 200; i++ )); do [[ -s $TT/status.pids ]] && break; sleep 0.05; done
  assert_ok test -s $TT/status.pids
  local d
  for d in B A B A; do
    cd $TT/$d
    _emjay_precmd
    sleep 0.2
  done
  _emjay_git_cancel
  sleep 0.5
  local p
  local -a pids alive
  pids=(${(f)"$(<$TT/status.pids)"})
  for p in $pids; do kill -0 $p 2>/dev/null && alive+=($p); done
  assert_eq "${alive[*]}" "" "slow 'git status' pids (of ${#pids}) still running after their workers were cancelled"
  (( $#alive )) && kill $alive 2>/dev/null
  return 0
}

run_tests
