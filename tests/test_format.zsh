# tests/test_format.zsh: duration and status formatting, status bookkeeping.
source ${0:A:h}/lib.zsh

test_duration_table() {
  # input / expected output pairs from DESIGN section 3.1
  local -a cases=(
    0 0s  3 3s  59 59s  60 1m  72 1m12s  3599 59m59s  3600 1h  3661 1h1m
    3780 1h3m  86399 23h59m  86400 1d  90061 1d1h  4.9 4s  -5 0s  abc 0s  '' 0s
  )
  local i o
  for i o in "${cases[@]}"; do
    REPLY=unchanged
    _emjay_fmt_duration "$i"
    assert_eq "$REPLY" "$o" "_emjay_fmt_duration '$i'"
  done
}

test_status_codes() {
  local -a cases=(1 1  2 2  127 127  128 128  130 INT  137 KILL  141 PIPE  143 TERM  200 200  255 255)
  local i o
  for i o in "${cases[@]}"; do
    REPLY=unchanged
    _emjay_fmt_status "$i"
    assert_eq "$REPLY" "$o" "_emjay_fmt_status $i"
  done
}

test_status_update_success() {
  _emjay_cmd_ran=1 _emjay_cmd_start=100
  _emjay_status_update 0 101
  assert_eq "$_emjay_last_status" 0 "last_status after 'update 0 101'"
  assert_eq "$_emjay_cmd_duration" 1 "cmd_duration after start=100 now=101"
  assert_eq "$_emjay_cmd_ran" 0 "cmd_ran reset after update"
  assert_eq "$_emjay_cmd_start" "" "cmd_start reset after update"
}

test_status_update_failure_duration() {
  _emjay_cmd_ran=1 _emjay_cmd_start=100
  _emjay_status_update 1 172.5
  assert_eq "$_emjay_last_status" 1 "last_status after 'update 1 172.5'"
  assert_eq "$_emjay_cmd_duration" 72 "cmd_duration after start=100 now=172.5"
}

test_status_update_empty_enter() {
  # stale values from an earlier command must be reset by an empty Enter
  _emjay_last_status=5 _emjay_cmd_duration=9
  _emjay_cmd_ran=0 _emjay_cmd_start=''
  _emjay_status_update 1
  assert_eq "$_emjay_last_status" 0 "last_status after empty Enter ('update 1', ran=0)"
  assert_eq "$_emjay_cmd_duration" 0 "cmd_duration after empty Enter"
}

test_status_update_floor() {
  _emjay_cmd_ran=1 _emjay_cmd_start=100
  _emjay_status_update 0 103.99
  assert_eq "$_emjay_cmd_duration" 3 "cmd_duration floor of 3.99s"
}

run_tests
