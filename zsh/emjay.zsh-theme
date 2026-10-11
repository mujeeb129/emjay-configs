# emjay: a two-line oh-my-zsh theme (dir, git, kube, last-command status).
#
#   ~/projects/api  <branch> main <ahead>2 <behind>1 <staged>3 ... REBASE 2/5  <kube> eks-prod/payments  <error> 1  took 4s
#   <prompt>
#
# (docs/REQUIREMENTS.md shows the rendered example. This file is kept ASCII-only:
# glyphs are UTF-8 byte escapes, with their code points noted beside each table.
# Byte escapes, unlike \u escapes, do not depend on the locale in force when
# zsh converts them, which for a sourced file can be a later, non-UTF-8 one.)
#
# Load with ZSH_THEME="emjay" (oh-my-zsh), or source this file from any zsh >= 5.8.
# It needs nothing from oh-my-zsh. Git info is collected asynchronously by a
# zle -F worker; the kube segment is parsed from the kubeconfig file(s) in pure
# zsh (kubectl is never run). See docs/DESIGN.md for the full contract.
#
# Configuration (all optional, read at every prompt):
#   EMJAY_NERD_FONT=1          Nerd Font v3 icons
#   EMJAY_ASCII=1|0            1 forces ASCII glyphs, 0 forces Unicode; unset
#                              picks ASCII when the shell's codeset is not UTF-8
#   EMJAY_KUBE_PROD_PATTERN    case-insensitive ERE matched against the full
#                              context name (default 'prod|prd|live'; empty disables)
#   EMJAY_CMD_MAX_DURATION     show "took" when a command ran longer than N whole
#                              seconds (default 3)
#   EMJAY_SHOW_DIR / EMJAY_SHOW_GIT / EMJAY_SHOW_KUBE / EMJAY_SHOW_STATUS /
#   EMJAY_SHOW_DURATION        0 hides that segment (GIT and KUBE also skip the work)
#   EMJAY_GIT_ASYNC=0          collect git info synchronously (debugging, tests)
#   EMJAY_SEPARATOR            separator between line-1 segments (default two spaces)
#
# Palette (anything %F{...} accepts: 256-colour numbers or names):
#   EMJAY_COLOR_DIR=39  EMJAY_COLOR_GIT_CLEAN=76  EMJAY_COLOR_GIT_DIRTY=178
#   EMJAY_COLOR_GIT_SYNC=75  EMJAY_COLOR_GIT_STAGED=76  EMJAY_COLOR_GIT_MODIFIED=214
#   EMJAY_COLOR_GIT_UNTRACKED=244  EMJAY_COLOR_GIT_STASH=141  EMJAY_COLOR_GIT_CONFLICT=196
#   EMJAY_COLOR_GIT_OP=208  EMJAY_COLOR_KUBE=33  EMJAY_COLOR_KUBE_PROD=196
#   EMJAY_COLOR_ERROR=196  EMJAY_COLOR_TOOK=178  EMJAY_COLOR_PROMPT_OK=76
#   EMJAY_COLOR_PROMPT_ERR=196
#
# Conventions: every function starts with "emulate -L zsh"; helpers return via
# REPLY / reply / _emjay_* globals and never print; the prompt-time path does no
# command substitution other than the fork-free $(<file) form, and never leaves
# a non-zero status behind (a user TRAPZERR must not fire on every prompt).
# PROMPT is the static string '${_emjay_prompt}', so branch or context names
# are never evaluated.

# ---------------------------------------------------------------------------
# Prologue: options that change how the rest of this file is *parsed* (aliases
# are expanded at parse time; sh_glob and ignore_braces change the grammar).
# Pin them here and restore the user's settings in the epilogue.
# ---------------------------------------------------------------------------
'builtin' 'typeset' -ga _emjay_src_opts
_emjay_src_opts=()
[[ ! -o aliases ]]             || _emjay_src_opts+=(aliases)
[[ ! -o sh_glob ]]             || _emjay_src_opts+=(sh_glob)
[[ ! -o ignore_braces ]]       || _emjay_src_opts+=(ignore_braces)
[[ ! -o ignore_close_braces ]] || _emjay_src_opts+=(ignore_close_braces)
'builtin' 'setopt' no_aliases no_sh_glob brace_expand no_ignore_braces no_ignore_close_braces

# ---------------------------------------------------------------------------
# Modules
# ---------------------------------------------------------------------------
zmodload zsh/datetime 2>/dev/null || :
zmodload zsh/system 2>/dev/null || :
zmodload zsh/zselect 2>/dev/null || :
zmodload zsh/langinfo 2>/dev/null || :
zmodload -F zsh/stat b:zstat 2>/dev/null || :

# ---------------------------------------------------------------------------
# Globals (re-sourcing keeps existing values)
# ---------------------------------------------------------------------------
typeset -gA _emjay_glyph _emjay_kube _emjay_kp_ctx _emjay_git
typeset -g  _emjay_glyph_mode _emjay_glyph_key _emjay_cmd_start _emjay_kp_cur _emjay_git_key
typeset -g  _emjay_git_req_key
typeset -gi _emjay_cmd_ran _emjay_last_status _emjay_cmd_duration
typeset -gi _emjay_git_reqid _emjay_git_fd _emjay_git_pid
typeset -gi _emjay_git_worker_mode _emjay_git_child
typeset -gi _emjay_bang _emjay_redraw_pending _emjay_zle_hooked
typeset -g  _emjay_seg_dir _emjay_seg_git _emjay_seg_kube _emjay_seg_status _emjay_seg_took _emjay_seg_char
typeset -g  _emjay_line1 _emjay_prompt

# ---------------------------------------------------------------------------
# Glyphs
# ---------------------------------------------------------------------------
# _emjay_glyphs_load <unicode|nerd|ascii>: fill all 14 slots of _emjay_glyph.
_emjay_glyphs_load() {
  emulate -L zsh
  case $1 in
    (nerd)       # E0A0 F417 F062 F063 | F055 F06A F059 F01C | F071 F00C F10FE | F00D F252 276F
      _emjay_glyph=(
        branch    $'\xee\x82\xa0'  detached  $'\xef\x90\x97'  ahead     $'\xef\x81\xa2'  behind  $'\xef\x81\xa3'
        staged    $'\xef\x81\x95'  modified  $'\xef\x81\xaa'  untracked $'\xef\x81\x99'  stash   $'\xef\x80\x9c'
        conflict  $'\xef\x81\xb1'  clean     $'\xef\x80\x8c'  kube      $'\xf3\xb1\x83\xbe'
        error     $'\xef\x80\x8d'  took      $'\xef\x89\x92'  prompt    $'\xe2\x9d\xaf'
      )
      _emjay_glyph_mode=nerd
      ;;
    (ascii)
      _emjay_glyph=(
        branch    git  detached  @   ahead     '^'  behind  v
        staged    +    modified  '*' untracked '?'  stash   '$'
        conflict  '!'  clean     ok  kube      k8s
        error     x    took      took  prompt  '>'
      )
      _emjay_glyph_mode=ascii
      ;;
    (*)          # 2387 27A6 2191 2193 | 25CF 271A 2026 2691 | 2716 2714 2388 | 2718 -- 276F
      _emjay_glyph=(
        branch    $'\xe2\x8e\x87'  detached  $'\xe2\x9e\xa6'  ahead     $'\xe2\x86\x91'  behind  $'\xe2\x86\x93'
        staged    $'\xe2\x97\x8f'  modified  $'\xe2\x9c\x9a'  untracked $'\xe2\x80\xa6'  stash   $'\xe2\x9a\x91'
        conflict  $'\xe2\x9c\x96'  clean     $'\xe2\x9c\x94'  kube      $'\xe2\x8e\x88'
        error     $'\xe2\x9c\x98'  took      took        prompt    $'\xe2\x9d\xaf'
      )
      _emjay_glyph_mode=unicode
      ;;
  esac
  return 0
}

# _emjay_glyphs_select: pick the mode; reload only when the env fingerprint
# changed (one string comparison per call otherwise). The automatic choice
# follows the codeset the shell actually runs with (zsh/langinfo), not the
# spelling of the locale variables: LC_CTYPE=UTF-8 on Linux is not a valid
# locale, zsh then edits in ASCII, and Unicode glyphs would garble the line.
_emjay_glyphs_select() {
  emulate -L zsh
  local key="$EMJAY_NERD_FONT|$EMJAY_ASCII|$LC_ALL|$LC_CTYPE|$LANG"
  [[ $key == "$_emjay_glyph_key" && -n $_emjay_glyph_mode ]] && return 0
  _emjay_glyph_key=$key
  local cs
  if (( ${+langinfo} )) && [[ -n ${langinfo[CODESET]-} ]]; then
    cs=${(L)langinfo[CODESET]}
  else
    cs=${(L)${LC_ALL:-${LC_CTYPE:-$LANG}}}
  fi
  if [[ $EMJAY_NERD_FONT == 1 ]]; then
    _emjay_glyphs_load nerd
  elif [[ $EMJAY_ASCII == 1 ]]; then
    _emjay_glyphs_load ascii
  elif [[ $EMJAY_ASCII == 0 ]]; then
    _emjay_glyphs_load unicode
  elif [[ $cs != *utf-8* && $cs != *utf8* ]]; then
    _emjay_glyphs_load ascii
  else
    _emjay_glyphs_load unicode
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Formatters and helpers (pure, no fork)
# ---------------------------------------------------------------------------
# _emjay_enabled <VARNAME>: 0 unless ${(P)VARNAME} is exactly "0".
_emjay_enabled() {
  emulate -L zsh
  [[ ${(P)1} != 0 ]]
}

# _emjay_esc <text> -> REPLY: user data made safe for the prompt. Control
# characters become '?', '%' is doubled, and '!' is doubled when the user has
# PROMPT_BANG on (captured by _emjay_precmd into _emjay_bang).
_emjay_esc() {
  emulate -L zsh
  REPLY=${${1//[[:cntrl:]]/?}//\%/%%}
  (( _emjay_bang )) && REPLY=${REPLY//\!/!!}
  return 0
}

# _emjay_fmt_duration <secs> -> REPLY: 4s, 1m12s, 1h3m, 1d1h (zero trailing unit omitted).
_emjay_fmt_duration() {
  emulate -L zsh
  local n=${1%%.*}
  [[ $n == <-> ]] || n=0
  local -i s=$n d h m
  if (( s < 60 )); then
    REPLY=${s}s
  elif (( s < 3600 )); then
    m=s/60 s=s%60
    REPLY=${m}m
    (( s )) && REPLY+=${s}s
  elif (( s < 86400 )); then
    h=s/3600 m=s%3600/60
    REPLY=${h}h
    (( m )) && REPLY+=${m}m
  else
    d=s/86400 h=s%86400/3600
    REPLY=${d}d
    (( h )) && REPLY+=${h}h
  fi
  return 0
}

# _emjay_fmt_status <code> -> REPLY: signal name for 129..159, else the code.
_emjay_fmt_status() {
  emulate -L zsh
  REPLY=$1
  [[ $1 == <-> ]] || return 0
  (( $1 >= 129 && $1 <= 159 )) || return 0
  local sig=${signals[$1 - 127]}
  case $sig in
    (''|EXIT|ZERR|DEBUG) ;;
    (*) REPLY=$sig ;;
  esac
  return 0
}

# ---------------------------------------------------------------------------
# Kube
# ---------------------------------------------------------------------------
# _emjay_yaml_unquote <raw> -> REPLY (DESIGN.md 4.3).
_emjay_yaml_unquote() {
  emulate -L zsh
  setopt extendedglob
  local s=${1##[[:space:]]#} c out=
  local -i i n
  case $s in
    (\"*)
      s=${s#\"}
      n=${#s}
      for (( i = 1; i <= n; i++ )); do
        c=$s[i]
        if [[ $c == \" ]]; then
          REPLY=$out
          return 0
        fi
        if [[ $c == \\ && $s[i+1] == [\"\\] ]]; then
          (( i++ ))
          c=$s[i]
        fi
        out+=$c
      done
      REPLY=${s%%[[:space:]]#}          # unterminated: rest of the line
      ;;
    (\'*)
      s=${s#\'}
      n=${#s}
      for (( i = 1; i <= n; i++ )); do
        c=$s[i]
        if [[ $c == \' ]]; then
          if [[ $s[i+1] == \' ]]; then
            out+=\'
            (( i++ ))
            continue
          fi
          REPLY=$out
          return 0
        fi
        out+=$c
      done
      REPLY=${s%%[[:space:]]#}
      ;;
    (*)
      [[ $s == \#* ]] && s=             # "key: # comment" has no value
      s=${s%%[[:space:]]##\#*}
      s=${s%%[[:space:]]#}
      case $s in
        (\~|null|Null|NULL) s= ;;
      esac
      REPLY=$s
      ;;
  esac
  return 0
}

# _emjay_kube_files -> reply: the kubeconfig paths in merge order.
_emjay_kube_files() {
  emulate -L zsh
  if [[ -n $KUBECONFIG ]]; then
    reply=(${(s.:.)KUBECONFIG})
  else
    reply=("$HOME/.kube/config")
  fi
  return 0
}

# _emjay_kube_cache_key <file>... -> REPLY. Exactly one zstat per file.
_emjay_kube_cache_key() {
  emulate -L zsh
  local f; local -A st
  REPLY="KUBECONFIG=$KUBECONFIG"
  for f; do
    if builtin zstat -H st -F '%s.%N' -- "$f" 2>/dev/null; then   # follows symlinks (WSL ~/.kube/config -> /mnt/c/...)
      REPLY+=$'\n'"$f"$'\t'"$st[mtime]"$'\t'"$st[size]"$'\t'"$st[inode]"
    else
      REPLY+=$'\n'"$f"$'\t-'
    fi
  done
  return 0
}

# _emjay_kube_parse_file <path>: fill _emjay_kp_cur and _emjay_kp_ctx from one
# file (DESIGN.md 4.1/4.2). Returns 1 with both empty if unreadable. Silent.
_emjay_kube_parse_file() {
  emulate -L zsh
  setopt extendedglob
  _emjay_kp_cur=
  _emjay_kp_ctx=()
  local f=$1 data
  [[ -f $f && -r $f ]] || return 1
  { data=$(<$f) } 2>/dev/null || return 1
  data=${data#$'\xef\xbb\xbf'}

  local line body key val state=top iname= ins= REPLY
  local -i ind ii=-1 ic=-1 cc=-1 item=0 in_ctx=0 cur_set=0
  local -a match mbegin mend

  for line in "${(@f)data}"; do
    # Indented and '-' lines only matter inside the contexts list.
    if [[ $line == [\ -]* && $state != ctxs ]]; then
      continue
    fi
    line=${line%$'\r'}
    body=${line##[ ]#}
    [[ $body == [[:space:]]# || $body == \#* ]] && continue
    ind=${#line}-${#body}

    if (( ind == 0 )) && [[ $body != -* ]]; then          # top-level key
      if (( item )) && [[ -n $iname ]] && (( ! ${+_emjay_kp_ctx[$iname]} )); then
        _emjay_kp_ctx[$iname]=$ins
      fi
      item=0
      state=top
      [[ $body == (#b)([A-Za-z0-9_.-]##):([[:space:]]##(*)|) ]] || continue
      key=$match[1] val=$match[3]
      if [[ $key == current-context ]]; then
        if (( ! cur_set )); then
          _emjay_yaml_unquote "$val"
          _emjay_kp_cur=$REPLY
          cur_set=1
        fi
      elif [[ $key == contexts ]]; then
        _emjay_yaml_unquote "$val"
        if [[ -z $REPLY ]]; then                         # "contexts: []" / null -> no entries
          state=ctxs
          ii=-1
        fi
      fi
      continue
    fi

    [[ $state == ctxs ]] || continue

    if [[ $body == - || $body == '- '* ]]; then           # sequence item
      (( ii < 0 )) && ii=ind
      (( ind == ii )) || continue                         # nested list (extensions:)
      if (( item )) && [[ -n $iname ]] && (( ! ${+_emjay_kp_ctx[$iname]} )); then
        _emjay_kp_ctx[$iname]=$ins
      fi
      item=1 iname= ins= in_ctx=0 cc=-1
      body=${body#-}
      val=${body##[ ]#}
      ic=ind+1+${#body}-${#val}
      body=$val
      ind=ic
      [[ -z $body ]] && continue
    fi

    (( item )) || continue
    [[ $body == (#b)([A-Za-z0-9_.-]##):([[:space:]]##(*)|) ]] || continue
    key=$match[1] val=$match[3]
    if (( ind == ic )); then
      in_ctx=0
      if [[ $key == name ]]; then
        _emjay_yaml_unquote "$val"
        iname=$REPLY
      elif [[ $key == context ]]; then
        _emjay_yaml_unquote "$val"
        if [[ -z $REPLY ]]; then                         # flow "{...}" is ignored
          in_ctx=1
          cc=-1
        fi
      fi
    elif (( ind > ic && in_ctx )); then
      (( cc < 0 )) && cc=ind
      if (( ind == cc )) && [[ $key == namespace ]]; then
        _emjay_yaml_unquote "$val"
        ins=$REPLY
      fi
    fi
  done

  if (( item )) && [[ -n $iname ]] && (( ! ${+_emjay_kp_ctx[$iname]} )); then
    _emjay_kp_ctx[$iname]=$ins
  fi
  return 0
}

# _emjay_kube_load <file>...: merge files in order into _emjay_kube[ctx]/[ns].
# First non-empty current-context wins; a context's namespace comes from the
# first file that defines it. Returns 0 if a context was found.
_emjay_kube_load() {
  emulate -L zsh
  local f k ctx=
  local -A merged
  for f; do
    _emjay_kube_parse_file "$f" || continue
    [[ -z $ctx ]] && ctx=$_emjay_kp_cur
    for k in "${(@k)_emjay_kp_ctx}"; do
      (( ${+merged[$k]} )) || merged[$k]=$_emjay_kp_ctx[$k]
    done
    if [[ -n $ctx ]] && (( ${+merged[$ctx]} )); then
      break
    fi
  done
  _emjay_kube[ctx]=$ctx
  if [[ -n $ctx ]]; then
    _emjay_kube[ns]=${merged[$ctx]:-default}
  else
    _emjay_kube[ns]=
  fi
  [[ -n $ctx ]]
}

# _emjay_kube_shorten <ctx> -> REPLY: EKS ARN and GKE names shortened to the cluster.
_emjay_kube_shorten() {
  emulate -L zsh
  setopt extendedglob
  local -a match mbegin mend
  if [[ $1 == (#b)arn:aws[^:]#:eks:[^:]#:[0-9]#:cluster/(?##) ]]; then
    REPLY=$match[1]
  elif [[ $1 == (#b)gke_[^_]##_[^_]##_(?##) ]]; then
    REPLY=$match[1]
  else
    REPLY=$1
  fi
  return 0
}

# _emjay_kube_is_prod <ctx>: 0 if the full name matches EMJAY_KUBE_PROD_PATTERN.
_emjay_kube_is_prod() {
  emulate -L zsh
  local pat=${EMJAY_KUBE_PROD_PATTERN-prod|prd|live}
  [[ -n $pat ]] || return 1
  local MATCH MBEGIN MEND
  local -a match mbegin mend
  { [[ ${(L)1} =~ ${(L)pat} ]] } 2>/dev/null
}

# _emjay_kube_update: sync path. One zstat per kubeconfig; parse only on change.
_emjay_kube_update() {
  emulate -L zsh
  if ! _emjay_enabled EMJAY_SHOW_KUBE; then
    _emjay_kube=()
    _emjay_seg_kube=
    return 0
  fi
  local REPLY key
  local -a reply files
  _emjay_kube_files
  files=("${reply[@]}")
  _emjay_kube_cache_key "${files[@]}"
  key=$REPLY
  if [[ $key != "$_emjay_kube[key]" ]]; then
    _emjay_kube_load "${files[@]}" || :
    _emjay_kube[key]=$key
  fi
  _emjay_render_kube
  return 0
}

# ---------------------------------------------------------------------------
# Git, pure parts
# ---------------------------------------------------------------------------
# _emjay_git_find_root [dir=$PWD] -> REPLY = repo key ('' and status 1 if none).
# Stat tests only, no fork.
_emjay_git_find_root() {
  emulate -L zsh
  if [[ -n $GIT_DIR ]]; then
    REPLY="GIT_DIR=${GIT_DIR:a}"
    return 0
  fi
  local d=${${1:-$PWD}:a} p
  while :; do
    p=${d%/}
    if [[ -e $p/.git ]] || [[ -f $p/HEAD && -d $p/objects && -d $p/refs ]]; then
      REPLY=$d
      return 0
    fi
    [[ $d == / || -z $d ]] && break
    d=${d:h}
  done
  REPLY=
  return 1
}

# _emjay_git_parse_status <porcelain v2 text>: pure; fills _emjay_git
# (everything except bare, gitdir and op).
_emjay_git_parse_status() {
  emulate -L zsh
  setopt extendedglob
  local -a lines match mbegin mend
  local l v
  lines=("${(@f)1}")
  _emjay_git=(
    repo 1 branch '' oid '' detached 0 upstream '' ahead 0 behind 0
    staged 0 modified 0 untracked 0 conflicts 0 stash 0
  )
  for l in ${(M)lines:#\# *}; do
    case $l in
      ('# branch.oid '*)
        v=${l#\# branch.oid }
        [[ $v == '(initial)' ]] && v=
        _emjay_git[oid]=$v
        ;;
      ('# branch.head '*)
        v=${l#\# branch.head }
        if [[ $v == '(detached)' ]]; then
          _emjay_git[detached]=1
          _emjay_git[branch]=
        else
          _emjay_git[branch]=$v
        fi
        ;;
      ('# branch.upstream '*)
        _emjay_git[upstream]=${l#\# branch.upstream }
        ;;
      ('# branch.ab '*)
        if [[ $l == (#b)'# branch.ab +'(<->)' -'(<->)* ]]; then
          _emjay_git[ahead]=$match[1]
          _emjay_git[behind]=$match[2]
        fi
        ;;
      ('# stash '*)
        v=${l#\# stash }
        [[ $v == <-> ]] && _emjay_git[stash]=$v
        ;;
    esac
  done
  _emjay_git[staged]=${#${(M)lines:#[12] [^.]?*}}
  _emjay_git[modified]=${#${(M)lines:#[12] ?[^.]*}}
  _emjay_git[conflicts]=${#${(M)lines:#u *}}
  _emjay_git[untracked]=${#${(M)lines:#\? *}}
  return 0
}

# _emjay_git_read_head <gitdir>: branch/detached/oid from $gitdir/HEAD only.
# Used by tests and as the last fallback; a reftable repo's HEAD file only
# holds the placeholder "ref: refs/heads/.invalid", which is ignored (status 1).
_emjay_git_read_head() {
  emulate -L zsh
  setopt extendedglob
  local h
  [[ -f $1/HEAD && -r $1/HEAD ]] || return 1
  { h=$(<$1/HEAD) } 2>/dev/null
  h=${${h%%$'\n'*}%$'\r'}
  if [[ $h == 'ref: refs/heads/.invalid' ]]; then
    return 1
  elif [[ $h == 'ref: refs/heads/'?* ]]; then
    _emjay_git[branch]=${h#ref: refs/heads/}
    _emjay_git[detached]=0
  elif [[ $h == [[:xdigit:]](#c7,) ]]; then
    _emjay_git[branch]=
    _emjay_git[detached]=1
    _emjay_git[oid]=$h
  fi
  return 0
}

# _emjay_git_operation <gitdir> -> REPLY: in-progress operation or ''.
_emjay_git_operation() {
  emulate -L zsh
  local g=$1 d a= b=
  REPLY=
  if [[ -d $g/rebase-merge ]]; then
    d=$g/rebase-merge
    [[ -f $d/msgnum && -r $d/msgnum ]] && { a=$(<$d/msgnum) } 2>/dev/null
    [[ -f $d/end && -r $d/end ]] && { b=$(<$d/end) } 2>/dev/null
    REPLY=REBASE
  elif [[ -d $g/rebase-apply ]]; then
    d=$g/rebase-apply
    [[ -f $d/next && -r $d/next ]] && { a=$(<$d/next) } 2>/dev/null
    [[ -f $d/last && -r $d/last ]] && { b=$(<$d/last) } 2>/dev/null
    if [[ -e $d/applying ]]; then
      REPLY=AM
    else
      REPLY=REBASE
    fi
  elif [[ -e $g/MERGE_HEAD ]]; then
    REPLY=MERGING
  elif [[ -e $g/CHERRY_PICK_HEAD ]]; then
    REPLY=CHERRY-PICKING
  elif [[ -e $g/REVERT_HEAD ]]; then
    REPLY=REVERTING
  elif [[ -e $g/BISECT_LOG ]]; then
    REPLY=BISECTING
  fi
  a=${a//[[:space:]]/}
  b=${b//[[:space:]]/}
  [[ $a == <-> ]] || a=                 # counters only; never raw file bytes
  [[ $b == <-> ]] || b=
  if [[ -n $REPLY && -n $a && -n $b ]]; then
    REPLY+=" $a/$b"
  fi
  return 0
}

# _emjay_git_rebase_head <gitdir> -> REPLY: the branch being rebased (from
# rebase-merge/head-name or rebase-apply/head-name), or ''.
_emjay_git_rebase_head() {
  emulate -L zsh
  local d h=
  REPLY=
  for d in $1/rebase-merge $1/rebase-apply; do
    if [[ -f $d/head-name && -r $d/head-name ]]; then
      { h=$(<$d/head-name) } 2>/dev/null
      break
    fi
  done
  h=${${h%%$'\n'*}%$'\r'}
  [[ $h == refs/heads/?* ]] && REPLY=${h#refs/heads/}
  return 0
}

# _emjay_git_run <var> <git args...>: git's stdout (trailing newlines removed)
# into $var; returns git's status. In the worker, git runs as a coproc whose pid
# the worker's TERM trap kills: without job control the worker is not a process
# group leader, so killing the worker alone would leave a slow git running.
# Elsewhere (sync mode) it is a plain command substitution.
_emjay_git_run() {
  emulate -L zsh
  local _ejr_var=$1 _ejr_out=
  local -i _ejr_rc=0
  shift
  if (( _emjay_git_worker_mode )); then
    coproc command git "$@" 2>/dev/null
    _emjay_git_child=$!
    IFS= read -r -d '' -p _ejr_out || :
    wait $_emjay_git_child && _ejr_rc=0 || _ejr_rc=$?
    _emjay_git_child=0
    while [[ $_ejr_out == *$'\n' ]]; do _ejr_out=${_ejr_out%$'\n'}; done
  else
    _ejr_out=$(GIT_OPTIONAL_LOCKS=0 command git "$@" 2>/dev/null) && _ejr_rc=0 || _ejr_rc=$?
  fi
  : ${(P)_ejr_var::=$_ejr_out}
  return _ejr_rc
}

# _emjay_git_collect: forks git. Only from the worker or in sync mode.
_emjay_git_collect() {
  emulate -L zsh
  local out fsm gitdir REPLY
  local -a lines st
  local -i have_status=0
  if ! _emjay_git_run out rev-parse --absolute-git-dir --is-inside-work-tree; then
    _emjay_git=(repo 0)
    return 1
  fi
  lines=("${(@f)out}")
  gitdir=$lines[1]
  if [[ -z $gitdir ]]; then
    _emjay_git=(repo 0)
    return 1
  fi
  if [[ $lines[2] == true ]]; then
    # A non-boolean core.fsmonitor is a hook command taken from the repo's own
    # config: never run it just because the user cd'd into an untrusted repo.
    # The boolean form (git's builtin daemon) stays in effect.
    if _emjay_git_run fsm config --get core.fsmonitor &&
       [[ -n $fsm && ${(L)fsm} != (true|false|yes|no|on|off|<->) ]]; then
      st=(-c core.fsmonitor=false)
    fi
    if _emjay_git_run out $st status --porcelain=v2 --branch --show-stash; then
      _emjay_git_parse_status "$out"
      _emjay_git[bare]=0
      have_status=1
    fi
  fi
  if (( ! have_status )); then        # no work tree (inside .git, bare) or status failed
    _emjay_git=(
      repo 1 bare 1 branch '' oid '' detached 0 upstream '' ahead 0 behind 0
      staged 0 modified 0 untracked 0 conflicts 0 stash 0
    )
    # Ask git rather than reading HEAD: reftable repos keep a placeholder there.
    if _emjay_git_run out symbolic-ref -q --short HEAD && [[ -n $out ]]; then
      _emjay_git[branch]=$out
    elif _emjay_git_run out rev-parse -q --verify HEAD && [[ -n $out ]]; then
      _emjay_git[detached]=1
      _emjay_git[oid]=$out
    else
      _emjay_git_read_head "$gitdir" || :
    fi
  fi
  _emjay_git[gitdir]=$gitdir
  _emjay_git_operation "$gitdir"
  _emjay_git[op]=$REPLY
  # During a rebase HEAD is detached; show the branch being rebased instead.
  if [[ $_emjay_git[detached] == 1 && $_emjay_git[op] == REBASE* ]]; then
    _emjay_git_rebase_head "$gitdir"
    if [[ -n $REPLY ]]; then
      _emjay_git[branch]=$REPLY
      _emjay_git[detached]=0
    fi
  fi
  return 0
}

# _emjay_git_serialize -> REPLY: sorted "key=value" lines.
_emjay_git_serialize() {
  emulate -L zsh
  local k
  local -a out
  for k in ${(ko)_emjay_git}; do
    out+=("$k=$_emjay_git[$k]")
  done
  REPLY=${(pj:\n:)out}
  return 0
}

# _emjay_git_apply <payload>: "<reqid>\n<k=v lines>". Rejects stale/garbage (1).
_emjay_git_apply() {
  emulate -L zsh
  [[ -n $1 ]] || return 1
  local -a lines
  local l
  lines=("${(@f)1}")
  [[ $lines[1] == "$_emjay_git_reqid" ]] || return 1
  _emjay_git=()
  for l in "${(@)lines[2,-1]}"; do
    [[ $l == ?*=* ]] || continue
    _emjay_git[${l%%=*}]=${l#*=}
  done
  _emjay_render_git
  _emjay_assemble
  return 0
}

# ---------------------------------------------------------------------------
# Git, async
# ---------------------------------------------------------------------------
# _emjay_git_update: sync path; forks only when $PWD is inside a repo.
_emjay_git_update() {
  emulate -L zsh
  if ! _emjay_enabled EMJAY_SHOW_GIT; then
    _emjay_git_key=
    _emjay_git_cancel
    _emjay_git=()
    _emjay_seg_git=
    return 0
  fi
  _emjay_git_find_root || :
  # git missing counts as "not a repo". Looked up only inside a repo: a miss
  # walks all of $PATH (tens of /mnt/c entries on WSL) on every prompt.
  [[ -n $REPLY ]] && (( ! $+commands[git] )) && REPLY=
  if [[ $REPLY != "$_emjay_git_key" ]]; then      # never show another repo's data
    _emjay_git=()
    _emjay_git_key=$REPLY
  fi
  if [[ -n $_emjay_git_key ]]; then
    _emjay_git_request
  else
    _emjay_git_cancel
    _emjay_git=()
  fi
  _emjay_render_git
  return 0
}

_emjay_git_request() {
  emulate -L zsh
  _emjay_git_cancel
  (( ++_emjay_git_reqid ))
  _emjay_git_req_key=$_emjay_git_key
  if [[ $EMJAY_GIT_ASYNC == 0 ]]; then
    _emjay_git_collect || :
    _emjay_render_git
    return 0
  fi
  local fd pid=
  # Commands started from the prompt while a worker is pending inherit this
  # read end. That is harmless (they never read it) and it is closed on the
  # next callback or precmd; not worth a close-on-exec dance.
  exec {fd}< <(_emjay_git_worker $_emjay_git_reqid "$PWD")
  _emjay_git_fd=$fd
  IFS= read -r -u $fd pid || pid=
  [[ $pid == <-> ]] || pid=0          # never arithmetic-evaluate pipe data
  _emjay_git_pid=$pid
  if [[ -o zle ]]; then
    # As a widget (-w) the handler sees $LASTWIDGET and $ISEARCHMATCH_ACTIVE.
    (( ${+widgets[_emjay_git_callback]} )) || zle -N _emjay_git_callback 2>/dev/null || :
    zle -F -w $fd _emjay_git_callback 2>/dev/null || :
  fi
  return 0
}

# _emjay_git_worker <reqid> <dir>: runs inside <(...). Writes its pid, then one
# write of "<reqid>\n<serialized>\n", then exits (EOF).
_emjay_git_worker() {
  emulate -L zsh
  print -r -- $sysparams[pid]
  trap - ZERR                        # a user ZERR trap must not write into the pipe
  _emjay_git_worker_mode=1 _emjay_git_child=0
  trap '(( _emjay_git_child > 1 )) && kill -TERM $_emjay_git_child 2>/dev/null; exit 143' TERM
  export GIT_OPTIONAL_LOCKS=0
  { builtin cd -q -- "$2" 2>/dev/null && _emjay_git_collect } || _emjay_git=(repo 0)
  _emjay_git_serialize
  print -r -- "$1"$'\n'"$REPLY"
}

# _emjay_git_cancel: drop the pending request. A worker whose pipe is already
# readable has written its payload (or exited), so it may be gone and its pid
# reused: it is never signalled. Its result is applied instead when it is for
# the repo we are still in (keeps info after "cd slowrepo; long-command").
_emjay_git_cancel() {
  emulate -L zsh
  (( _emjay_git_fd > 0 )) || return 0
  local fd=$_emjay_git_fd pid=$_emjay_git_pid data=
  local -a reply
  _emjay_git_fd=0 _emjay_git_pid=0
  zle -F $fd 2>/dev/null || :
  if zselect -t 0 -r $fd 2>/dev/null; then
    pid=0
    if [[ -n $_emjay_git_req_key && $_emjay_git_req_key == "$_emjay_git_key" ]]; then
      IFS= read -r -u $fd -d '' data || :
    fi
  fi
  { exec {fd}<&- } 2>/dev/null
  if [[ $pid == <-> ]] && (( pid > 1 )); then
    if [[ -o monitor ]]; then
      kill -TERM -$pid 2>/dev/null || :      # its own process group under job control
    else
      kill -TERM $pid 2>/dev/null || :       # its TERM trap kills the git child
    fi
  fi
  if [[ -n $data ]]; then
    _emjay_git_apply "$data" || :
  fi
  return 0
}

# _emjay_zle_busy: 0 while a completion list/menu-select or an incremental
# search is on screen; a reset-prompt then would corrupt the list or the search
# line. During isearch $LASTWIDGET is still the widget before it, so isearch is
# detected by $ISEARCHMATCH_ACTIVE; once it ends the flag drops at once, while
# $LASTWIDGET would keep naming the search widget until the next key.
_emjay_zle_busy() {
  emulate -L zsh
  [[ ${ISEARCHMATCH_ACTIVE:-0} == 1 ]] && return 0
  [[ ${LASTWIDGET-} == (*complet*|menu-*|*isearch*|*history-search*) ]]
}

# _emjay_git_callback <fd> [err]: zle -F -w handler (tests call it to drain).
_emjay_git_callback() {
  emulate -L zsh
  zle -f nolast 2>/dev/null || :      # leave $LASTWIDGET to the user's widgets
  local fd=$1 data= old=$_emjay_prompt REPLY
  local -a reply
  [[ $fd == <-> ]] && (( fd > 0 )) || return 0
  if [[ -z $2 || $2 == hup ]]; then
    IFS= read -r -u $fd -d '' data || :   # rc 1 at EOF is expected
  fi
  zle -F $fd 2>/dev/null || :
  { exec {fd}<&- } 2>/dev/null
  if (( fd == _emjay_git_fd )); then
    _emjay_git_fd=0 _emjay_git_pid=0
    # A widget may have run cd (and reset-prompt) without a precmd: a result
    # for the repo we left must not be shown.
    _emjay_git_find_root || :
    if [[ $REPLY != "$_emjay_git_req_key" ]]; then
      data=
      _emjay_git=()
      _emjay_seg_git=
      _emjay_assemble
    fi
  fi
  if [[ -n $data ]]; then
    _emjay_git_apply "$data" || return 0
  fi
  [[ $_emjay_prompt == "$old" ]] && return 0
  if _emjay_zle_busy; then
    _emjay_redraw_pending=1           # redraw from zle-line-pre-redraw once it is safe
    _emjay_zle_hook_install || :
  else
    { zle .reset-prompt && zle -R } 2>/dev/null || :
  fi
  return 0
}

# _emjay_line_pre_redraw: zle-line-pre-redraw hook; does a deferred reset-prompt.
_emjay_line_pre_redraw() {
  emulate -L zsh
  if (( _emjay_redraw_pending )) && ! _emjay_zle_busy; then
    _emjay_redraw_pending=0
    zle .reset-prompt 2>/dev/null || :
  fi
  if (( ${+widgets[_emjay_prev_line_pre_redraw]} )); then
    zle _emjay_prev_line_pre_redraw -f nolast -- "$@" 2>/dev/null || :
  fi
  return 0
}

# _emjay_zle_hook_install: hook _emjay_line_pre_redraw into zle-line-pre-redraw
# once per shell, on the first deferred redraw. Uses add-zle-hook-widget when it
# already manages the hook; otherwise installs directly, chaining to any widget
# the user had there (add-zle-hook-widget later keeps ours the same way).
_emjay_zle_hook_install() {
  emulate -L zsh
  (( _emjay_zle_hooked )) && return 0
  local h=zle-line-pre-redraw cur=${widgets[zle-line-pre-redraw]-}
  local -a w
  zle -N _emjay_line_pre_redraw 2>/dev/null || return 1
  _emjay_zle_hooked=1
  if [[ $cur == user:azhw:$h ]] && (( ${+functions[add-zle-hook-widget]} )); then
    zstyle -a $h widgets w
    if [[ -z ${(M)w:#<->:(user:|)_emjay_line_pre_redraw} ]]; then
      add-zle-hook-widget line-pre-redraw _emjay_line_pre_redraw 2>/dev/null || :
    fi
    return 0
  fi
  if [[ -n $cur && $cur != user:_emjay_line_pre_redraw ]]; then
    zle -A $h _emjay_prev_line_pre_redraw 2>/dev/null || :
  fi
  zle -N $h _emjay_line_pre_redraw 2>/dev/null || :
  return 0
}

# ---------------------------------------------------------------------------
# Renderers
# ---------------------------------------------------------------------------
_emjay_render_dir() {
  emulate -L zsh
  if _emjay_enabled EMJAY_SHOW_DIR; then
    _emjay_seg_dir="%B%F{${EMJAY_COLOR_DIR:-39}}%~%f%b"
  else
    _emjay_seg_dir=
  fi
  return 0
}

_emjay_render_git() {
  emulate -L zsh
  _emjay_glyphs_select
  if ! _emjay_enabled EMJAY_SHOW_GIT || [[ $_emjay_git[repo] != 1 ]]; then
    _emjay_seg_git=
    return 0
  fi
  local k v name glyph head color conflict=$_emjay_glyph[conflict] REPLY
  local -A n
  local -a parts
  for k in ahead behind staged modified untracked stash conflicts; do
    v=$_emjay_git[$k]
    [[ $v == <-> ]] || v=0
    n[$k]=$v
  done
  if [[ $_emjay_git[detached] == 1 ]]; then
    glyph=$_emjay_glyph[detached]
    name=${_emjay_git[oid][1,7]}
  else
    glyph=$_emjay_glyph[branch]
    name=$_emjay_git[branch]
  fi
  _emjay_esc "$name"
  head="$glyph $REPLY"
  if (( n[staged] + n[modified] + n[untracked] + n[conflicts] > 0 )); then
    color=${EMJAY_COLOR_GIT_DIRTY:-178}
  else
    color=${EMJAY_COLOR_GIT_CLEAN:-76}
    [[ $_emjay_git[bare] != 1 ]] && head+=" $_emjay_glyph[clean]"
  fi
  (( _emjay_bang )) && conflict=${conflict//\!/!!}
  parts=("%F{$color}$head%f")
  (( n[ahead] ))     && parts+=("%F{${EMJAY_COLOR_GIT_SYNC:-75}}$_emjay_glyph[ahead]$n[ahead]%f")
  (( n[behind] ))    && parts+=("%F{${EMJAY_COLOR_GIT_SYNC:-75}}$_emjay_glyph[behind]$n[behind]%f")
  (( n[staged] ))    && parts+=("%F{${EMJAY_COLOR_GIT_STAGED:-76}}$_emjay_glyph[staged]$n[staged]%f")
  (( n[modified] ))  && parts+=("%F{${EMJAY_COLOR_GIT_MODIFIED:-214}}$_emjay_glyph[modified]$n[modified]%f")
  (( n[untracked] )) && parts+=("%F{${EMJAY_COLOR_GIT_UNTRACKED:-244}}$_emjay_glyph[untracked]$n[untracked]%f")
  (( n[stash] ))     && parts+=("%F{${EMJAY_COLOR_GIT_STASH:-141}}$_emjay_glyph[stash]$n[stash]%f")
  (( n[conflicts] )) && parts+=("%F{${EMJAY_COLOR_GIT_CONFLICT:-196}}$conflict$n[conflicts]%f")
  if [[ -n $_emjay_git[op] ]]; then
    _emjay_esc "$_emjay_git[op]"
    parts+=("%B%F{${EMJAY_COLOR_GIT_OP:-208}}$REPLY%f%b")
  fi
  _emjay_seg_git=${(j: :)parts}
  return 0
}

_emjay_render_kube() {
  emulate -L zsh
  _emjay_glyphs_select
  local ctx=$_emjay_kube[ctx] ns=$_emjay_kube[ns] disp REPLY
  if [[ -z $ctx ]] || ! _emjay_enabled EMJAY_SHOW_KUBE; then
    _emjay_kube[display]=
    _emjay_kube[prod]=0
    _emjay_seg_kube=
    return 0
  fi
  _emjay_kube_shorten "$ctx"
  disp="$REPLY/${ns:-default}"
  disp=${disp//[[:cntrl:]]/?}
  _emjay_kube[display]=$disp
  _emjay_esc "$disp"
  disp=$REPLY
  if _emjay_kube_is_prod "$ctx"; then
    _emjay_kube[prod]=1
    _emjay_seg_kube="%B%F{${EMJAY_COLOR_KUBE_PROD:-196}}$_emjay_glyph[kube] $disp%f%b"
  else
    _emjay_kube[prod]=0
    _emjay_seg_kube="%F{${EMJAY_COLOR_KUBE:-33}}$_emjay_glyph[kube] $disp%f"
  fi
  return 0
}

# Sets _emjay_seg_status, _emjay_seg_took and _emjay_seg_char.
_emjay_render_status() {
  emulate -L zsh
  _emjay_glyphs_select
  local REPLY max=$EMJAY_CMD_MAX_DURATION
  [[ $max == <-> ]] || max=3
  if _emjay_enabled EMJAY_SHOW_STATUS && (( _emjay_last_status != 0 )); then
    _emjay_fmt_status $_emjay_last_status
    _emjay_seg_status="%F{${EMJAY_COLOR_ERROR:-196}}$_emjay_glyph[error] ${REPLY//\%/%%}%f"
  else
    _emjay_seg_status=
  fi
  if _emjay_enabled EMJAY_SHOW_DURATION && (( _emjay_cmd_duration > max )); then
    _emjay_fmt_duration $_emjay_cmd_duration
    _emjay_seg_took="%F{${EMJAY_COLOR_TOOK:-178}}$_emjay_glyph[took] $REPLY%f"
  else
    _emjay_seg_took=
  fi
  if (( _emjay_last_status == 0 )); then
    _emjay_seg_char="%F{${EMJAY_COLOR_PROMPT_OK:-76}}$_emjay_glyph[prompt]%f"
  else
    _emjay_seg_char="%F{${EMJAY_COLOR_PROMPT_ERR:-196}}$_emjay_glyph[prompt]%f"
  fi
  return 0
}

_emjay_assemble() {
  emulate -L zsh
  local s sep='  '
  (( ${+EMJAY_SEPARATOR} )) && sep=$EMJAY_SEPARATOR
  _emjay_line1=
  for s in $_emjay_seg_dir $_emjay_seg_git $_emjay_seg_kube $_emjay_seg_status $_emjay_seg_took; do
    _emjay_line1+=${_emjay_line1:+$sep}$s
  done
  if [[ -n $_emjay_line1 ]]; then
    _emjay_prompt="$_emjay_line1"$'\n'"$_emjay_seg_char "
  else
    _emjay_prompt="$_emjay_seg_char "
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Hooks
# ---------------------------------------------------------------------------
_emjay_preexec() {
  emulate -L zsh
  _emjay_cmd_start=$EPOCHREALTIME
  _emjay_cmd_ran=1
  return 0
}

# _emjay_status_update <code> [now=$EPOCHREALTIME]
_emjay_status_update() {
  emulate -L zsh
  local now=${2:-$EPOCHREALTIME}
  if (( _emjay_cmd_ran == 1 )); then
    if [[ $1 == <-> ]]; then
      _emjay_last_status=$1
    else
      _emjay_last_status=0
    fi
    if [[ -n $_emjay_cmd_start ]]; then
      _emjay_cmd_duration=now-_emjay_cmd_start      # integer target: floors
      (( _emjay_cmd_duration < 0 )) && _emjay_cmd_duration=0
    else
      _emjay_cmd_duration=0
    fi
  else                                   # empty Enter / ^C at the prompt
    _emjay_last_status=0
    _emjay_cmd_duration=0
  fi
  _emjay_cmd_ran=0
  _emjay_cmd_start=
  return 0
}

# _emjay_chpwd: a cd into another repo (or out of one) clears the git segment at
# once, also when a widget runs cd and reset-prompt without a precmd.
_emjay_chpwd() {
  emulate -L zsh
  local REPLY
  local -a reply
  _emjay_enabled EMJAY_SHOW_GIT || return 0
  _emjay_git_find_root || :
  [[ $REPLY == "$_emjay_git_key" ]] && return 0
  _emjay_git_key=$REPLY
  _emjay_git_cancel
  _emjay_git=()
  _emjay_seg_git=
  _emjay_assemble
  return 0
}

_emjay_precmd() {
  local -i code=$?           # MUST be the first statement
  [[ -o prompt_bang ]] && _emjay_bang=1 || _emjay_bang=0     # before emulate resets it
  emulate -L zsh
  local REPLY
  local -a reply
  _emjay_status_update $code
  _emjay_glyphs_select
  _emjay_git_update          # starts the worker first so it overlaps with the sync work
  _emjay_kube_update
  _emjay_render_dir
  _emjay_render_status
  _emjay_assemble
  _emjay_redraw_pending=0    # a fresh prompt is about to be drawn anyway
  return 0
}

# ---------------------------------------------------------------------------
# Registration
# ---------------------------------------------------------------------------
# Same dedupe as add-zsh-hook, without defining a non-_emjay_ function; inside
# emulate so options like ksh_arrays cannot break the (Ie) index checks.
() {
  emulate -L zsh
  typeset -ga precmd_functions preexec_functions chpwd_functions
  (( ${precmd_functions[(Ie)_emjay_precmd]} )) || precmd_functions+=(_emjay_precmd)
  (( ${preexec_functions[(Ie)_emjay_preexec]} )) || preexec_functions+=(_emjay_preexec)
  (( ${chpwd_functions[(Ie)_emjay_chpwd]} )) || chpwd_functions+=(_emjay_chpwd)
  _emjay_glyphs_select
  _emjay_git_cancel
  [[ -n $_emjay_prompt ]] || _emjay_prompt="${_emjay_glyph[prompt]} "
  return 0
}
setopt prompt_subst
PROMPT='${_emjay_prompt}'

# Epilogue: restore the parse-time options saved in the prologue.
if (( ${#_emjay_src_opts[@]} )); then
  'builtin' 'setopt' "${_emjay_src_opts[@]}"
fi
'builtin' 'unset' _emjay_src_opts
