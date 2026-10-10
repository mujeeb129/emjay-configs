#!/usr/bin/env zsh
# tests/run.zsh: run the emjay test suite.
#
#   zsh tests/run.zsh [files...]      default: tests/test_*.zsh, sorted
#   EMJAY_TEST_FILTER='test_parse_*'  only run test functions matching the glob
#   EMJAY_TEST_SKIP_PERF=1            skip the timing test
#
# Each file runs in its own `zsh -f`. Exit status is 1 if any file failed.

emulate -R zsh
setopt extendedglob

typeset here=${${(%):-%x}:A:h}
typeset -a files
if (( $# )); then
  files=("$@")
else
  files=($here/test_*.zsh(N))      # glob results are sorted
fi

# The filter and skip switches reach the children through the environment.
[[ -n ${EMJAY_TEST_FILTER-} ]] && export EMJAY_TEST_FILTER
[[ -n ${EMJAY_TEST_SKIP_PERF-} ]] && export EMJAY_TEST_SKIP_PERF

typeset -i n=0 p=0 f=0
typeset file
for file in $files; do
  (( ++n ))
  print -r -- "# ${file:t}"
  if zsh -f -- $file; then
    (( ++p ))
  else
    (( ++f ))
    print -r -- "# FAILED: ${file:t}"
  fi
done

print -r -- "$n files, $p passed, $f failed"
(( f == 0 ))
