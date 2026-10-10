# tests/test_kube.zsh: kubeconfig parsing, merging, caching, prod guard, rendering.
# lib.zsh unsets KUBECONFIG; HOME=$TT/home has no .kube unless a test creates it.
source ${0:A:h}/lib.zsh

# _t_kube_expect <display> <msg>: run _emjay_kube_update, then check
# _emjay_kube[display] and the stripped kube segment.
_t_kube_expect() {
  local want=$1 msg=$2
  _emjay_kube_update
  assert_eq "${_emjay_kube[display]-<unset>}" "$want" "$msg: _emjay_kube[display]"
  seg_text kube
  if [[ -n $want ]]; then
    assert_eq "$REPLY" "${UG[kube]} $want" "$msg: kube segment"
  else
    assert_eq "$REPLY" "" "$msg: kube segment"
  fi
}

# _t_default_kubeconfig <file>: install <file> as $HOME/.kube/config
_t_default_kubeconfig() {
  assert_ok mkdir -p $HOME/.kube
  assert_ok cp -- $1 $HOME/.kube/config
}

# _t_is_prod <ctx> <expected status>
_t_is_prod() {
  _emjay_kube_is_prod "$1"
  assert_eq "$?" "$2" "_emjay_kube_is_prod '$1' with pattern '${EMJAY_KUBE_PROD_PATTERN-<unset>}': status"
}

test_default_path() {
  kube_fixture basic
  _t_default_kubeconfig $REPLY
  _t_kube_expect dev/team-a "basic at ~/.kube/config"
  assert_eq "${_emjay_kube[ctx]}" dev "basic at default path: _emjay_kube[ctx]"
  assert_eq "${_emjay_kube[ns]}" team-a "basic at default path: _emjay_kube[ns]"
  assert_eq "${_emjay_kube[prod]}" 0 "basic at default path: _emjay_kube[prod]"
}

test_kubeconfig_single() {
  kube_fixture basic
  KUBECONFIG=$REPLY
  _t_kube_expect dev/team-a "KUBECONFIG=basic"
}

test_missing_namespace() {
  kube_fixture basic
  local txt=$(<$REPLY)
  print -r -- "${txt/current-context: dev/current-context: kind-kind}" > $TT/k.yaml
  KUBECONFIG=$TT/k.yaml
  _t_kube_expect kind-kind/default "basic with current-context kind-kind (no namespace)"
}

test_indented_quoted_comments() {
  kube_fixture indented
  local f=$REPLY
  KUBECONFIG=$f
  _t_kube_expect prod-eu/payments "indented fixture"
  assert_eq "${_emjay_kube[prod]}" 1 "indented fixture: _emjay_kube[prod] for prod-eu"
  assert_ok _emjay_kube_parse_file $f
  assert_eq "$_emjay_kp_cur" prod-eu "indented parse_file: _emjay_kp_cur"
  assert_eq "${_emjay_kp_ctx[staging]-<unset>}" web "indented parse_file: _emjay_kp_ctx[staging]"
  assert_eq "${_emjay_kp_ctx[prod-eu]-<unset>}" payments "indented parse_file: _emjay_kp_ctx[prod-eu]"
  assert_eq "${+_emjay_kp_ctx[should-not-match]}" 0 "indented parse_file: \${+_emjay_kp_ctx[should-not-match]}"
}

test_minikube_extensions() {
  kube_fixture minikube
  local f=$REPLY
  KUBECONFIG=$f
  _t_kube_expect minikube/kube-system "minikube fixture"
  assert_ok _emjay_kube_parse_file $f
  local -a names
  names=(${(ok)_emjay_kp_ctx})
  assert_eq "$names" minikube "minikube parse_file: context names"
  assert_eq "${_emjay_kp_ctx[minikube]-<unset>}" kube-system "minikube parse_file: _emjay_kp_ctx[minikube]"
}

test_eks_arn() {
  kube_fixture eks
  KUBECONFIG=$REPLY
  _t_kube_expect payments-prod/checkout "eks fixture"
  assert_eq "${_emjay_kube[ctx]}" arn:aws:eks:us-east-1:123456789012:cluster/payments-prod "eks fixture: _emjay_kube[ctx] is the full ARN"
  assert_eq "${_emjay_kube[prod]}" 1 "eks fixture: _emjay_kube[prod]"
}

test_gke() {
  kube_fixture gke
  KUBECONFIG=$REPLY
  _t_kube_expect web/default "gke fixture"
  assert_eq "${_emjay_kube[prod]}" 0 "gke fixture: _emjay_kube[prod]"
}

test_no_current_context() {
  kube_fixture no-current
  KUBECONFIG=$REPLY
  _t_kube_expect "" "no-current fixture"
  assert_eq "${_emjay_kube[ctx]}" "" "no-current fixture: _emjay_kube[ctx]"
  assert_eq "$_emjay_seg_kube" "" "no-current fixture: raw _emjay_seg_kube"
}

test_missing_file() {
  KUBECONFIG=$TT/nope.yaml
  capture_err _emjay_kube_update
  assert_eq "$REPLY" "" "KUBECONFIG=missing file: stderr of _emjay_kube_update"
  assert_eq "$_emjay_seg_kube" "" "KUBECONFIG=missing file: raw _emjay_seg_kube"
}

test_no_kubeconfig_at_all() {
  _t_kube_expect "" "no KUBECONFIG, no ~/.kube/config"
  assert_eq "$_emjay_seg_kube" "" "no kubeconfig at all: raw _emjay_seg_kube"
}

test_multi_first_current_wins() {
  local a b
  kube_fixture multi-a; a=$REPLY
  kube_fixture multi-b; b=$REPLY
  KUBECONFIG=$a:$b
  _t_kube_expect shared/ops "KUBECONFIG=multi-a:multi-b"
}

test_multi_reverse_undefined_ctx() {
  local a b
  kube_fixture multi-a; a=$REPLY
  kube_fixture multi-b; b=$REPLY
  KUBECONFIG=$b:$a
  _t_kube_expect other/default "KUBECONFIG=multi-b:multi-a"
}

test_multi_first_context_wins() {
  local a b
  kube_fixture multi-a; a=$REPLY
  kube_fixture multi-b; b=$REPLY
  print -r -- 'current-context: local' > $TT/c.yaml
  KUBECONFIG=$TT/c.yaml:$a:$b
  _t_kube_expect local/from-a "KUBECONFIG=c:multi-a:multi-b"
  KUBECONFIG=$TT/c.yaml:$b:$a
  _t_kube_expect local/from-b "KUBECONFIG=c:multi-b:multi-a"
}

test_multi_skips_missing_empty() {
  local a b
  kube_fixture multi-a; a=$REPLY
  kube_fixture multi-b; b=$REPLY
  KUBECONFIG="$TT/nope::$a:$b:"
  _t_kube_expect shared/ops "KUBECONFIG=nope::multi-a:multi-b:"
}

test_crlf() {
  kube_fixture basic
  local txt=$(<$REPLY)
  local nl=$'\n' crlf=$'\r\n'
  print -rn -- "${txt//$nl/$crlf}$crlf" > $TT/crlf.yaml
  KUBECONFIG=$TT/crlf.yaml
  _t_kube_expect dev/team-a "basic with CRLF line endings"
  assert_eq "${_emjay_kube[ctx]}" dev "CRLF: _emjay_kube[ctx] has no CR"
  assert_eq "${_emjay_kube[ns]}" team-a "CRLF: _emjay_kube[ns] has no CR"
}

test_bom() {
  kube_fixture basic
  local txt=$(<$REPLY)
  local -a lines
  lines=("${(@f)txt}")
  lines=("${(@)lines:#current-context:*}")
  print -rn -- $'\xef\xbb\xbf'"current-context: dev"$'\n'"${(pj:\n:)lines}"$'\n' > $TT/bom.yaml
  KUBECONFIG=$TT/bom.yaml
  _t_kube_expect dev/team-a "BOM before current-context on line 1"
}

test_flow_style_graceful() {
  kube_fixture flow
  KUBECONFIG=$REPLY
  capture_err _emjay_kube_update
  assert_eq "$REPLY" "" "flow fixture: stderr of _emjay_kube_update"
  _t_kube_expect flowy/default "flow fixture"
}

test_empty_contexts_list() {
  print -r -- $'current-context: solo\ncontexts: []' > $TT/k.yaml
  KUBECONFIG=$TT/k.yaml
  _t_kube_expect solo/default "contexts: []"
}

test_yaml_unquote_table() {
  # raw / expected pairs from DESIGN section 4.3
  local -a cases=(
    'foo'                 'foo'
    '  foo  '             'foo'
    'foo # c'             'foo'
    'foo#bar'             'foo#bar'
    '"foo bar"'           'foo bar'
    '"a\"b" # c'          'a"b'
    "'it''s'"             "it's"
    "'x'  # c"            'x'
    '""'                  ''
    '~'                   ''
    'null'                ''
    '"unterminated'       'unterminated'
    'arn:aws:eks:us-east-1:1:cluster/x'  'arn:aws:eks:us-east-1:1:cluster/x'
  )
  local raw want
  for raw want in "${cases[@]}"; do
    REPLY=unchanged
    _emjay_yaml_unquote "$raw"
    assert_eq "$REPLY" "$want" "_emjay_yaml_unquote '$raw'"
  done
}

test_shorten_table() {
  local -a cases=(
    'arn:aws:eks:us-east-1:123456789012:cluster/payments-prod'  'payments-prod'
    'arn:aws-cn:eks:cn-north-1:123456789012:cluster/x'          'x'
    'arn:aws-us-gov:eks:us-gov-west-1:1:cluster/a/b'            'a/b'
    'gke_my-proj_europe-west1-b_web'                            'web'
    'gke_bad'                                                   'gke_bad'
    'kind-kind'                                                 'kind-kind'
    'arn:aws:iam::1:role/r'                                     'arn:aws:iam::1:role/r'
    'me@eks.us-east-1.eksctl.io'                                'me@eks.us-east-1.eksctl.io'
  )
  local ctx want
  for ctx want in "${cases[@]}"; do
    REPLY=unchanged
    _emjay_kube_shorten "$ctx"
    assert_eq "$REPLY" "$want" "_emjay_kube_shorten '$ctx'"
  done
}

test_prod_default_pattern() {
  local c
  for c in prod-eu PRD-1 live eks-Live; do
    _t_is_prod $c 0
  done
}

test_prod_default_negative() {
  local c
  for c in staging dev; do
    _t_is_prod $c 1
  done
}

test_prod_custom_pattern() {
  EMJAY_KUBE_PROD_PATTERN='^prd-'
  _t_is_prod prd-x 0
  _t_is_prod prod-x 1
}

test_prod_empty_pattern() {
  EMJAY_KUBE_PROD_PATTERN=''
  _t_is_prod prod 1
}

test_prod_invalid_regex() {
  EMJAY_KUBE_PROD_PATTERN='('
  capture_err _emjay_kube_is_prod prod
  local -i rc=$?
  assert_eq "$rc" 1 "_emjay_kube_is_prod prod with pattern '(': status"
  assert_eq "$REPLY" "" "_emjay_kube_is_prod prod with pattern '(': stderr"
}

test_prod_matches_full_name() {
  print -r -- 'current-context: gke_acme-prod_us-east1-b_web' > $TT/k.yaml
  KUBECONFIG=$TT/k.yaml
  _t_kube_expect web/default "ctx gke_acme-prod_us-east1-b_web"
  assert_eq "${_emjay_kube[prod]}" 1 "ctx gke_acme-prod_us-east1-b_web: prod matched on the full name"
}

test_prod_colors() {
  kube_fixture eks
  KUBECONFIG=$REPLY
  _emjay_kube_update
  assert_contains "$_emjay_seg_kube" '%B' "eks raw kube segment is bold"
  assert_contains "$_emjay_seg_kube" '%F{196}' "eks raw kube segment uses default KUBE_PROD colour"
  EMJAY_COLOR_KUBE_PROD=160
  _emjay_render_kube
  assert_contains "$_emjay_seg_kube" '%F{160}' "eks raw kube segment with EMJAY_COLOR_KUBE_PROD=160"
  kube_fixture gke
  KUBECONFIG=$REPLY
  _emjay_kube_update
  assert_contains "$_emjay_seg_kube" '%F{33}' "gke raw kube segment uses default KUBE colour"
  assert_not_contains "$_emjay_seg_kube" '%B' "gke raw kube segment is not bold"
}

# Shared by the two mtime cache tests: k.yaml says aaa and is cached, then it
# is rewritten in place to bbb with the same size, inode and mtime.
_t_cache_setup() {
  print -r -- 'current-context: aaa' > $TT/k.yaml
  assert_ok touch -t 202001010000 $TT/k.yaml
  KUBECONFIG=$TT/k.yaml
  _t_kube_expect aaa/default "cache setup: first load"
  # Wait 50 ms so the rewrite gets a different ctime even with the kernel's
  # coarse timestamp clock; a cache key that wrongly included ctime would
  # then reparse and fail test_cache_hit_no_reparse.
  zmodload zsh/zselect && zselect -t 5
  print -r -- 'current-context: bbb' > $TT/k.yaml     # '>' truncates: same inode
  assert_ok touch -t 202001010000 $TT/k.yaml
}

test_cache_hit_no_reparse() {
  _t_cache_setup
  _t_kube_expect aaa/default "same mtime/size/inode after rewrite: cached value kept"
}

test_cache_mtime_invalidates() {
  _t_cache_setup
  assert_ok touch -t 202001010001 $TT/k.yaml
  _t_kube_expect bbb/default "after mtime change"
}

test_cache_kubeconfig_value_invalidates() {
  local a b
  kube_fixture multi-a; a=$REPLY
  kube_fixture multi-b; b=$REPLY
  KUBECONFIG=$a
  _t_kube_expect shared/default "KUBECONFIG=multi-a"
  KUBECONFIG=$a:$b
  _t_kube_expect shared/ops "KUBECONFIG changed to multi-a:multi-b"
}

test_use_context_simulation() {
  kube_fixture basic
  _t_default_kubeconfig $REPLY
  _t_kube_expect dev/team-a "before use-context"
  local txt=$(<$HOME/.kube/config)
  print -r -- "${txt/current-context: dev/current-context: kind-kind}" > $HOME/.kube/config
  _t_kube_expect kind-kind/default "after rewriting current-context to kind-kind"
}

test_show_toggle() {
  kube_fixture basic
  _t_default_kubeconfig $REPLY
  _t_kube_expect dev/team-a "toggle on"
  EMJAY_SHOW_KUBE=0
  _emjay_kube_update
  assert_eq "$_emjay_seg_kube" "" "EMJAY_SHOW_KUBE=0: raw _emjay_seg_kube"
  assert_eq "${_emjay_kube[display]}" "" "EMJAY_SHOW_KUBE=0: _emjay_kube[display]"
}

test_no_kubectl_calls() {
  local f
  assert_ok mkdir -p $TT/bin
  for f in kubectl kubectl.exe; do
    print -r -- "#!/bin/sh
: > '$TT/called'" > $TT/bin/$f
    assert_ok chmod +x $TT/bin/$f
  done
  PATH=$TT/bin:$PATH
  rehash
  kube_fixture basic
  _t_default_kubeconfig $REPLY
  _emjay_precmd
  assert_fail test -e $TT/called
  seg_text kube
  assert_eq "$REPLY" "${UG[kube]} dev/team-a" "kube segment after _emjay_precmd with fake kubectl on PATH"
}

test_ctx_name_not_evaluated() {
  # DESIGN's payload; YAML has no ref-name rules. Single-quoted in the file.
  local ctx='x$(:>pwned)%F'
  print -r -- "current-context: '$ctx'" > $TT/k.yaml
  KUBECONFIG=$TT/k.yaml
  _emjay_precmd
  : ${(%%)PROMPT}
  assert_fail test -e $TT/pwned
  assert_eq "${_emjay_kube[ctx]}" "$ctx" "_emjay_kube[ctx] for a hostile context name"
  seg_text kube
  assert_eq "$REPLY" "${UG[kube]} $ctx/default" "kube segment for a hostile context name"
}

run_tests
