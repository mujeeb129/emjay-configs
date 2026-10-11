# tests/test_git_repo.zsh: real git repositories, synchronous collection
# (lib.zsh sets EMJAY_GIT_ASYNC=0).
source ${0:A:h}/lib.zsh

# _t_q <cmd...>: run quietly (setup commands; git prints progress/noise).
_t_q() { "$@" >/dev/null 2>&1 }

# _t_commit <file> <content> <msg>: write, add and commit in $PWD.
_t_commit() {
  print -r -- "$2" > $1 &&
    git add -- $1 &&
    git commit -qm "$3"
}

# _t_sha7 [rev=HEAD] -> REPLY. (DESIGN's ${$(git rev-parse HEAD)[1,7]} slices
# words, not characters, in zsh, so take the string first.)
_t_sha7() {
  local h
  h=$(git rev-parse ${1:-HEAD})
  REPLY=${h[1,7]}
}

# _t_git_expect <expected stripped git segment> <label>: _emjay_precmd, compare.
_t_git_expect() {
  _emjay_precmd
  seg_text git
  assert_eq "$REPLY" "$1" "$2: git segment"
}

# _t_key_is <expected path> <label>: compare _emjay_git_key with :A.
_t_key_is() {
  assert_eq "${_emjay_git_key:+${_emjay_git_key:A}}" "${1:A}" "$2: _emjay_git_key (compared with :A)"
}

# Shared by the merge and cherry-pick tests: main and other both rewrite a.txt
# from "a", main to "main" and other to "other", so applying other conflicts.
_t_conflict_setup() {
  assert_ok mkrepo $TT/r
  cd $TT/r
  assert_ok git checkout -qb other
  print -r -- other > a.txt
  assert_ok git commit -qam other
  assert_ok git checkout -q main
  print -r -- main > a.txt
  assert_ok git commit -qam main
}

test_nonrepo() {
  mkdir -p $TT/plain
  cd $TT/plain
  _emjay_precmd
  assert_eq "$_emjay_seg_git" "" "non-repo: raw _emjay_seg_git"
  assert_eq "$_emjay_git_key" "" "non-repo: _emjay_git_key"
  assert_eq "${#_emjay_git}" 0 "non-repo: \${#_emjay_git}"
}

test_fresh_no_commits() {
  assert_ok mkrepo_empty $TT/r
  cd $TT/r
  _t_git_expect "${UG[branch]} main ${UG[clean]}" "fresh repo, no commits"
  assert_eq "${_emjay_git[oid]-<unset>}" "" "fresh repo: _emjay_git[oid]"
}

test_fresh_untracked() {
  assert_ok mkrepo_empty $TT/r
  cd $TT/r
  : > u
  _t_git_expect "${UG[branch]} main ${UG[untracked]}1" "fresh repo with untracked u"
}

test_clean_no_upstream() {
  assert_ok mkrepo $TT/r
  cd $TT/r
  _t_git_expect "${UG[branch]} main ${UG[clean]}" "clean repo without upstream"
  assert_eq "${_emjay_git[upstream]-<unset>}" "" "clean repo: _emjay_git[upstream]"
}

test_dirty_counts() {
  assert_ok mkrepo $TT/r
  cd $TT/r
  print -r -- b > b.txt
  assert_ok git add b.txt
  print -r -- more >> a.txt
  : > u1
  : > u2
  _t_git_expect "${UG[branch]} main ${UG[staged]}1 ${UG[modified]}1 ${UG[untracked]}2" "staged b, modified a, untracked u1 u2"
}

test_ahead_behind() {
  assert_ok mkrepo $TT/r
  cd $TT/r
  assert_ok git checkout -qb feature --track main
  assert_ok _t_commit f1 1 f1
  assert_ok _t_commit f2 2 f2
  assert_ok git checkout -q main
  assert_ok _t_commit m1 1 m1
  assert_ok git checkout -q feature
  _t_git_expect "${UG[branch]} feature ${UG[clean]} ${UG[ahead]}2 ${UG[behind]}1" "feature tracking main, 2 ahead 1 behind"
  assert_eq "${_emjay_git[upstream]-<unset>}" main "feature tracking main: _emjay_git[upstream]"
}

test_stash() {
  assert_ok mkrepo $TT/r
  cd $TT/r
  print -r -- changed > a.txt
  assert_ok git stash -q
  _t_git_expect "${UG[branch]} main ${UG[clean]} ${UG[stash]}1" "one stash entry"
}

test_detached() {
  assert_ok mkrepo $TT/r
  cd $TT/r
  assert_ok git checkout -q --detach
  _t_sha7
  _t_git_expect "${UG[detached]} $REPLY ${UG[clean]}" "detached HEAD"
  assert_eq "${_emjay_git[detached]-<unset>}" 1 "detached HEAD: _emjay_git[detached]"
}

test_merge_conflict() {
  _t_conflict_setup
  assert_fail _t_q git merge other
  _t_git_expect "${UG[branch]} main ${UG[conflict]}1 MERGING" "merge conflict on a.txt"
}

test_cherry_pick_conflict() {
  _t_conflict_setup
  assert_fail _t_q git cherry-pick other
  _t_git_expect "${UG[branch]} main ${UG[conflict]}1 CHERRY-PICKING" "cherry-pick conflict on a.txt"
}

test_rebase_conflict() {
  assert_ok mkrepo $TT/r
  cd $TT/r
  assert_ok _t_commit f base base
  assert_ok git checkout -qb topic
  assert_ok _t_commit f t1 t1
  assert_ok _t_commit g g g
  assert_ok git checkout -q main
  assert_ok _t_commit f m1 m1
  assert_ok git checkout -q topic
  # the first of two picks conflicts on f; HEAD is detached at main, but the
  # prompt names the branch being rebased (rebase-merge/head-name), as in the
  # requirements mock "main ... REBASE 2/5"
  assert_fail _t_q git rebase main
  _t_git_expect "${UG[branch]} topic ${UG[conflict]}1 REBASE 1/2" "rebase of topic onto main stopped at 1/2"
  assert_eq "${_emjay_git[detached]-<unset>}" 0 "during the rebase: _emjay_git[detached]"
  assert_match "$_emjay_seg_git" '%F{178}*' "during the rebase: head uses the dirty colour"
}

test_rebase_detached_start_keeps_sha() {
  # rebasing a detached HEAD has no branch to name: head-name is "detached HEAD"
  assert_ok mkrepo $TT/r
  cd $TT/r
  assert_ok _t_commit f base base
  assert_ok git checkout -qb topic
  assert_ok _t_commit f t1 t1
  assert_ok git checkout -q main
  assert_ok _t_commit f m1 m1
  assert_ok git checkout -q --detach topic
  assert_fail _t_q git rebase main
  _t_sha7 main
  _t_git_expect "${UG[detached]} $REPLY ${UG[conflict]}1 REBASE 1/1" "rebase of a detached HEAD onto main"
}

test_bisect() {
  assert_ok mkrepo $TT/r
  cd $TT/r
  assert_ok _t_q git bisect start
  _t_git_expect "${UG[branch]} main ${UG[clean]} BISECTING" "after git bisect start"
}

test_inside_dot_git() {
  assert_ok mkrepo $TT/r
  cd $TT/r/.git
  _t_git_expect "${UG[branch]} main" "inside r/.git"
  assert_eq "${_emjay_git[bare]-<unset>}" 1 "inside r/.git: _emjay_git[bare]"
  _t_key_is $TT/r/.git "inside r/.git"
  cd $TT/r/.git/refs
  _t_git_expect "${UG[branch]} main" "inside r/.git/refs"
  assert_eq "${_emjay_git[bare]-<unset>}" 1 "inside r/.git/refs: _emjay_git[bare]"
  _t_key_is $TT/r/.git "inside r/.git/refs"
}

test_worktree() {
  assert_ok mkrepo $TT/r
  assert_ok _t_q git -C $TT/r worktree add -q $TT/wt -b feature
  cd $TT/wt
  _t_git_expect "${UG[branch]} feature ${UG[clean]}" "linked worktree wt"
  local want=$TT/r/.git/worktrees/wt
  assert_eq "${_emjay_git[gitdir]:A}" "${want:A}" "linked worktree: _emjay_git[gitdir] (compared with :A)"
  _t_key_is $TT/wt "linked worktree"
}

test_submodule() {
  assert_ok mkrepo $TT/subsrc
  assert_ok mkrepo $TT/super
  assert_ok _t_q git -C $TT/super submodule add -q $TT/subsrc sub
  cd $TT/super/sub
  _t_git_expect "${UG[branch]} main ${UG[clean]}" "submodule super/sub"
  local want=$TT/super/.git/modules/sub
  assert_eq "${_emjay_git[gitdir]:A}" "${want:A}" "submodule: _emjay_git[gitdir] (compared with :A)"
  assert_ok git checkout -q --detach
  _t_sha7
  _t_git_expect "${UG[detached]} $REPLY ${UG[clean]}" "submodule after checkout --detach"
  cd $TT/super
  _t_git_expect "${UG[branch]} main ${UG[staged]}2" "superproject with staged .gitmodules and sub"
}

test_subdir_same_key() {
  assert_ok mkrepo $TT/r
  mkdir -p $TT/r/x/y
  cd $TT/r
  _emjay_precmd
  seg_text git
  local root=$REPLY
  assert_eq "$root" "${UG[branch]} main ${UG[clean]}" "repo root r: git segment"
  cd $TT/r/x/y
  _t_git_expect "$root" "subdir r/x/y"
  _t_key_is $TT/r "subdir r/x/y"
}

test_show_git_off() {
  assert_ok mkrepo $TT/r
  cd $TT/r
  _t_git_expect "${UG[branch]} main ${UG[clean]}" "before EMJAY_SHOW_GIT=0"
  EMJAY_SHOW_GIT=0
  _emjay_precmd
  assert_eq "$_emjay_seg_git" "" "EMJAY_SHOW_GIT=0: raw _emjay_seg_git"
  assert_eq "${#_emjay_git}" 0 "EMJAY_SHOW_GIT=0: \${#_emjay_git}"
}

test_git_missing() {
  assert_ok mkrepo $TT/r
  mkdir -p $TT/emptybin
  cd $TT/r
  _t_git_expect "${UG[branch]} main ${UG[clean]}" "before PATH without git"
  PATH=$TT/emptybin
  capture_err _emjay_precmd
  assert_eq "$REPLY" "" "PATH without git: stderr of _emjay_precmd"
  assert_eq "$_emjay_seg_git" "" "PATH without git: raw _emjay_seg_git"
}

test_branch_name_not_evaluated() {
  assert_ok mkrepo $TT/r
  cd $TT/r
  # DESIGN uses x$(:>pwned)%F, which git rejects (':' is not allowed in ref
  # names). x$(touch${IFS}pwned)%F is a valid ref but inert in zsh (no word
  # splitting: "command not found: touch \t\n..."), so it could not detect
  # evaluation. echo>pwned is a valid ref and does create the file.
  local br='x$(echo>pwned)%F'
  assert_ok git checkout -qb $br
  _emjay_precmd
  : ${(%%)PROMPT}
  assert_fail test -e $TT/r/pwned
  assert_fail test -e $TT/pwned
  seg_text git
  assert_eq "$REPLY" "${UG[branch]} $br ${UG[clean]}" "hostile branch name: git segment"
}

# ------------------------------------------------------------ review fixes

test_fsmonitor_hook_not_run() {                  # m5: repo-local hook command
  assert_ok mkrepo $TT/r
  print -r -- "#!/bin/sh
: > '$TT/pwned'" > $TT/hook.sh
  chmod +x $TT/hook.sh
  assert_ok git -C $TT/r config core.fsmonitor $TT/hook.sh
  cd $TT/r
  _t_git_expect "${UG[branch]} main ${UG[clean]}" "repo with a core.fsmonitor hook"
  assert_fail test -e $TT/pwned
  # control: plain git status does run the hook, so the check above is meaningful
  _t_q git status --porcelain=v2
  assert_ok test -e $TT/pwned
}

test_fsmonitor_boolean_kept() {                  # m5: builtin daemon (boolean) left alone
  assert_ok mkrepo $TT/r
  assert_ok git -C $TT/r config core.fsmonitor true
  local real=$commands[git]
  mkdir -p $TT/bin
  print -r -- "#!/bin/sh
printf '%s\n' \"\$*\" >> '$TT/args'
exec '$real' \"\$@\"" > $TT/bin/git
  chmod +x $TT/bin/git
  path=($TT/bin $path)
  rehash
  cd $TT/r
  _t_git_expect "${UG[branch]} main ${UG[clean]}" "repo with core.fsmonitor=true"
  local -a calls
  calls=(${(f)"$(<$TT/args)"})
  local st=${(M)calls:#*status --porcelain=v2*}
  assert_nonempty "$st" "the git status call"
  assert_not_contains "$st" core.fsmonitor=false "git status call when core.fsmonitor=true"
}

test_reftable_head() {                           # nit: reftable keeps a HEAD placeholder
  if ! _t_q git init -q --ref-format=reftable $TT/r; then
    print -r -- "  # skipped: this git has no reftable support"
    return 0
  fi
  assert_ok git -C $TT/r commit -q --allow-empty -m init
  cd $TT/r
  _t_git_expect "${UG[branch]} main ${UG[clean]}" "reftable work tree"
  cd $TT/r/.git
  _t_git_expect "${UG[branch]} main" "inside .git of a reftable repo"
  assert_ok git -C $TT/r checkout -q --detach
  _t_sha7 HEAD
  _t_git_expect "${UG[detached]} $REPLY" "inside .git of a reftable repo, detached"
  assert_ok _t_q git clone -q --bare $TT/r $TT/b.git
  cd $TT/b.git
  _t_git_expect "${UG[branch]} main" "bare clone"
}

run_tests
