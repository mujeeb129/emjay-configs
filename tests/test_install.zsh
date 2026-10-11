# tests/test_install.zsh: install.sh against a fake HOME and oh-my-zsh.
# Every run gets HOME and ZSH pointing into $TT, with ZSH_CUSTOM and ZDOTDIR
# unset explicitly because the real ones may be exported in the environment.
source ${0:A:h}/lib.zsh

typeset -g THEME=$EMJAY_ROOT/zsh/emjay.zsh-theme H= ORIG=

# The .zshrc from DESIGN section 9, and the expected result of installing over it.
typeset -g STD_ZSHRC='export ZSH="$HOME/.oh-my-zsh"
# ZSH_THEME="old"
ZSH_THEME="robbyrussell"
source $ZSH/oh-my-zsh.sh
'
typeset -g STD_ZSHRC_AFTER='export ZSH="$HOME/.oh-my-zsh"
# ZSH_THEME="old"
ZSH_THEME="emjay"
source $ZSH/oh-my-zsh.sh
'

# _t_slurp <file> -> REPLY, byte for byte ('' if missing)
_t_slurp() {
  REPLY=
  [[ -r $1 ]] && IFS= read -r -d '' REPLY < $1
  return 0
}

# _t_exists <path>: exists, or is a (possibly dangling) symlink
_t_exists() { [[ -e $1 || -L $1 ]] }

# _t_setup: fake oh-my-zsh and the standard .zshrc; ORIG = its bytes.
_t_setup() {
  H=$TT/home
  assert_ok mkdir -p $H/.oh-my-zsh/custom
  print -rn -- "$STD_ZSHRC" > $H/.zshrc
  _t_slurp $H/.zshrc
  ORIG=$REPLY
}

# _t_install [VAR=value ...]: run install.sh with HOME=$H ZSH=$H/.oh-my-zsh,
# ZSH_CUSTOM and ZDOTDIR unset, then the given overrides. stdout and stderr
# go to $TT/inst.out and $TT/inst.err. Returns install.sh's status.
_t_install() {
  (
    unset ZSH_CUSTOM ZDOTDIR
    export HOME=$H ZSH=$H/.oh-my-zsh
    local a
    for a; do export "$a"; done
    exec sh $EMJAY_ROOT/install.sh
  ) > $TT/inst.out 2> $TT/inst.err
}

# _t_install_ok <label> [VAR=value ...]: _t_install and require status 0.
_t_install_ok() {
  local label=$1
  shift
  _t_install "$@"
  local -i rc=$?
  _t_slurp $TT/inst.err
  assert_eq "$rc" 0 "$label: install.sh exit status (stderr: $REPLY)"
}

test_install_symlink() {
  _t_setup
  _t_install_ok "first install"
  local link=$H/.oh-my-zsh/custom/themes/emjay.zsh-theme
  assert_ok test -L $link
  assert_eq "${link:A}" "${THEME:A}" "symlink $link target (compared with :A)"
}

test_install_sets_theme_and_backup() {
  _t_setup
  _t_install_ok "first install"
  _t_slurp $H/.zshrc
  local txt=$REPLY
  local -a lines themes
  lines=("${(@f)txt}")
  themes=("${(@M)lines:#[[:space:]]#ZSH_THEME=*}")
  assert_eq "${(j:|:)themes}" 'ZSH_THEME="emjay"' "uncommented ZSH_THEME lines in .zshrc (joined with |)"
  assert_not_contains "$txt" robbyrussell ".zshrc after install"
  local commented='# ZSH_THEME="old"'
  assert_ne "${lines[(Ie)$commented]}" 0 "line number of '$commented' in .zshrc (0 = removed)"
  assert_eq "$txt" "$STD_ZSHRC_AFTER" ".zshrc after install, whole file"
  assert_ok test -f $H/.zshrc.bak
  _t_slurp $H/.zshrc.bak
  assert_eq "$REPLY" "$ORIG" ".zshrc.bak equals the original .zshrc"
}

test_install_idempotent() {
  _t_setup
  _t_install_ok "first install"
  _t_slurp $H/.zshrc
  local first=$REPLY
  _t_install_ok "second install"
  _t_slurp $TT/inst.out
  assert_contains "$REPLY" "already set" "second install: stdout"
  _t_slurp $H/.zshrc
  assert_eq "$REPLY" "$first" "second install: .zshrc byte-identical to after the first"
  _t_slurp $H/.zshrc.bak
  assert_eq "$REPLY" "$ORIG" "second install: .zshrc.bak still equals the original .zshrc"
}

test_install_inserts_when_missing() {
  _t_setup
  print -rn -- 'export ZSH="$HOME/.oh-my-zsh"
plugins=(git)
source $ZSH/oh-my-zsh.sh
alias ll='\''ls -l'\''
' > $H/.zshrc
  _t_slurp $H/.zshrc
  local orig=$REPLY
  _t_install_ok "install into .zshrc without ZSH_THEME"
  _t_slurp $H/.zshrc
  local txt=$REPLY
  local -a lines
  lines=("${(@f)txt}")
  local src='source $ZSH/oh-my-zsh.sh'
  local -i i=${lines[(ie)$src]}
  assert_eq "${lines[i-1]-}" 'ZSH_THEME="emjay"' "line directly before '$src' (at line $i)"
  assert_eq "$txt" 'export ZSH="$HOME/.oh-my-zsh"
plugins=(git)
ZSH_THEME="emjay"
source $ZSH/oh-my-zsh.sh
alias ll='\''ls -l'\''
' ".zshrc after inserting ZSH_THEME, whole file"
  _t_slurp $H/.zshrc.bak
  assert_eq "$REPLY" "$orig" ".zshrc.bak equals the original .zshrc"
}

test_install_respects_zsh_custom() {
  _t_setup
  _t_install_ok "install with ZSH_CUSTOM=\$TT/cust" ZSH_CUSTOM=$TT/cust
  local link=$TT/cust/themes/emjay.zsh-theme
  assert_ok test -L $link
  assert_eq "${link:A}" "${THEME:A}" "symlink $link target (compared with :A)"
  assert_fail _t_exists $H/.oh-my-zsh/custom/themes/emjay.zsh-theme
}

test_install_zdotdir() {
  _t_setup
  assert_ok mkdir -p $TT/zd
  print -rn -- "$STD_ZSHRC" > $TT/zd/.zshrc
  _t_install_ok "install with ZDOTDIR=\$TT/zd" ZDOTDIR=$TT/zd
  _t_slurp $TT/zd/.zshrc
  assert_eq "$REPLY" "$STD_ZSHRC_AFTER" "\$ZDOTDIR/.zshrc after install, whole file"
  _t_slurp $TT/zd/.zshrc.bak
  assert_eq "$REPLY" "$STD_ZSHRC" "\$ZDOTDIR/.zshrc.bak equals the original"
  _t_slurp $H/.zshrc
  assert_eq "$REPLY" "$ORIG" "\$HOME/.zshrc untouched when ZDOTDIR is set"
  assert_fail _t_exists $H/.zshrc.bak
}

test_install_missing_omz_fails() {
  _t_setup
  _t_install ZSH=$TT/none
  local -i rc=$?
  assert_ne "$rc" 0 "install with ZSH=\$TT/none: exit status"
  _t_slurp $TT/inst.err
  assert_contains "$REPLY" "oh-my-zsh not found at $TT/none" "install with ZSH=\$TT/none: stderr"
  _t_slurp $H/.zshrc
  assert_eq "$REPLY" "$ORIG" "install with ZSH=\$TT/none: .zshrc unchanged"
  assert_fail _t_exists $H/.zshrc.bak
  assert_fail _t_exists $TT/none
}

# ------------------------------------------------- review fixes (M2 M3 m9)

# _t_rc <content>: write $H/.zshrc (exact bytes) and set ORIG to them.
_t_rc() {
  print -rn -- "$1" > $H/.zshrc
  ORIG=$1
}

test_install_zsh_custom_from_zshrc() {          # M2: unexported ZSH_CUSTOM in .zshrc
  _t_setup
  _t_rc 'export ZSH="$HOME/.oh-my-zsh"
ZSH_CUSTOM="$HOME/dotfiles/omz-custom"
ZSH_THEME="robbyrussell"
source $ZSH/oh-my-zsh.sh
'
  _t_install_ok "install with ZSH_CUSTOM only in .zshrc"
  local link=$H/dotfiles/omz-custom/themes/emjay.zsh-theme
  assert_ok test -L $link
  assert_eq "${link:A}" "${THEME:A}" "symlink $link target (compared with :A)"
  assert_fail _t_exists $H/.oh-my-zsh/custom/themes/emjay.zsh-theme
}

test_install_zsh_custom_export_with_zsh_var() {  # M2: export form, ${ZSH} expanded
  _t_setup
  _t_rc 'export ZSH="$HOME/.oh-my-zsh"
export ZSH_CUSTOM=${ZSH}/my-custom   # mine
source $ZSH/oh-my-zsh.sh
'
  _t_install_ok "install with export ZSH_CUSTOM=\${ZSH}/my-custom"
  assert_ok test -L $H/.oh-my-zsh/my-custom/themes/emjay.zsh-theme
  assert_fail _t_exists $H/.oh-my-zsh/custom/themes/emjay.zsh-theme
}

test_install_zsh_custom_unresolvable_fails() {   # M2: refuse before touching anything
  _t_setup
  _t_rc 'export ZSH="$HOME/.oh-my-zsh"
ZSH_CUSTOM="$(dotfiles-dir)/omz"
ZSH_THEME="robbyrussell"
source $ZSH/oh-my-zsh.sh
'
  _t_install
  local -i rc=$?
  assert_ne "$rc" 0 "install with an unresolvable ZSH_CUSTOM: exit status"
  _t_slurp $TT/inst.err
  assert_contains "$REPLY" "ZSH_CUSTOM" "stderr names the variable"
  assert_contains "$REPLY" "ln -s" "stderr says how to link by hand"
  _t_slurp $H/.zshrc
  assert_eq "$REPLY" "$ORIG" ".zshrc unchanged"
  assert_fail _t_exists $H/.zshrc.bak
  assert_fail _t_exists $H/.oh-my-zsh/custom/themes/emjay.zsh-theme
}

test_install_zsh_from_zshrc() {                  # M2: unexported ZSH at a non-default path
  _t_setup
  assert_ok mkdir -p $H/.config/oh-my-zsh/custom
  _t_rc 'ZSH="$HOME/.config/oh-my-zsh"
ZSH_THEME="robbyrussell"
source $ZSH/oh-my-zsh.sh
'
  _t_install_ok "install with ZSH only in .zshrc" ZSH=
  assert_ok test -L $H/.config/oh-my-zsh/custom/themes/emjay.zsh-theme
  assert_fail _t_exists $H/.oh-my-zsh/custom/themes/emjay.zsh-theme
}

test_install_zdotdir_from_zshenv() {             # M2: ZDOTDIR set in ~/.zshenv only
  _t_setup
  assert_ok mkdir -p $H/.config/zsh
  print -r -- 'export ZDOTDIR="$HOME/.config/zsh"' > $H/.zshenv
  print -rn -- "$STD_ZSHRC" > $H/.config/zsh/.zshrc
  _t_install_ok "install with ZDOTDIR only in ~/.zshenv"
  _t_slurp $H/.config/zsh/.zshrc
  assert_eq "$REPLY" "$STD_ZSHRC_AFTER" "\$ZDOTDIR/.zshrc after install, whole file"
  _t_slurp $H/.zshrc
  assert_eq "$REPLY" "$ORIG" "\$HOME/.zshrc untouched"
  _t_slurp $TT/inst.err
  assert_contains "$REPLY" "ZDOTDIR" "stderr warns about the unexported ZDOTDIR"
}

test_install_zdotdir_unresolvable_fails() {      # M2
  _t_setup
  print -r -- 'ZDOTDIR=$(find-my-zdotdir)' > $H/.zshenv
  _t_install
  local -i rc=$?
  assert_ne "$rc" 0 "install with an unresolvable ZDOTDIR in ~/.zshenv: exit status"
  _t_slurp $H/.zshrc
  assert_eq "$REPLY" "$ORIG" ".zshrc unchanged"
  assert_fail _t_exists $H/.oh-my-zsh/custom/themes/emjay.zsh-theme
}

test_install_replaces_only_the_token() {         # M3
  _t_setup
  _t_rc 'export ZSH="$HOME/.oh-my-zsh"
ZSH_THEME="agnoster"; DEFAULT_USER=me
  ZSH_THEME=robbyrussell  # old one
source $ZSH/oh-my-zsh.sh
'
  _t_install_ok "install over ZSH_THEME lines with other code"
  _t_slurp $H/.zshrc
  assert_eq "$REPLY" 'export ZSH="$HOME/.oh-my-zsh"
ZSH_THEME="emjay"; DEFAULT_USER=me
  ZSH_THEME="emjay"  # old one
source $ZSH/oh-my-zsh.sh
' ".zshrc after install, whole file"
  _t_install_ok "second install"
  _t_slurp $TT/inst.out
  assert_contains "$REPLY" "already set" "second install: stdout"
}

test_install_comment_after_emjay_is_set() {      # M3: same token parse for "already set"
  _t_setup
  _t_rc 'ZSH_THEME="emjay" # my theme
source $ZSH/oh-my-zsh.sh
'
  _t_install_ok "install over ZSH_THEME=\"emjay\" # comment"
  _t_slurp $TT/inst.out
  assert_contains "$REPLY" "already set" "stdout"
  _t_slurp $H/.zshrc
  assert_eq "$REPLY" "$ORIG" ".zshrc unchanged"
  assert_fail _t_exists $H/.zshrc.bak
}

test_install_ignores_computed_theme() {          # M3: ZSH_THEME="$1" in a function body
  _t_setup
  _t_rc 'export ZSH="$HOME/.oh-my-zsh"
set_theme() {
  ZSH_THEME="$1"
}
x=1; ZSH_THEME=$PICKED
source $ZSH/oh-my-zsh.sh
'
  _t_install_ok "install with only computed ZSH_THEME values"
  _t_slurp $H/.zshrc
  assert_eq "$REPLY" 'export ZSH="$HOME/.oh-my-zsh"
set_theme() {
  ZSH_THEME="$1"
}
x=1; ZSH_THEME=$PICKED
ZSH_THEME="emjay"
source $ZSH/oh-my-zsh.sh
' ".zshrc after install, whole file"
}

test_install_guarded_source_line() {             # m9
  _t_setup
  _t_rc 'export ZSH="$HOME/.oh-my-zsh"
[ -f $ZSH/oh-my-zsh.sh ] && source $ZSH/oh-my-zsh.sh
'
  _t_install_ok "install with a guarded source line"
  _t_slurp $H/.zshrc
  assert_eq "$REPLY" 'export ZSH="$HOME/.oh-my-zsh"
ZSH_THEME="emjay"
[ -f $ZSH/oh-my-zsh.sh ] && source $ZSH/oh-my-zsh.sh
' ".zshrc after install, whole file"
  _t_slurp $TT/inst.err
  assert_eq "$REPLY" "" "stderr"
}

test_install_no_source_line_warns() {            # m9
  _t_setup
  _t_rc 'alias ll="ls -l"
'
  _t_install_ok "install into a .zshrc that never sources oh-my-zsh"
  _t_slurp $H/.zshrc
  assert_eq "$REPLY" 'alias ll="ls -l"
ZSH_THEME="emjay"
' ".zshrc after install, whole file"
  _t_slurp $TT/inst.err
  assert_contains "$REPLY" "appended" "stderr warns that the line was appended"
}

test_install_keeps_older_backup() {              # nit: never clobber a different .zshrc.bak
  _t_setup
  print -r -- "PRECIOUS older backup" > $H/.zshrc.bak
  _t_install_ok "install with an unrelated .zshrc.bak present"
  _t_slurp $H/.zshrc.bak
  assert_eq "$REPLY" $'PRECIOUS older backup\n' ".zshrc.bak untouched"
  local -a baks
  baks=($H/.zshrc.bak.<->(N))
  assert_eq "${#baks}" 1 "number of .zshrc.bak.<epoch> files"
  _t_slurp ${baks[1]-/nonexistent}
  assert_eq "$REPLY" "$ORIG" "${baks[1]:t} equals the original .zshrc"
  _t_slurp $TT/inst.out
  assert_contains "$REPLY" "${baks[1]-<none>}" "stdout names the backup"
}

test_install_refuses_regular_file_at_link() {    # nit: a copied theme may hold local edits
  _t_setup
  assert_ok mkdir -p $H/.oh-my-zsh/custom/themes
  print -r -- "# my local tweaks" > $H/.oh-my-zsh/custom/themes/emjay.zsh-theme
  _t_install
  local -i rc=$?
  assert_ne "$rc" 0 "install over a regular file: exit status"
  assert_fail test -L $H/.oh-my-zsh/custom/themes/emjay.zsh-theme
  _t_slurp $H/.oh-my-zsh/custom/themes/emjay.zsh-theme
  assert_eq "$REPLY" $'# my local tweaks\n' "the regular file is untouched"
  _t_slurp $H/.zshrc
  assert_eq "$REPLY" "$ORIG" ".zshrc unchanged"
  assert_fail _t_exists $H/.zshrc.bak
}

run_tests
