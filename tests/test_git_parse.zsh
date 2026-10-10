# tests/test_git_parse.zsh: pure git functions (no git binary needed).
source ${0:A:h}/lib.zsh

# Appendix B porcelain v2 texts, one line per entry, no trailing newline
# (as returned by $(git status ...)).
typeset -ga B1_lines=(
  '# branch.oid 1234567890abcdef1234567890abcdef12345678'
  '# branch.head main'
  '# branch.upstream origin/main'
  '# branch.ab +0 -0'
)
typeset -ga B2_lines=(
  '# branch.oid 1234567890abcdef1234567890abcdef12345678'
  '# branch.head feature/x'
  '# branch.upstream origin/feature/x'
  '# branch.ab +2 -1'
  '# stash 1'
  '1 M. N... 100644 100644 100644 aaaa bbbb staged.txt'
  '1 A. N... 000000 100644 100644 0000 cccc new.txt'
  '1 MM N... 100644 100644 100644 aaaa bbbb both.txt'
  '1 .M N... 100644 100644 100644 aaaa aaaa mod.txt'
  '2 R. N... 100644 100644 100644 aaaa aaaa R100 new name.txt'$'\t''old name.txt'
  '1 .D N... 100644 100644 000000 aaaa aaaa deleted.txt'
  'u UU N... 100644 100644 100644 100644 aaaa bbbb cccc conflict.txt'
  '? untracked1'
  '? dir/'
  '! ignored.txt'
)
typeset -ga B3_lines=(
  '# branch.oid (initial)'
  '# branch.head main'
  '? a'
)
typeset -ga B4_lines=(
  '# branch.oid abcdef1234567890abcdef1234567890abcdef12'
  '# branch.head (detached)'
)
typeset -ga B5_lines=(
  '# branch.oid 1234567890abcdef1234567890abcdef12345678'
  '# branch.head main'
  '# branch.upstream origin/gone'
)
typeset -ga B6_lines=(
  '# branch.oid 1234567890abcdef1234567890abcdef12345678'
  '# branch.head main'
  '1 .M N... 100644 100644 100644 aaaa aaaa "we\"ird name.txt"'
  '? "sp ace.txt"'
)
typeset -g B1=${(pj:\n:)B1_lines} B2=${(pj:\n:)B2_lines} B3=${(pj:\n:)B3_lines}
typeset -g B4=${(pj:\n:)B4_lines} B5=${(pj:\n:)B5_lines} B6=${(pj:\n:)B6_lines}

# _t_keys <label> key value [key value ...]: check _emjay_git entries.
_t_keys() {
  local label=$1 k v
  shift
  for k v in "$@"; do
    assert_eq "${_emjay_git[$k]-<unset>}" "$v" "$label: _emjay_git[$k]"
  done
}

# _t_git_seg <expected stripped> <label>: _emjay_render_git and compare.
_t_git_seg() {
  _emjay_seg_git=junk
  _emjay_render_git
  seg_text git
  assert_eq "$REPLY" "$1" "$2: stripped git segment"
}

# ------------------------------------------------------------ parse_status

test_parse_clean_upstream() {
  _emjay_git_parse_status "$B1"
  _t_keys "parse B1" repo 1 branch main oid 1234567890abcdef1234567890abcdef12345678 \
    upstream origin/main ahead 0 behind 0 staged 0 modified 0 untracked 0 \
    conflicts 0 stash 0 detached 0
}

test_parse_full() {
  _emjay_git_parse_status "$B2"
  _t_keys "parse B2" repo 1 branch feature/x upstream origin/feature/x ahead 2 behind 1 \
    staged 4 modified 3 untracked 2 conflicts 1 stash 1 detached 0
  _emjay_git[bare]=0
  local g
  g="${UG[branch]} feature/x ${UG[ahead]}2 ${UG[behind]}1 ${UG[staged]}4 ${UG[modified]}3"
  g+=" ${UG[untracked]}2 ${UG[stash]}1 ${UG[conflict]}1"
  _t_git_seg "$g" "parse B2 then render"
}

test_parse_initial() {
  _emjay_git_parse_status "$B3"
  _t_keys "parse B3" oid '' branch main untracked 1 detached 0
}

test_parse_detached() {
  _emjay_git_parse_status "$B4"
  _t_keys "parse B4" branch '' detached 1 oid abcdef1234567890abcdef1234567890abcdef12
}

test_parse_upstream_gone() {
  _emjay_git_parse_status "$B5"
  _t_keys "parse B5" upstream origin/gone ahead 0 behind 0
}

test_parse_empty() {
  _emjay_git_parse_status ''
  _t_keys "parse ''" repo 1 branch '' oid '' upstream '' detached 0 ahead 0 behind 0 \
    staged 0 modified 0 untracked 0 conflicts 0 stash 0
}

test_parse_resets_previous() {
  _emjay_git_parse_status "$B2"
  _emjay_git[op]=MERGING     # a key parse_status never sets: must not survive
  _emjay_git_parse_status "$B1"
  _t_keys "parse B2 then B1" ahead 0 behind 0 staged 0 modified 0 untracked 0 \
    conflicts 0 stash 0 branch main upstream origin/main
  assert_eq "${+_emjay_git[op]}" 0 "parse B2 then B1: _emjay_git=() before parsing drops op"
}

test_parse_quoted_paths() {
  _emjay_git_parse_status "$B6"
  _t_keys "parse B6" modified 1 untracked 1 staged 0
}

test_parse_many_untracked() {
  local -a l=('# branch.oid 1234567890abcdef1234567890abcdef12345678' '# branch.head main')
  local -i i
  for (( i = 1; i <= 5000; i++ )); do l+=("? f$i"); done
  local text=${(pj:\n:)l}
  local t0=$EPOCHREALTIME
  _emjay_git_parse_status "$text"
  local dt=$(( EPOCHREALTIME - t0 ))
  _t_keys "parse 5000 untracked" untracked 5000
  assert_eq "$(( dt < 2 ))" 1 "parse 5000 untracked took ${dt}s, limit 2s"
}

# ------------------------------------------------------------ operation

# _t_op <gitdir> <expected> <label>
_t_op() {
  REPLY=unchanged
  _emjay_git_operation $1
  assert_eq "$REPLY" "$2" "_emjay_git_operation: $3"
}

test_op_rebase_merge() {
  mkdir -p $TT/g/rebase-merge
  print 2 > $TT/g/rebase-merge/msgnum
  print 5 > $TT/g/rebase-merge/end
  _t_op $TT/g 'REBASE 2/5' "rebase-merge msgnum=2 end=5"
}

test_op_rebase_merge_no_counts() {
  mkdir -p $TT/g/rebase-merge
  _t_op $TT/g 'REBASE' "empty rebase-merge/"
}

test_op_rebase_apply() {
  mkdir -p $TT/g/rebase-apply
  print 3 > $TT/g/rebase-apply/next
  print 4 > $TT/g/rebase-apply/last
  : > $TT/g/rebase-apply/rebasing
  _t_op $TT/g 'REBASE 3/4' "rebase-apply next=3 last=4 rebasing"
}

test_op_am() {
  mkdir -p $TT/g/rebase-apply
  print 1 > $TT/g/rebase-apply/next
  print 3 > $TT/g/rebase-apply/last
  : > $TT/g/rebase-apply/applying
  _t_op $TT/g 'AM 1/3' "rebase-apply next=1 last=3 applying"
}

test_op_merge() {
  mkdir -p $TT/g
  print 1234567890abcdef1234567890abcdef12345678 > $TT/g/MERGE_HEAD
  _t_op $TT/g MERGING "MERGE_HEAD"
}

test_op_cherry() {
  mkdir -p $TT/g
  print 1234567890abcdef1234567890abcdef12345678 > $TT/g/CHERRY_PICK_HEAD
  _t_op $TT/g CHERRY-PICKING "CHERRY_PICK_HEAD"
}

test_op_revert() {
  mkdir -p $TT/g
  print 1234567890abcdef1234567890abcdef12345678 > $TT/g/REVERT_HEAD
  _t_op $TT/g REVERTING "REVERT_HEAD"
}

test_op_bisect() {
  mkdir -p $TT/g
  print 'git bisect start' > $TT/g/BISECT_LOG
  _t_op $TT/g BISECTING "BISECT_LOG"
}

test_op_precedence() {
  mkdir -p $TT/g1/rebase-merge
  print 1 > $TT/g1/rebase-merge/msgnum
  print 2 > $TT/g1/rebase-merge/end
  print 1234567890abcdef1234567890abcdef12345678 > $TT/g1/MERGE_HEAD
  _t_op $TT/g1 'REBASE 1/2' "rebase-merge 1/2 plus MERGE_HEAD"
  mkdir -p $TT/g2
  print 1234567890abcdef1234567890abcdef12345678 > $TT/g2/MERGE_HEAD
  print 'git bisect start' > $TT/g2/BISECT_LOG
  _t_op $TT/g2 MERGING "MERGE_HEAD plus BISECT_LOG"
}

test_op_none() {
  mkdir -p $TT/g
  _t_op $TT/g '' "empty git dir"
  _t_op $TT/does-not-exist '' "nonexistent git dir"
}

# ------------------------------------------------------------ read_head

test_read_head_branch() {
  mkdir -p $TT/g
  print 'ref: refs/heads/feature/x' > $TT/g/HEAD
  _emjay_git=(repo 1 bare 1 staged 0)
  _emjay_git_read_head $TT/g
  _t_keys "read_head ref" branch feature/x detached 0 repo 1 bare 1 staged 0
}

test_read_head_detached() {
  mkdir -p $TT/g
  print abcdef1234567890abcdef1234567890abcdef12 > $TT/g/HEAD
  _emjay_git=(repo 1 bare 1 staged 0)
  _emjay_git_read_head $TT/g
  _t_keys "read_head hex" detached 1 oid abcdef1234567890abcdef1234567890abcdef12 \
    branch '' repo 1 bare 1 staged 0
}

# ------------------------------------------------------------ find_root
# test_find_root_*: one function per case in the DESIGN row.

# _t_root <dir|''> <expected REPLY> <expected status> <label>
# An empty <dir> calls _emjay_git_find_root with no argument ($PWD).
_t_root() {
  REPLY=unchanged
  if [[ -n $1 ]]; then _emjay_git_find_root $1; else _emjay_git_find_root; fi
  local -i rc=$?
  assert_eq "$rc" "$3" "_emjay_git_find_root $4: status"
  if [[ -n $2 && $2 != GIT_DIR=* && -n $REPLY ]]; then
    assert_eq "${REPLY:A}" "${2:A}" "_emjay_git_find_root $4: REPLY (compared with :A)"
  else
    assert_eq "$REPLY" "$2" "_emjay_git_find_root $4: REPLY"
  fi
}

test_find_root_repo_root() {
  mkdir -p $TT/r/.git
  _t_root $TT/r $TT/r 0 "from r with r/.git/"
}

test_find_root_subdir() {
  mkdir -p $TT/r/.git $TT/r/a/b
  _t_root $TT/r/a/b $TT/r 0 "from r/a/b"
  builtin cd -q $TT/r/a/b
  _t_root '' $TT/r 0 "from \$PWD=r/a/b (no argument)"
}

test_find_root_inside_git_dir() {
  mkdir -p $TT/r/.git/objects $TT/r/.git/refs
  print 'ref: refs/heads/main' > $TT/r/.git/HEAD
  _t_root $TT/r/.git/refs $TT/r/.git 0 "from r/.git/refs"
  _t_root $TT/r/.git $TT/r/.git 0 "from r/.git"
}

test_find_root_gitfile() {
  mkdir -p $TT/wt
  print "gitdir: $TT/r/.git/worktrees/wt" > $TT/wt/.git
  _t_root $TT/wt $TT/wt 0 "from wt with a .git file"
}

test_find_root_none() {
  mkdir -p $TT/plain
  _t_root $TT/plain '' 1 "from plain/"
}

test_find_root_git_dir_env() {
  mkdir -p $TT/x.git $TT/plain
  GIT_DIR=$TT/x.git
  _t_root $TT/plain "GIT_DIR=$TT/x.git" 0 "with GIT_DIR=\$TT/x.git"
}

# ------------------------------------------------------------ render_git

test_render_clean() {
  _emjay_git=(repo 1 bare 0 branch main detached 0)
  _t_git_seg "${UG[branch]} main ${UG[clean]}" "clean main"
  assert_contains "$_emjay_seg_git" '%F{76}' "clean main: raw segment uses GIT_CLEAN colour"
}

test_render_requirements_example() {
  _emjay_git=(repo 1 bare 0 branch main detached 0 ahead 2 behind 1 staged 3 modified 1
              untracked 2 stash 1 conflicts 1 op 'REBASE 2/5')
  local g
  g="${UG[branch]} main ${UG[ahead]}2 ${UG[behind]}1 ${UG[staged]}3 ${UG[modified]}1"
  g+=" ${UG[untracked]}2 ${UG[stash]}1 ${UG[conflict]}1 REBASE 2/5"
  _t_git_seg "$g" "requirements example"
  assert_contains "$_emjay_seg_git" "%F{178}${UG[branch]} main" "requirements example: raw head uses GIT_DIRTY colour"
}

test_render_clean_ahead_stash() {
  _emjay_git=(repo 1 bare 0 branch main detached 0 ahead 1 stash 2)
  _t_git_seg "${UG[branch]} main ${UG[clean]} ${UG[ahead]}1 ${UG[stash]}2" "clean, ahead 1, stash 2"
}

test_render_detached() {
  _emjay_git=(repo 1 bare 0 branch '' detached 1 oid abc1234def567890abc1234def567890abc12345)
  _t_git_seg "${UG[detached]} abc1234 ${UG[clean]}" "detached at abc1234..."
}

test_render_bare() {
  _emjay_git=(repo 1 bare 1 branch main detached 0)
  _t_git_seg "${UG[branch]} main" "bare, branch main"
}

test_render_bare_op() {
  _emjay_git=(repo 1 bare 1 branch main detached 0 op MERGING)
  _t_git_seg "${UG[branch]} main MERGING" "bare, branch main, op MERGING"
}

test_render_not_repo() {
  _emjay_seg_git=junk
  _emjay_git=(repo 0)
  _emjay_render_git
  assert_eq "$_emjay_seg_git" "" "render with _emjay_git=(repo 0)"
  _emjay_seg_git=junk
  _emjay_git=()
  _emjay_render_git
  assert_eq "$_emjay_seg_git" "" "render with _emjay_git=()"
}

test_render_toggle_off() {
  EMJAY_SHOW_GIT=0
  _emjay_seg_git=junk
  _emjay_git=(repo 1 bare 0 branch main detached 0)
  _emjay_render_git
  assert_eq "$_emjay_seg_git" "" "render with EMJAY_SHOW_GIT=0"
}

test_render_percent_escape() {
  _emjay_git=(repo 1 bare 0 branch 'a%b' detached 0)
  _emjay_render_git
  assert_contains "$_emjay_seg_git" 'a%%b' "branch a%b: raw segment escapes %"
  seg_text git
  assert_eq "$REPLY" "${UG[branch]} a%b ${UG[clean]}" "branch a%b: stripped git segment"
}

# ------------------------------------------------------------ serialize / apply

test_serialize_roundtrip() {
  # all 15 keys; includes an empty value, spaces and an '=' inside a value
  local -A orig=(
    repo 1 bare 0 gitdir "$TT/a=b/.git" branch feature/x
    oid 1234567890abcdef1234567890abcdef12345678 detached 0 upstream ''
    ahead 2 behind 1 staged 3 modified 1 untracked 2 conflicts 1 stash 1 op 'REBASE 2/5'
  )
  _emjay_git=("${(@kv)orig}")
  _emjay_git_reqid=3
  _emjay_git_serialize
  local payload="$_emjay_git_reqid"$'\n'$REPLY
  _emjay_git=()
  _emjay_git_apply "$payload"
  assert_eq "$?" 0 "apply of a serialized payload: status"
  local k got= want=
  for k in ${(ok)orig}; do want+="$k=$orig[$k];"; done
  for k in ${(ok)_emjay_git}; do got+="$k=$_emjay_git[$k];"; done
  assert_eq "$got" "$want" "serialize/apply round trip of _emjay_git"
}

test_apply_rejects_stale() {
  _emjay_git_reqid=5
  _emjay_git=(repo 1 bare 0 branch keep detached 0)
  _emjay_git_apply $'4\nrepo=1\nbranch=stale\nbare=0\ndetached=0'
  assert_eq "$?" 1 "apply with reqid 4 while current is 5: status"
  assert_eq "${_emjay_git[branch]}" keep "apply with stale reqid: _emjay_git[branch] unchanged"
  assert_eq "${#_emjay_git}" 4 "apply with stale reqid: _emjay_git size unchanged"
}

test_apply_rejects_garbage() {
  _emjay_git_reqid=5
  _emjay_git=(repo 1 bare 0 branch keep detached 0)
  _emjay_git_apply ''
  assert_eq "$?" 1 "apply of '': status"
  _emjay_git_apply $'abc\nrepo=1'
  assert_eq "$?" 1 "apply of 'abc\\nrepo=1': status"
  assert_eq "${_emjay_git[branch]}" keep "apply of garbage: _emjay_git[branch] unchanged"
}

run_tests
