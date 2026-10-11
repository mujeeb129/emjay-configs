# emjay: design (docs/DESIGN.md)

This design follows `docs/REQUIREMENTS.md` and does not re-open anything decided there. Two agents build from it in parallel, so every name, format and output below is binding. Paths in this document are relative to the repo root `/home/mujeeb/projects/emjay-configs`.

## 0. Key decisions

| Decision | Choice | Why |
|---|---|---|
| Async engine | **Our own `zle -F` worker. OMZ's `_omz_async_*` is not reused.** | (1) `_OMZ_ASYNC_OUTPUT[h]` keeps the old string until a new result arrives and results carry no request ID. After a `cd` to another repo, the old repo's info stays on screen for seconds on `/mnt/c`, which the requirements forbid. Fixing that means writing into OMZ's globals and depending on hook order. (2) OMZ forks one worker per registered handler on **every** precmd, non-repo dirs included, so the sync path is never fork-free. (3) It returns one opaque string, and we need structured data plus a stale check. (4) It only exists under OMZ, so tests could not run without it, and its header calls the API "subject to change". The replacement is about 50 lines using the same proven pattern (zsh-autosuggestions → OMZ): `exec {fd}< <(…)`, the worker sends its pid first, and the worker's process group is killed on cancel. |
| Prompt wiring | `PROMPT='${_emjay_prompt}'` is assigned once at load and never changed. Hooks only update `_emjay_*` variables. | With prompt_subst on, the value of a referenced variable is not re-evaluated, so a branch or context named `$(…)` cannot run code. Data is never interpolated into `PROMPT` itself. |
| Return convention | Helpers return through `REPLY`, `reply` or named globals and never print to stdout. The only exception is the worker, which writes to its pipe. | Avoids `$(…)` on the sync path. |
| Options hygiene | Every function starts with `emulate -L zsh`, plus `setopt extendedglob` where patterns need it. | Immune to user options such as `ksh_arrays` and `rematch_pcre`. |
| Minimum versions | zsh 5.8, git 2.35 (needed for the porcelain v2 `# stash` header). Apple git 2.39 is fine. Older git still works but always reports stash as 0. | |
| OMZ interplay | The theme needs nothing from OMZ. Our PROMPT contains no `$(git_prompt_info)`, so OMZ never registers its own git async handlers. RPROMPT is left alone. | |
| Parse-time safety | A prologue saves the user's `aliases`, `sh_glob`, `ignore_braces` and `ignore_close_braces`, then runs `'builtin' 'setopt' no_aliases no_sh_glob brace_expand no_ignore_braces no_ignore_close_braces`; an epilogue restores them. Hook registration runs inside `() { emulate -L zsh; … }`. | Aliases are expanded when a function body is parsed, and `sh_glob`/`ignore_braces` change the grammar, so e.g. `alias read='read -e'` or `setopt ignore_braces` would otherwise break the theme. `ksh_arrays` would break the `(Ie)` dedupe checks at top level. |
| No stray non-zero status | Nothing on the precmd, chpwd or callback path leaves a non-zero status behind: status-returning helpers are called as `f || :` or in conditions, and there are no `(( expr ))` statements that can evaluate to 0 (integer assignments are used instead). | A user `TRAPZERR` (or `ERR_EXIT` habits) would otherwise fire on every prompt. |
| Hostile repos | The worker never runs a repo-local `core.fsmonitor` hook command, and every byte of repo or kubeconfig data shown in the prompt is sanitised (control characters become `?`). | `cd` into an untrusted checkout must not run its code or let it drive the terminal. |

## 1. File layout

```
zsh/emjay.zsh-theme            # the whole theme, ~600 lines
install.sh                     # POSIX sh installer
tests/run.zsh                  # runner: runs each tests/test_*.zsh in its own `zsh -f`
tests/lib.zsh                  # assertions + sandbox + helpers; sourced by each test file
tests/fixtures/kube/*.yaml     # basic indented minikube eks gke no-current flow multi-a multi-b (Appendix A)
tests/test_format.zsh  tests/test_glyphs.zsh  tests/test_kube.zsh
tests/test_git_parse.zsh  tests/test_git_repo.zsh  tests/test_git_async.zsh
tests/test_render.zsh  tests/test_static.zsh  tests/test_install.zsh
```

Section order inside the theme file:
0. Prologue: save and pin the parse-time options (§0, "Parse-time safety").
1. Header with the config docs. The file is ASCII-only.
2. Module loads, each `2>/dev/null || :`: `zsh/datetime`, `zsh/system`, `zsh/zselect` (readiness check in `_emjay_git_cancel`), `zsh/langinfo` (codeset for glyph selection), and `zmodload -F zsh/stat b:zstat`. Use `-F` so the user's `/usr/bin/stat` is not shadowed.
3. Globals.
4. Glyphs.
5. Formatters.
6. Kube.
7. Git, pure functions.
8. Git, async.
9. Renderers.
10. Hooks.
11. Registration.
12. Epilogue: restore the options saved by the prologue and unset its temporary global `_emjay_src_opts`.

## 2. Globals

All globals are created with `typeset -g…` at load. Re-sourcing is safe: existing values are kept, any pending worker is cancelled, and hooks are not duplicated (registration uses the same `(Ie)` dedupe as `add-zsh-hook`, without autoloading it, so no non-`_emjay_` function is defined).

| Global | Type | Written by | Meaning |
|---|---|---|---|
| `_emjay_glyph` | assoc | `_emjay_glyphs_load` | slot → glyph (§3.2) |
| `_emjay_glyph_mode` | scalar | `_emjay_glyphs_load` | `unicode` / `nerd` / `ascii` |
| `_emjay_glyph_key` | scalar | `_emjay_glyphs_select` | env fingerprint `"$EMJAY_NERD_FONT|$EMJAY_ASCII|$LC_ALL|$LC_CTYPE|$LANG"` |
| `_emjay_cmd_start` | scalar | preexec / status_update | `$EPOCHREALTIME` at preexec, empty otherwise |
| `_emjay_cmd_ran` | int | preexec / status_update | 1 if a command ran since the last prompt |
| `_emjay_last_status` | int | status_update | exit code to display (0 after an empty Enter) |
| `_emjay_cmd_duration` | int | status_update | whole seconds, floored (0 after an empty Enter) |
| `_emjay_kube` | assoc | kube_update / kube_load / render_kube | keys: `key ctx ns display prod`; `display` has control characters replaced by `?` |
| `_emjay_kp_cur` | scalar | kube_parse_file | current-context of the **last parsed file** |
| `_emjay_kp_ctx` | assoc | kube_parse_file | context name → namespace for the last parsed file (namespace may be empty; key present means the context is defined) |
| `_emjay_git` | assoc | parse_status / collect / apply | keys in the table below |
| `_emjay_git_key` | scalar | git_update / chpwd | repo key of `$PWD` at the last precmd or chpwd (`""` means not a repo, or git is missing) |
| `_emjay_git_reqid` | int | git_request | monotonically increasing request ID |
| `_emjay_git_req_key` | scalar | git_request | repo key the latest request was made for |
| `_emjay_git_fd` / `_emjay_git_pid` | int | request / cancel / callback | pending worker's fd and pid; 0 means none. The pid line is read into a scalar and accepted only if it matches `<->` (reading pipe data into an integer variable would arithmetic-evaluate it) |
| `_emjay_git_worker_mode` / `_emjay_git_child` | int | worker | set only inside the worker subshell: run git as a killable coproc / that coproc's pid |
| `_emjay_bang` | int | precmd | 1 if the user has `PROMPT_BANG` on (captured before `emulate`) |
| `_emjay_redraw_pending` | int | callback / pre-redraw hook / precmd | a reset-prompt was deferred (§3.5) |
| `_emjay_zle_hooked` | int | zle_hook_install | the `zle-line-pre-redraw` hook is installed (once per shell) |
| `_emjay_seg_dir` `_emjay_seg_git` `_emjay_seg_kube` `_emjay_seg_status` `_emjay_seg_took` `_emjay_seg_char` | scalar | renderers | raw prompt-escape strings (§3.6) |
| `_emjay_line1` | scalar | assemble | line 1 |
| `_emjay_prompt` | scalar | assemble | full prompt. Before the first precmd it is `"${_emjay_glyph[prompt]} "` |

**`_emjay_git` keys.** All values are strings. Counters are decimal integers. After `_emjay_git_collect` inside a repo, all 15 keys are present. A worker that finds no repo produces exactly `(repo 0)`. When the repo key is empty the assoc is `()`.

| key | value |
|---|---|
| `repo` | `1` in a repo or git dir, otherwise `0` |
| `bare` | `1` when there is no work tree (inside `.git`, bare repo, or status failed), otherwise `0` |
| `gitdir` | absolute per-worktree git dir (`git rev-parse --absolute-git-dir`) |
| `branch` | branch name, `""` when detached. During a rebase it is the branch being rebased (from `rebase-merge/head-name` or `rebase-apply/head-name`) |
| `oid` | full HEAD OID, `""` for `(initial)` |
| `detached` | `1` / `0`. `0` during a rebase whose `head-name` names a branch (the prompt shows `⎇ <branch> … REBASE n/m`, as in the requirements mock); stays `1` when a detached HEAD is being rebased |
| `upstream` | e.g. `origin/main`, or `""` |
| `ahead` `behind` `staged` `modified` `untracked` `conflicts` `stash` | integers, default `0` |
| `op` | operation string (§3.4), or `""` |

## 3. Function contract

### 3.1 Formatters and helpers (pure, no fork)

| Signature | Output | Spec |
|---|---|---|
| `_emjay_enabled <VARNAME>` | return status | 0 (enabled) unless `${(P)VARNAME}` is exactly `0` |
| `_emjay_fmt_duration <secs>` | `REPLY` | Input is truncated to an integer. Negative or non-numeric input becomes 0. Format: under 60 → `Ns`; under 3600 → `Mm[Ss]`; under 86400 → `Hh[Mm]` (seconds dropped); otherwise `Dd[Hh]`. A **zero trailing unit is omitted**. |
| `_emjay_fmt_status <code>` | `REPLY` | If `129 ≤ code ≤ 159` and `$signals[code-127]` is non-empty and not `EXIT`, `ZERR` or `DEBUG`, return the signal name. Otherwise return the decimal code. |
| `_emjay_esc <text>` | `REPLY` | User data made safe for the prompt: control characters (`[[:cntrl:]]`) become `?`, `%` becomes `%%`, and when `_emjay_bang` is 1 (`PROMPT_BANG` on) `!` becomes `!!`. |

`_emjay_fmt_duration` exact outputs:

| in | 0 | 3 | 59 | 60 | 72 | 3599 | 3600 | 3661 | 3780 | 86399 | 86400 | 90061 | 4.9 | -5 | abc | '' |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| out | `0s` | `3s` | `59s` | `1m` | `1m12s` | `59m59s` | `1h` | `1h1m` | `1h3m` | `23h59m` | `1d` | `1d1h` | `4s` | `0s` | `0s` | `0s` |

`_emjay_fmt_status`: 1→`1`, 2→`2`, 127→`127`, 128→`128`, 130→`INT`, 137→`KILL`, 141→`PIPE`, 143→`TERM`, 200→`200`, 255→`255`.

### 3.2 Glyphs

| Signature | Effect |
|---|---|
| `_emjay_glyphs_load <unicode\|nerd\|ascii>` | Fills all 14 slots of `_emjay_glyph` and sets `_emjay_glyph_mode`. |
| `_emjay_glyphs_select` | Picks the mode: `nerd` if `EMJAY_NERD_FONT == 1`; else `ascii` if `EMJAY_ASCII == 1`; else `unicode` if `EMJAY_ASCII == 0`; else `ascii` if the shell's effective codeset `${(L)langinfo[CODESET]}` (zsh/langinfo) matches neither `*utf-8*` nor `*utf8*`; else `unicode`. Without zsh/langinfo it falls back to `${(L)${LC_ALL:-${LC_CTYPE:-$LANG}}}`. The codeset, not the variables' spelling, decides: `LC_CTYPE=UTF-8` (no such locale on Linux) leaves zsh editing in ASCII, and Unicode glyphs would then garble the line. Calls load only when `_emjay_glyph_key` (still the env string) has changed. It runs at load time, in every precmd, and at the start of each renderer that uses glyphs. |

The theme file is ASCII-only. It writes glyphs as UTF-8 **byte** escapes (`$'\xe2\x8e\x87'` for U+2387), with the code points noted beside each table; tests write the same glyphs as `$'\uXXXX'`. Byte escapes are used in the theme because a `\u` escape is converted with the locale in force when zsh converts it, which for a sourced file can be a later, non-UTF-8 one: with `LC_ALL=C EMJAY_ASCII=0` the Unicode table failed with `character not in range`. Byte escapes never depend on the locale.

| slot | unicode | nerd (Nerd Fonts v3) | ascii |
|---|---|---|---|
| `branch` | `⎇` U+2387 | U+E0A0 (nf-pl-branch) | `git` |
| `detached` | `➦` U+27A6 | U+F417 (nf-oct-git_commit) | `@` |
| `ahead` | `↑` U+2191 | U+F062 (nf-fa-arrow_up) | `^` |
| `behind` | `↓` U+2193 | U+F063 (nf-fa-arrow_down) | `v` |
| `staged` | `●` U+25CF | U+F055 (nf-fa-plus_circle) | `+` |
| `modified` | `✚` U+271A | U+F06A (nf-fa-exclamation_circle) | `*` |
| `untracked` | `…` U+2026 | U+F059 (nf-fa-question_circle) | `?` |
| `stash` | `⚑` U+2691 | U+F01C (nf-fa-inbox) | `$` |
| `conflict` | `✖` U+2716 | U+F071 (nf-fa-warning) | `!` |
| `clean` | `✔` U+2714 | U+F00C (nf-fa-check) | `ok` |
| `kube` | `⎈` U+2388 | U+F10FE (nf-md-kubernetes) | `k8s` |
| `error` | `✘` U+2718 | U+F00D (nf-fa-close) | `x` |
| `took` | `took` | U+F252 (nf-fa-hourglass_half) | `took` |
| `prompt` | `❯` U+276F | `❯` U+276F | `>` |

Two slots are additions to the requirement's glyph list: `clean` gives "clean/dirty" a visible form, and `detached` tells a short SHA apart from a branch name.

### 3.3 Kube

| Signature | Inputs | Output / effect |
|---|---|---|
| `_emjay_yaml_unquote <raw>` | — | `REPLY` (§4.3) |
| `_emjay_kube_files` | `$KUBECONFIG`, `$HOME` | `reply` = `${(s.:.)KUBECONFIG}` with empty entries dropped. If KUBECONFIG is unset or empty, `reply=("$HOME/.kube/config")`. Paths are used literally (no `~` expansion). |
| `_emjay_kube_cache_key <file>...` | files, `$KUBECONFIG` | `REPLY` (format below). Exactly one `zstat` per file; no other I/O. |
| `_emjay_kube_parse_file <path>` | file | Resets and fills `_emjay_kp_cur` and `_emjay_kp_ctx` from this file only. Returns 0 if the file is regular and readable, otherwise returns 1 with both empty. Reads with `$(<path)`, which does not fork. Never writes to stderr. |
| `_emjay_kube_load <file>...` | files | Merges in order. `ctx` = the first **non-empty** `current-context`. A context's namespace comes from the first file that defines it (presence counts, even with an empty namespace). Sets `_emjay_kube[ctx]`. Sets `_emjay_kube[ns]` to `${merged[ctx]:-default}`, or `""` when ctx is empty. Missing files are skipped. Returns 0 if ctx is non-empty. May stop early once ctx and its entry are both known. |
| `_emjay_kube_shorten <ctx>` | — | `REPLY`. For `^arn:aws[^:]*:eks:[^:]*:[0-9]*:cluster/(.+)$` → group 1. For `^gke_[^_]+_[^_]+_(.+)$` → group 1. Otherwise the input unchanged. |
| `_emjay_kube_is_prod <ctx>` | `EMJAY_KUBE_PROD_PATTERN` (default `prod|prd|live`; **an empty value disables the check**) | Returns 0 if `[[ ${(L)ctx} =~ ${(L)pat} ]] 2>/dev/null`. The match is against the **full** context name, as an ERE. An invalid regex counts as not prod and prints nothing. |
| `_emjay_kube_update` | env | If `EMJAY_SHOW_KUBE` is off: `_emjay_kube=()`, `_emjay_seg_kube=''`, return. Otherwise: `_emjay_kube_files`, then `_emjay_kube_cache_key $reply`. If `REPLY != _emjay_kube[key]`, call `_emjay_kube_load $reply` and set `_emjay_kube[key]=$REPLY`. Always finish with `_emjay_render_kube`. |
| `_emjay_render_kube` | `_emjay_kube[ctx]`, `_emjay_kube[ns]` | Sets `_emjay_kube[display]` to `"$short/$ns"` with control characters replaced by `?` (or `''`), `_emjay_kube[prod]` to `1` or `0`, and `_emjay_seg_kube` (display escaped with `_emjay_esc`). The prod check still runs on the raw full context name. |

The cache key is pinned. Tests depend on ctime **not** being part of it.

```zsh
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
}
```

### 3.4 Git, pure parts

| Signature | Output / effect |
|---|---|
| `_emjay_git_find_root [dir=$PWD]` | `REPLY` = repo key; returns 0 if found, 1 with `REPLY=''` otherwise. If `GIT_DIR` is set: `REPLY="GIT_DIR=${GIT_DIR:a}"`. Otherwise walk `d` from dir up to `/`. Return `d` at the first match of `[[ -e $d/.git ]]`, or of `[[ -f $d/HEAD && -d $d/objects && -d $d/refs ]]` (bare or inside `.git`). Pure zsh using stat tests only. From `<repo>/.git/refs` the result is `<repo>/.git`. |
| `_emjay_git_parse_status <text>` | **Pure.** Sets `_emjay_git=()`, then `repo=1`, branch, oid, detached, upstream, ahead, behind, staged, modified, untracked, conflicts, stash (defaults `''` or `0`). Does not set `bare`, `gitdir` or `op`. Rules below. |
| `_emjay_git_read_head <gitdir>` | Reads `$gitdir/HEAD`. `ref: refs/heads/X` → `branch=X`, `detached=0`. A hex OID → `branch=''`, `detached=1`, `oid=<hex>`. The reftable placeholder `ref: refs/heads/.invalid` is ignored (returns 1, keys untouched). Writes into `_emjay_git` and touches no other keys. Used by tests and as the last fallback in `collect`. |
| `_emjay_git_operation <gitdir>` | `REPLY`, checked in this order, first match wins (table below). A missing directory gives `''`. The counters are file contents, so after stripping whitespace each must match `<->` or both are dropped (an escape sequence in `msgnum` gives plain `REBASE`). |
| `_emjay_git_rebase_head <gitdir>` | `REPLY` = the branch being rebased: the first readable `rebase-merge/head-name` or `rebase-apply/head-name`, with `refs/heads/` stripped; `''` when there is none or it is not under `refs/heads/` (e.g. `detached HEAD`). |
| `_emjay_git_run <var> <git args…>` | Runs git; stdout (trailing newlines removed) into `$var`, git's status returned. In the worker (`_emjay_git_worker_mode=1`) git runs as `coproc command git …` and its pid is kept in `_emjay_git_child`, so the worker's TERM trap can kill it; otherwise it is `$(GIT_OPTIONAL_LOCKS=0 command git … 2>/dev/null)`. |
| `_emjay_git_collect` | Forks git, so call it **only** from the worker or in sync mode. Runs in `$PWD`; every git call goes through `_emjay_git_run` with `GIT_OPTIONAL_LOCKS=0`. Steps below. Returns 0 if `repo=1`. |
| `_emjay_git_serialize` | `REPLY` = one `key=value` line per key of `_emjay_git`, sorted (`${(ko)_emjay_git}`), joined with `\n`. |
| `_emjay_git_apply <payload>` | Payload format is in §3.5. Returns 1 (and changes nothing) if the payload is empty or line 1 is not equal to `$_emjay_git_reqid`. Otherwise: `_emjay_git=()`, then for each later line containing `=`, split at the first `=`. Calls `_emjay_render_git` and `_emjay_assemble`, and returns 0. |

`_emjay_git_parse_status` rules. Unknown lines are ignored; no `-z` is used, so each entry is one line.
- `# branch.oid X`: `oid = (X == "(initial)" ? "" : X)`.
- `# branch.head X`: if X is `(detached)`, then `detached=1` and `branch=''`; otherwise `branch=X`.
- `# branch.upstream U`: `upstream=U`.
- `# branch.ab +A -B`: `ahead=A`, `behind=B`.
- `# stash N`: `stash=N`.
- Lines starting `1 XY …` or `2 XY …`: if X is not `.`, increment staged; if Y is not `.`, increment modified (a file can count in both).
- `u …`: increment conflicts.
- `? …`: increment untracked.
- `! …`: ignored.

Suggested implementation is vectorised: `${#${(M)lines:#[12] [^.]?*}}` and similar.

`_emjay_git_operation` order:

| condition | REPLY |
|---|---|
| dir `rebase-merge/` | `REBASE <msgnum>/<end>`, or `REBASE` if either file is missing or empty |
| dir `rebase-apply/` + file `applying` | `AM <next>/<last>` (or `AM`) |
| dir `rebase-apply/` otherwise | `REBASE <next>/<last>` (or `REBASE`) |
| `MERGE_HEAD` | `MERGING` |
| `CHERRY_PICK_HEAD` | `CHERRY-PICKING` |
| `REVERT_HEAD` | `REVERTING` |
| `BISECT_LOG` | `BISECTING` |

`_emjay_git_collect` steps:
1. Run `rev-parse --absolute-git-dir --is-inside-work-tree`. If it fails (or prints no git dir): `_emjay_git=(repo 0)` and return 1.
2. If line 2 is `true`: read the effective `git config --get core.fsmonitor`. If it is non-empty and not a boolean (`true false yes no on off` or digits, case-insensitive), it is a hook command taken from the repo's own config, so status runs with `-c core.fsmonitor=false`; the boolean form (git's builtin daemon) is left in effect. Then, if `status --porcelain=v2 --branch --show-stash` succeeds: call `_emjay_git_parse_status "$out"` and set `bare=0`.
3. Otherwise (no work tree, or status failed): set `_emjay_git` to `repo=1`, `bare=1`, `branch=''`, `oid=''`, `detached=0`, all counters 0, upstream `''`. Then ask git for HEAD, because a reftable repo's HEAD file only holds a placeholder: `symbolic-ref -q --short HEAD` → `branch`; else `rev-parse -q --verify HEAD` → `detached=1`, `oid`; else `_emjay_git_read_head $gitdir`.
4. Set `gitdir` and `op` (from `_emjay_git_operation $gitdir`).
5. If `detached == 1` and `op` starts with `REBASE`: `_emjay_git_rebase_head $gitdir`; when that names a branch, set `branch` to it and `detached=0`.

### 3.5 Git, async worker

Wire format. The worker writes to its pipe in this order:
1. Line 1: its pid (`$sysparams[pid]`), written immediately and read synchronously by `_emjay_git_request`.
2. **One single write** at the end containing `<reqid>\n<serialized k=v lines>\n`.
3. Exit, which gives EOF.

The callback therefore sees a payload whose line 1 is the reqid. When the directory is not a repo, the payload is `<reqid>\nrepo=0\n`.

```zsh
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
```

Notes on the code above:
- `_emjay_git_update` looks up `$+commands[git]` only once `find_root` has found a repo: a miss walks the whole `$PATH` (about 10 ms on WSL, where `$PATH` carries dozens of `/mnt/c` entries), and it would otherwise run on every prompt in non-repo dirs.
- The pid line is read into a scalar and validated with `<->`. Reading pipe data into an integer variable arithmetic-evaluates it (`path[$(cmd)]` runs `cmd`).
- **Never signal a finished worker.** `_emjay_git_cancel` polls the pipe with `zselect -t 0 -r`. Readable means the worker has written its payload or exited, so its pid may already be reused and is not signalled. That payload is applied instead when it is for the repo we are still in (`_emjay_git_req_key == _emjay_git_key`). This keeps git info after `cd slowrepo; long-command`, where the callback never ran because ZLE was not reading. A worker that is still running is signalled: its process group under job control (`[[ -o monitor ]]`; `emulate -L zsh` keeps `monitor` in interactive shells), otherwise just its pid. There is no group-then-pid fallback.
- **No orphaned git without job control.** Without `monitor` the worker is not a process-group leader, and killing it alone used to leave a slow `git status` running. The worker therefore runs every git call as a coproc (`_emjay_git_run`), keeps its pid, and has `trap '… kill -TERM $_emjay_git_child …; exit 143' TERM`. The trap runs even while the worker is blocked in `read -p`.
- The worker clears any user `ZERR` trap, so a trap cannot write into the pipe. A user `TRAPEXIT`/`zshexit` does not run in the `<( )` subshell (verified).
- **Deferred redraw (`zle -F -w`).** The handler is registered as a widget, so it sees `$LASTWIDGET` and `$ISEARCHMATCH_ACTIVE`; it starts with `zle -f nolast` so it never becomes `$LASTWIDGET` itself. `_emjay_zle_busy` is true while `ISEARCHMATCH_ACTIVE == 1` or `$LASTWIDGET` matches `*complet*|menu-*|*isearch*|*history-search*`. During isearch `$LASTWIDGET` is still the widget before it, and right after isearch it names the search widget until the next key, so the flag, not the name, detects isearch. When busy, the data is applied but `reset-prompt` is deferred: `_emjay_redraw_pending=1`, and `_emjay_line_pre_redraw` performs it from `zle-line-pre-redraw` once not busy. A precmd clears the flag.
- **Installing the pre-redraw hook.** `_emjay_zle_hook_install` runs once per shell, on the first deferral. If `add-zle-hook-widget` already manages the hook (`$widgets[zle-line-pre-redraw] == user:azhw:zle-line-pre-redraw`), it registers through it. Otherwise it installs `_emjay_line_pre_redraw` directly, chaining to any existing user widget, which it copies to `_emjay_prev_line_pre_redraw`. A later `add-zle-hook-widget` keeps ours, because it preserves a pre-existing user widget. Nothing is autoloaded, so no non-`_emjay_` function is defined.
- Fd inheritance: commands started from the prompt while a worker is pending inherit its read end. That is harmless, it is closed at the next callback or precmd, and it is documented in a comment rather than worked around.

Stale protection works in five layers:
1. A change of repo key in precmd clears `_emjay_git` **before** the prompt is drawn.
2. The `chpwd` hook (`_emjay_chpwd`) does the same at the moment of the `cd`. It sets the new key, cancels the pending request and clears the segment. This also covers a widget that runs `cd` and `reset-prompt` without a precmd. It does not start a request; the next precmd does.
3. A new request cancels the previous one: the handler is removed and the fd closed. A worker that is still running is killed, together with its git child.
4. The callback re-runs `find_root`. If `$PWD`'s repo is no longer the request's (`_emjay_git_req_key`), the payload is dropped and the segment cleared.
5. `_emjay_git_apply` drops any payload whose reqid is not the latest.

A `cd` within the same repo (same key) keeps the current data until the refresh arrives, which avoids flicker.

### 3.6 Renderers and assembly

Raw segments may contain only these colour codes: `%F{…}`, `%f`, `%B`, `%b`. User data (branch names, the short OID, the operation, context names, namespaces) goes through `_emjay_esc` (§3.1): control characters become `?`, `%` is doubled, and `!` is doubled when the user has `PROMPT_BANG` on. With `PROMPT_BANG`, the ASCII conflict glyph `!` is doubled too. The separator is used verbatim. Colours are read from `EMJAY_COLOR_*` at render time (§5).

| Var | Function | Raw template | Stripped example |
|---|---|---|---|
| `_emjay_seg_dir` | `_emjay_render_dir` | `%B%F{DIR}%~%f%b`, or `''` when `EMJAY_SHOW_DIR` is off | `~/projects/api` |
| `_emjay_seg_git` | `_emjay_render_git` | `''` if the toggle is off or `repo != 1`. Otherwise these parts joined by one space: (1) head `%F{C}<g> <name>[ <clean>]%f`, where `<g> <name>` is `branch␠branch` or `detached␠${oid[1,7]}`, `C` is GIT_DIRTY if staged+modified+untracked+conflicts > 0 else GIT_CLEAN, and the ` <clean>` glyph is added only when not dirty and `bare != 1`; (2) counters in the order ahead, behind, staged, modified, untracked, stash, conflicts, each `%F{X}<glyph><n>%f` and only when n > 0; (3) op `%B%F{GIT_OP}<op>%f%b` if non-empty. Missing keys count as `''` or `0`. | `⎇ main ↑2 ↓1 ●3 ✚1 …2 ⚑1 ✖1 REBASE 2/5` |
| `_emjay_seg_kube` | `_emjay_render_kube` | `%F{KUBE}<kube> <display>%f`, or `%B%F{KUBE_PROD}<kube> <display>%f%b` when prod, or `''` | `⎈ eks-prod/payments` |
| `_emjay_seg_status` | `_emjay_render_status` | `%F{ERROR}<error> <fmt_status>%f` when the toggle is on and `_emjay_last_status != 0`, otherwise `''` | `✘ 1`, `✘ INT` |
| `_emjay_seg_took` | `_emjay_render_status` | `%F{TOOK}<took> <fmt_duration>%f` when the toggle is on and `_emjay_cmd_duration > T`, where `T = EMJAY_CMD_MAX_DURATION` if it matches `<->`, otherwise 3 | `took 4s` |
| `_emjay_seg_char` | `_emjay_render_status` | `%F{PROMPT_OK}<prompt>%f` if `_emjay_last_status == 0`, otherwise `%F{PROMPT_ERR}<prompt>%f`. Always present. | `❯` |
| `_emjay_line1` | `_emjay_assemble` | the non-empty values of [dir, git, kube, status, took] joined with `${EMJAY_SEPARATOR-  }` (unset gives two spaces; empty is allowed) | |
| `_emjay_prompt` | `_emjay_assemble` | `"$_emjay_line1"$'\n'"$_emjay_seg_char "`, or `"$_emjay_seg_char "` if line1 is empty | |

### 3.7 Hooks

```zsh
_emjay_preexec() { _emjay_cmd_start=$EPOCHREALTIME; _emjay_cmd_ran=1 }

_emjay_status_update() {   # <code> [now=$EPOCHREALTIME]
  # if _emjay_cmd_ran==1: _emjay_last_status=code; _emjay_cmd_duration = start ? int(now-start) clamped >=0 : 0
  # else (empty Enter / ^C at prompt): _emjay_last_status=0; _emjay_cmd_duration=0
  # always: _emjay_cmd_ran=0; _emjay_cmd_start=''
}

_emjay_precmd() {
  local -i code=$?           # MUST be the first statement (zsh restores $? for each precmd hook, verified)
  [[ -o prompt_bang ]] && _emjay_bang=1 || _emjay_bang=0     # before emulate resets it
  emulate -L zsh
  local REPLY; local -a reply  # never clobber the user's REPLY/reply
  _emjay_status_update $code
  _emjay_glyphs_select
  _emjay_git_update          # starts the worker first so it overlaps with the remaining sync work
  _emjay_kube_update
  _emjay_render_dir
  _emjay_render_status
  _emjay_assemble
  _emjay_redraw_pending=0    # a fresh prompt is about to be drawn anyway
  return 0
}

_emjay_chpwd() {             # cd into another repo (or out of one), also from a widget
  # if EMJAY_SHOW_GIT is on and find_root($PWD) != _emjay_git_key:
  #   _emjay_git_key=<new key>; _emjay_git_cancel; _emjay_git=(); _emjay_seg_git=''; _emjay_assemble
  # (no request is started here; the next precmd does that)
}
```

Registration at load time (no `add-zsh-hook` autoload, so the only new functions are `_emjay_*`):
```zsh
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
```

An empty Enter resets the display to neutral: green `❯`, no `✘`, no `took`. The theme defines no functions outside the `_emjay_*` namespace and sets no globals other than `_emjay_*` and `PROMPT`.

### 3.8 install.sh contract (POSIX sh, `set -eu`)

The environment always wins. Nothing is changed before every location is known and checked.

1. `src="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)/zsh/emjay.zsh-theme"`; exit 1 if it is missing.
2. **zshrc.** If `$ZDOTDIR` is set, `rc=$ZDOTDIR/.zshrc`. Otherwise, if `~/.zshenv` assigns `ZDOTDIR` (uncommented, optionally `export`ed), resolve it (rule below) and warn on stderr that it was taken from `.zshenv`. If it cannot be resolved, exit 1 with instructions, before touching anything. Otherwise `rc=$HOME/.zshrc`.
3. **oh-my-zsh.** If `$ZSH` is unset or empty, use a `ZSH=` assignment from the zshrc when it resolves (an unresolvable one exits 1), else `~/.oh-my-zsh`. If `$ZSH` is not a directory, print `emjay: oh-my-zsh not found at $ZSH` to stderr and exit 1 without changing anything.
4. **Custom dir.** `$ZSH_CUSTOM` if set; else a `ZSH_CUSTOM=` assignment in the zshrc when it resolves; else `$ZSH/custom`. If the zshrc assigns `ZSH_CUSTOM` a value that cannot be resolved, exit 1 before touching anything. The message names the variable and says how to link by hand (`ln -s <src> <your ZSH_CUSTOM>/themes/emjay.zsh-theme`) or to re-run with `ZSH_CUSTOM=…` set.
5. If `<custom>/themes/emjay.zsh-theme` exists and is **not a symlink** (a copied theme may hold local edits), exit 1 without changing anything. Then `mkdir -p "<custom>/themes"` and `ln -sfn "$src" "<custom>/themes/emjay.zsh-theme"`.
6. If `rc` is missing, exit 1 with a message.
7. Classify the `ZSH_THEME` assignments (rules below). If at least one exists and all of them are `emjay` (`"emjay"`, `'emjay'` or bare), print `already set` and exit 0. **In that case `.zshrc` and every backup are left untouched.** Example: `ZSH_THEME="emjay" # comment` counts as set.
8. Otherwise:
   - Back up with `cp -p "$rc" "$rc.bak"`. If `$rc.bak` already exists **and differs** from `$rc`, use `$rc.bak.<epoch>` instead (plus `.<pid>` if that exists too) and never overwrite the older backup. The backup path is printed.
   - **Replace:** if any counted assignment has another value, replace only the assignment token of every counted assignment with `ZSH_THEME="emjay"`. Indentation, comments and other code on the line are kept, so `ZSH_THEME="agnoster"; DEFAULT_USER=me` becomes `ZSH_THEME="emjay"; DEFAULT_USER=me`.
   - **Insert:** if there are no counted assignments, insert `ZSH_THEME="emjay"` before the first line that sources `oh-my-zsh.sh`. If no line does, append it and warn on stderr that it was appended and must come before oh-my-zsh.sh is sourced.
   - Write through `awk` to a temp file in the same directory, then `cat tmp > "$rc"` to keep symlinks and permissions, then remove tmp.
   - Comment-only lines and trailing comments are never changed.

Rules (awk, quote-aware):
- **Comment.** A comment starts at an unquoted `#` at line start or after whitespace, `;`, `&`, `|` or `(`.
- **Counted assignment.** A `ZSH_THEME=` that starts a statement: at line start, after `;`, `&` or `|`, optionally preceded by `export`. Its value token is `"…"`, `'…'`, or a bare word up to whitespace or one of `; & | )`. A value containing `$` or a backquote is computed (e.g. `ZSH_THEME="$1"` in a function body) and is neither counted nor changed.
- **Sourcing line.** "Sources oh-my-zsh.sh" means the code part contains `oh-my-zsh.sh` and the word `source` or `.`, anywhere on the line. This includes guarded forms such as `[ -f $ZSH/oh-my-zsh.sh ] && source $ZSH/oh-my-zsh.sh`.
- **Which assignment counts** (`ZDOTDIR`, `ZSH`, `ZSH_CUSTOM`): an uncommented `NAME=value` or `export NAME=value` at line start. Use the last one before the sourcing line, or the last in the file when there is no sourcing line. An empty value counts as unset.
- **Resolving a value:**
  - Only `~` (unquoted, leading), `$HOME`, `${HOME}`, `$ZSH`, `${ZSH}` and `${XDG_CONFIG_HOME:-$HOME/.config}` are expanded. `$ZSH` must not be followed by an identifier character, so `$ZSH_CUSTOM` is not expanded as `$ZSH`.
  - A single-quoted value is taken literally.
  - The result must be an absolute path with no `$`, backquote or backslash left, and no glob characters when unquoted. Otherwise the value is unresolvable.

Not allowed: `sed -i`, `readlink -f`, `stat -c`, `date -d`, `sed -r`. The awk programs live in single-quoted shell strings (`\047` for `'`), not in heredocs inside `$(…)`, which macOS `/bin/sh` (bash 3.2) misparses.

## 4. Kubeconfig parser spec (`_emjay_kube_parse_file`)

### 4.1 Line preprocessing
1. Strip one trailing `\r` (CRLF files).
2. On line 1, strip a UTF-8 BOM (`$'\xef\xbb\xbf'`).
3. Skip blank lines and lines whose first non-space character is `#`.
4. `ind` is the number of leading **spaces**.

### 4.2 State machine

A key line is `^([A-Za-z0-9_.-]+):([[:space:]]+(.*))?$`, where `$3` is the raw value.

```
state=top; ii=-1 (item indent); item=none
for each line:
  if ind==0 and body doesn't start with '-':           # top-level key
     commit_item; state=top
     current-context → if _emjay_kp_cur unset in this file: _emjay_kp_cur=unquote(val)
     contexts        → state = (unquote(val)=='' ? ctxs : top)   # `contexts: []` / `null` → no entries
     continue
  state!=ctxs → continue
  if body =~ '^-( +|$)(.*)':                           # sequence item
     ii<0 → ii=ind
     ind!=ii → continue                                # nested list (e.g. extensions:)
     commit_item; item=new; ic = column of first non-space after '-' ; in_ctx=0; cc=-1
     body=rest; ind=ic; rest empty → continue
  item==none or body not a key line → continue
  if ind==ic:   in_ctx=0
                name    → item.name=unquote(val)
                context → if unquote(val)=='' : in_ctx=1; cc=-1     # flow `{...}` → ignored
  elif ind>ic and in_ctx:
                cc<0 → cc=ind
                ind==cc and key==namespace → item.ns=unquote(val)
EOF: commit_item
commit_item: if item.name!='' and !(( ${+_emjay_kp_ctx[$item.name]} )): _emjay_kp_ctx[$item.name]=item.ns
```

What this supports:
- kubectl, aws-cli and gcloud style: zero-indented sequences (`- context:` at column 0), 2-space mappings.
- Indented sequences (`  - name:`).
- `name` before or after `context`.
- Context children at any indent greater than `ic`.
- Nested `extensions:` lists inside a context. Their inner `name:` keys are ignored because they sit at other indents.
- `namespace:` before or after `extensions:`.
- Top-level keys in any order.
- `---` document markers are harmless and ignored.

### 4.3 `_emjay_yaml_unquote <raw>` → REPLY
- Trim leading whitespace.
- `"…"`: content up to the first unescaped `"`. Unescape `\"` → `"` and `\\` → `\`. Any text after the closing quote (such as a comment) is dropped.
- `'…'`: content up to the first `'` that is not part of `''`. `''` → `'`.
- Unterminated quote: the rest of the line after the quote, with trailing whitespace trimmed.
- Plain value: cut at the first whitespace followed by `#`, then trim trailing whitespace. `~`, `null`, `Null` and `NULL` become `''`.

| raw | REPLY |
|---|---|
| `foo` | `foo` |
| `  foo  ` | `foo` |
| `foo # c` | `foo` |
| `foo#bar` | `foo#bar` |
| `"foo bar"` | `foo bar` |
| `"a\"b" # c` | `a"b` |
| `'it''s'` | `it's` |
| `'x'  # c` | `x` |
| `""` | `` |
| `~` | `` |
| `null` | `` |
| `"unterminated` | `unterminated` |
| `arn:aws:eks:us-east-1:1:cluster/x` | same |

### 4.4 Out of scope

Out-of-scope input is handled gracefully: no error, and namespace falls back to `default`.
- Flow mappings and sequences (`context: {namespace: x}`).
- JSON kubeconfigs.
- Tab indentation.
- Anchors and aliases.
- Block scalars (`|`, `>`).
- Quoted keys.
- A bare `-` on its own line.
- Multi-document merging.
- `~` expansion in KUBECONFIG entries.
- Windows `C:\` paths.
- Escapes other than `\"` and `\\`.

## 5. Configuration (all optional; read at every render)

| Var | Default | Meaning |
|---|---|---|
| `EMJAY_NERD_FONT` | unset | `1` turns on Nerd Font glyphs |
| `EMJAY_ASCII` | unset (auto) | `1` forces ASCII; `0` forces Unicode; unset picks ASCII when the shell's effective codeset (`$langinfo[CODESET]`) is not UTF-8 |
| `EMJAY_KUBE_PROD_PATTERN` | `prod\|prd\|live` | case-insensitive ERE on the full context name; empty disables |
| `EMJAY_CMD_MAX_DURATION` | `3` | show `took` when whole seconds exceed N (integers only; invalid values fall back to 3) |
| `EMJAY_SHOW_DIR` / `_GIT` / `_KUBE` / `_STATUS` / `_DURATION` | on | `0` hides that segment (and for GIT and KUBE, skips the work) |
| `EMJAY_GIT_ASYNC` | `1` | `0` collects git synchronously in precmd (tests and debugging) |
| `EMJAY_SEPARATOR` | two spaces | separator between segments on line 1 |

Palette. Each value goes into `%F{…}`, so 256-colour numbers or colour names both work.

| Var | Default | Used for |
|---|---|---|
| `EMJAY_COLOR_DIR` | 39 | directory (bold) |
| `EMJAY_COLOR_GIT_CLEAN` | 76 | head and ✔ when clean |
| `EMJAY_COLOR_GIT_DIRTY` | 178 | head when dirty |
| `EMJAY_COLOR_GIT_SYNC` | 75 | ↑ ↓ |
| `EMJAY_COLOR_GIT_STAGED` | 76 | ● |
| `EMJAY_COLOR_GIT_MODIFIED` | 214 | ✚ |
| `EMJAY_COLOR_GIT_UNTRACKED` | 244 | … |
| `EMJAY_COLOR_GIT_STASH` | 141 | ⚑ |
| `EMJAY_COLOR_GIT_CONFLICT` | 196 | ✖ |
| `EMJAY_COLOR_GIT_OP` | 208 | operation (bold) |
| `EMJAY_COLOR_KUBE` | 33 | kube |
| `EMJAY_COLOR_KUBE_PROD` | 196 | kube when prod (bold) |
| `EMJAY_COLOR_ERROR` | 196 | ✘ code |
| `EMJAY_COLOR_TOOK` | 178 | took |
| `EMJAY_COLOR_PROMPT_OK` | 76 | ❯ after success |
| `EMJAY_COLOR_PROMPT_ERR` | 196 | ❯ after failure |

## 6. Edge cases

| Case | Handled by |
|---|---|
| Non-repo dir: no fork, segment hidden | `_emjay_git_find_root` → `''` → `_emjay_git_update` |
| `git init` / `rm -rf .git` in the current dir | `find_root` re-walks on every precmd |
| Fresh repo with no commits | `parse_status`: `(initial)` gives `oid=''`, branch from `branch.head` |
| Detached HEAD | `parse_status` sets `detached=1`; `render_git` shows `➦ sha7` |
| During a rebase (HEAD detached) | `collect` reads `head-name`: `⎇ topic ✖1 REBASE 1/2`. A rebase of a detached HEAD keeps `➦ sha7` |
| Worktree or submodule (`.git` is a file) | `find_root` uses `-e .git`; `collect` gets the per-worktree `--absolute-git-dir`; the operation is read from that dir |
| Inside `.git` or a bare repo | `find_root` (HEAD+objects+refs); `collect` sees `is-inside-work-tree=false` → `bare=1`, HEAD from `symbolic-ref`/`rev-parse` (reftable repos keep only `ref: refs/heads/.invalid` in the HEAD file), no ✔ |
| No upstream, or upstream gone | `parse_status`: ahead and behind default to 0 |
| `cd` to another repo with a request pending | `chpwd` and `git_update` clear on key change; `git_request` cancels; the callback re-checks the repo; `git_apply` checks reqid |
| A widget runs `cd` + `reset-prompt` (no precmd) | `chpwd` clears the segment at once; a late result for the old repo is dropped by the callback |
| `cd slowrepo; long-command` (callback never ran) | next precmd: `cancel` finds the pipe readable, applies the finished same-repo result, never signals the (possibly reused) pid |
| Cancelled worker without job control (`no_monitor`) | the worker's TERM trap kills its coproc git; no orphaned `git status` |
| Completion list, menu-select or Ctrl-R on screen when git info arrives | data applied, `reset-prompt` deferred to `zle-line-pre-redraw` |
| `cd` within the same repo | same key, data kept |
| git missing | `git_update` checks `$+commands[git]`, only inside a repo (a miss walks all of `$PATH`) |
| Repo-local `core.fsmonitor` hook command (untrusted checkout) | status runs with `-c core.fsmonitor=false`; boolean `true` (builtin daemon) is kept |
| Control characters / escape sequences in branch, op counters, context or namespace | `_emjay_esc` turns them into `?`; op counters must be digits |
| User has `PROMPT_BANG` on | `!` in user data (and the ASCII conflict glyph) doubled |
| User `TRAPZERR`, aliases (`read`, `cd`, `git`), `sh_glob`, `ignore_braces`, `ksh_arrays` | no non-zero status on the prompt path; parse-time prologue/epilogue; `emulate -L zsh` |
| Dubious ownership on `/mnt/c`, or broken repo | `collect`: rev-parse fails → `repo=0` → hidden |
| `git status` fails inside a work tree | `collect` falls back to `read_head` |
| `%` or `$(…)` in a branch, context or namespace | renderers escape `%`; `PROMPT` is a static reference |
| Worker hangs on a slow filesystem | ZLE is never blocked; the next request kills it |
| Huge status output | vectorised parse inside the async worker |
| KUBECONFIG unset, empty, `a::b`, or trailing `:` | `_emjay_kube_files` |
| Kubeconfig missing, a directory, or unreadable | `parse_file` returns 1; the key gets `\t-`; hidden |
| Symlinked kubeconfig (WSL → `/mnt/c`) | `zstat` without `-L` follows the link |
| current-context empty, `""` or `null` | `yaml_unquote` + `kube_load` → hidden |
| current-context names an undefined context | `kube_load` → `ctx/default` |
| Context defined in a later file | `kube_load` merge |
| CRLF, BOM, comments, quotes | `parse_file` / `yaml_unquote` |
| `name:` nested under `extensions` | indent tracking in `parse_file` |
| Invalid or empty prod regex | `kube_is_prod` |
| User options (`ksh_arrays`, `rematch_pcre`, `err_exit`) | `emulate -L zsh` everywhere |
| `LC_CTYPE=UTF-8` on Linux (invalid locale, zsh edits in ASCII) | `glyphs_select` uses `$langinfo[CODESET]` → ascii |
| Empty Enter or ^C at the prompt | `status_update` (`_emjay_cmd_ran=0`) |
| Signal exits (130 etc.), exit ≥ 160 | `fmt_status` |
| Non-UTF-8 locale or codeset | `glyphs_select` → ascii |
| Mode or env changed at runtime | `glyphs_select` fingerprint; colours and toggles read at render |
| Every segment empty | `assemble` gives a single-line prompt |
| Theme re-sourced | `add-zsh-hook` dedupes; `_emjay_git_cancel` at load |
| `/tmp` → `/private/tmp` on macOS | tests compare paths with `:A` |

## 7. Performance

The sync path is everything in `_emjay_precmd`.

| Step | Cost | Forks |
|---|---|---|
| status / duration | float arithmetic on `$EPOCHREALTIME` | 0 |
| glyphs | one string comparison | 0 |
| dir | constant `%~` | 0 |
| git, non-repo | ≤ 3 `[[ -e/-f/-d ]]` checks per ancestor; no `$commands[git]` lookup | **0** (no worker) |
| git, repo | `find_root`, `$+commands[git]`, then `exec {fd}< <(…)` and a blocking read of the pid line (the child writes it at once) | 1 (unavoidable); the worker then runs 3 git calls (rev-parse, config, status) off the prompt path |
| kube | one `zstat` per file plus a key comparison. A parse (`$(<f)`, measured fork-free at 2 µs) only happens when the key changes. | 0 |
| renderers / assemble | parameter expansion only | 0 |

There are no `$(…)` command substitutions, backticks, `print -P` calls or external commands on this path. The test `test_precmd_works_with_empty_path` enforces it. The worker uses `GIT_OPTIONAL_LOCKS=0` so it never writes `index.lock`, and it respects `status.showUntrackedFiles`. Target: a non-repo precmd under 1 ms on WSL, with a test budget of under 10 ms.

## 8. Test-mode hooks and harness

- **The theme is sourceable in `zsh -f` without OMZ** and prints nothing. No stubs are needed, because it autoloads `add-zsh-hook` and loads its modules itself.
- `EMJAY_GIT_ASYNC=0` makes `_emjay_precmd` fully synchronous.
- With async on in a script (no ZLE), `zle -F` is inert. The test drains a request with `_emjay_git_callback $_emjay_git_fd`, which blocks until the worker exits. Calling `zle .reset-prompt` fails silently there.
- Deterministic timing: set `_emjay_cmd_ran=1 _emjay_cmd_start=100`, then call `_emjay_status_update <code> <now>`.

**`tests/run.zsh`**
- `zsh tests/run.zsh [files…]` defaults to `tests/test_*.zsh`, sorted.
- Each file runs as `zsh -f <file>`, and the runner prints its output.
- Prints a summary line `N files, P passed, F failed`.
- Exits 1 if any file failed.
- `EMJAY_TEST_FILTER=<glob>` limits which test functions run.

**`tests/lib.zsh`** is sourced at the top of each test file. On load it:
1. Sets `setopt extendedglob`.
2. Computes `EMJAY_ROOT=${${(%):-%x}:A:h:h}`.
3. Unsets every `EMJAY_*` except `EMJAY_ROOT`, plus `KUBECONFIG GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE`.
4. Exports a UTF-8 locale if the current one is not UTF-8 (`C.UTF-8` on linux*, `en_US.UTF-8` on darwin*).
5. Creates `T=$(mktemp -d "${TMPDIR:-/tmp}"/emjay-test.XXXXXX)` (strip a trailing `/` from TMPDIR first) and registers an EXIT trap that removes it.
6. Aborts if `_emjay_git_find_root $T` finds a repo.
7. Exports `GIT_CONFIG_NOSYSTEM=1`, `GIT_CONFIG_GLOBAL=$T/gitconfig`, `GIT_EDITOR=:`, `GIT_PAGER=cat`.
8. Writes that gitconfig with `user.name`, `user.email`, `init.defaultBranch=main`, `advice.detachedHead=false`, `commit.gpgSign=false`, `protocol.file.allow=always`, `core.autocrlf=false`.
9. Sources the theme and sets `EMJAY_GIT_ASYNC=0`.

Helper API:

| Helper | Behaviour |
|---|---|
| `run_tests` | For each name in `${(ok)functions[(I)test_*]}` (filtered): `TT=$T/<name>`, `mkdir -p $TT/home`, then `( HOME=$TT/home; cd $TT; _t_failed=0; <name>; exit $_t_failed )`. Prints `ok N - name` or `not ok N - name`, and returns 1 on any failure. |
| `assert_eq <actual> <expected> [msg]`, `assert_ne`, `assert_match <actual> <zsh-glob>`, `assert_empty`, `assert_nonempty`, `assert_contains <hay> <needle>`, `assert_not_contains`, `assert_ok <cmd…>`, `assert_fail <cmd…>` | On failure print `  FAIL: msg: expected 'x' got 'y'` to stderr and set `_t_failed=1`. They never exit early. |
| `strip_prompt <raw>` | `REPLY`: remove `%F{…}`, then `%f`, `%B`, `%b`; then `REPLY=${(%)s}`, which expands `%~` and turns `%%` into `%`. |
| `seg_text <dir\|git\|kube\|status\|took\|char\|line1\|prompt>` | `REPLY` = `strip_prompt` of `_emjay_seg_<n>`, `_emjay_line1` or `_emjay_prompt` |
| `mkrepo <dir> [branch=main]` | `git init -q -b <branch>`, write `a.txt` containing `a`, add, `commit -qm init` |
| `mkrepo_empty <dir>` | init only |
| `kube_fixture <name>` | `REPLY=$EMJAY_ROOT/tests/fixtures/kube/<name>.yaml`. Copy into `$TT` before modifying. |
| `capture_err <cmd…>` | runs the command in the current shell with stderr sent to `$TT/.err`; `REPLY` = that file's contents |

## 9. Test plan

Each item is one `test_*` function. Rendered segments are compared after `seg_text`. Unicode glyphs are the defaults unless the test says otherwise.

### tests/test_format.zsh
| Test | Setup | Expected |
|---|---|---|
| `test_duration_table` | each input from §3.1 | exact table outputs |
| `test_status_codes` | 1 2 127 128 130 137 141 143 200 255 | `1 2 127 128 INT KILL PIPE TERM 200 255` |
| `test_status_update_success` | ran=1, start=100; `_emjay_status_update 0 101` | last_status=0, duration=1, ran=0, start='' |
| `test_status_update_failure_duration` | ran=1, start=100; `update 1 172.5` | last_status=1, duration=72 |
| `test_status_update_empty_enter` | ran=0, start=''; `update 1` | last_status=0, duration=0 |
| `test_status_update_floor` | ran=1, start=100; `update 0 103.99` | duration=3 |

### tests/test_glyphs.zsh
| Test | Setup | Expected |
|---|---|---|
| `test_default_unicode` | no EMJAY vars; `_emjay_glyphs_select` | mode `unicode`; all 14 slots match §3.2 |
| `test_nerd_mode` | `EMJAY_NERD_FONT=1` | mode `nerd`; all 14 slots |
| `test_ascii_forced` | `EMJAY_ASCII=1` | mode `ascii`; all 14 slots |
| `test_ascii_auto_c_locale` | `LC_ALL=C` | `ascii` |
| `test_ascii_zero_overrides_locale` | `LC_ALL=C EMJAY_ASCII=0` | `unicode` |
| `test_nerd_beats_ascii` | `EMJAY_NERD_FONT=1 EMJAY_ASCII=1` | `nerd` |
| `test_switch_back_without_resource` | nerd, select, `unset EMJAY_NERD_FONT`, select | `unicode` |
| `test_render_git_nerd` | `_emjay_git=(repo 1 bare 0 branch main detached 0)`, nerd; `_emjay_render_git` | `$'\ue0a0 main \uf00c'` |
| `test_precmd_applies_mode` | `EMJAY_NERD_FONT=1; _emjay_precmd` | `_emjay_glyph_mode == nerd` |
| `test_ascii_when_codeset_not_utf8` | `LC_ALL=C`, then `LC_ALL=xx_XX.UTF-8` (no such locale: the codeset stays ASCII); select; then `EMJAY_ASCII=0` | setting it prints nothing; mode `ascii` although the name says UTF-8; then `unicode` with the right glyph bytes (m2) |

### tests/test_kube.zsh
Unless stated otherwise: `unset KUBECONFIG`, and `HOME=$TT/home` has no `.kube`.

| Test | Setup | Expected |
|---|---|---|
| `test_default_path` | copy `basic` → `$HOME/.kube/config`; `_emjay_kube_update` | ctx `dev`, ns `team-a`, display `dev/team-a`, prod `0`, seg `⎈ dev/team-a` |
| `test_kubeconfig_single` | `KUBECONFIG=<basic>` | display `dev/team-a` |
| `test_missing_namespace` | copy of basic with `current-context: kind-kind` | `kind-kind/default` |
| `test_indented_quoted_comments` | `indented` | `prod-eu/payments`, prod 1. Then `_emjay_kube_parse_file <indented>`: `_emjay_kp_ctx[staging]==web` and `${+_emjay_kp_ctx[should-not-match]}==0` |
| `test_minikube_extensions` | `minikube`; plus `parse_file` | `minikube/kube-system`; `${(k)_emjay_kp_ctx}` is exactly `minikube` |
| `test_eks_arn` | `eks` | ctx is the full ARN; display `payments-prod/checkout`; prod 1 |
| `test_gke` | `gke` | `web/default`, prod 0 |
| `test_no_current_context` | `no-current` | ctx '', display '', seg '' |
| `test_missing_file` | `KUBECONFIG=$TT/nope.yaml`; `capture_err _emjay_kube_update` | seg ''; stderr '' |
| `test_no_kubeconfig_at_all` | nothing set | seg '' |
| `test_multi_first_current_wins` | `KUBECONFIG=a:b` (multi-a, multi-b) | `shared/ops` |
| `test_multi_reverse_undefined_ctx` | `KUBECONFIG=b:a` | `other/default` |
| `test_multi_first_context_wins` | `$TT/c.yaml` = `current-context: local`; `KUBECONFIG=c:a:b`, then `c:b:a` | `local/from-a`, then `local/from-b` |
| `test_multi_skips_missing_empty` | `KUBECONFIG="$TT/nope::a:b:"` | `shared/ops` |
| `test_crlf` | basic rewritten with `\r\n` line endings | `dev/team-a`; `_emjay_kube[ns]` is exactly `team-a` |
| `test_bom` | `$'\xef\xbb\xbf'` + `current-context: dev` + newline + basic with its own current-context line removed | `dev/team-a` |
| `test_flow_style_graceful` | `flow` with `capture_err` | `flowy/default`; stderr '' |
| `test_empty_contexts_list` | `current-context: solo` + newline + `contexts: []` | `solo/default` |
| `test_yaml_unquote_table` | §4.3 rows | exact |
| `test_shorten_table` | `arn:aws:eks:us-east-1:123456789012:cluster/payments-prod`→`payments-prod`; `arn:aws-cn:eks:cn-north-1:123456789012:cluster/x`→`x`; `arn:aws-us-gov:eks:us-gov-west-1:1:cluster/a/b`→`a/b`; `gke_my-proj_europe-west1-b_web`→`web`; `gke_bad`→`gke_bad`; `kind-kind`→same; `arn:aws:iam::1:role/r`→same; `me@eks.us-east-1.eksctl.io`→same | exact |
| `test_prod_default_pattern` | `_emjay_kube_is_prod` on `prod-eu` `PRD-1` `live` `eks-Live` | each returns 0 |
| `test_prod_default_negative` | `staging`, `dev` | each returns 1 |
| `test_prod_custom_pattern` | `EMJAY_KUBE_PROD_PATTERN='^prd-'` | `prd-x` → 0, `prod-x` → 1 |
| `test_prod_empty_pattern` | `EMJAY_KUBE_PROD_PATTERN=''` | `prod` → 1 |
| `test_prod_invalid_regex` | pattern `(`; `capture_err _emjay_kube_is_prod prod` | returns 1; stderr '' |
| `test_prod_matches_full_name` | file with ctx `gke_acme-prod_us-east1-b_web` | display `web/default`, prod 1 |
| `test_prod_colors` | eks fixture | raw seg contains `%B` and `%F{196}`. With `EMJAY_COLOR_KUBE_PROD=160` and `_emjay_render_kube`: contains `%F{160}`. gke fixture: contains `%F{33}` and not `%B` |
| `test_cache_hit_no_reparse` | `$TT/k.yaml` with `current-context: aaa`; `touch -t 202001010000`; update → `aaa/default`. Rewrite in place with `bbb` (same size, same inode via `>`), `touch -t 202001010000`, update | still `aaa/default` |
| `test_cache_mtime_invalidates` | continue the previous setup with `touch -t 202001010001`, update | `bbb/default` |
| `test_cache_kubeconfig_value_invalidates` | `KUBECONFIG=a` → `shared/default`; then `KUBECONFIG=a:b` | `shared/ops` |
| `test_use_context_simulation` | basic copy → `dev/team-a`; rewrite with `current-context: kind-kind`; update | `kind-kind/default` |
| `test_show_toggle` | basic at default path, `EMJAY_SHOW_KUBE=0` | seg '', `_emjay_kube[display]` '' |
| `test_no_kubectl_calls` | `$TT/bin/kubectl` and `kubectl.exe` are `#!/bin/sh` scripts that create `$TT/called`; `PATH=$TT/bin:$PATH; rehash`; basic at default path; `_emjay_precmd` | `$TT/called` does not exist |
| `test_ctx_name_not_evaluated` | `current-context: 'x$(:>pwned)%F'`; `_emjay_precmd`; `: ${(%%)PROMPT}` | `$TT/pwned` does not exist; seg `⎈ x$(:>pwned)%F/default` |
| `test_ctx_control_chars` | context and namespace containing ESC/BEL bytes | no ESC/BEL in the raw seg; display `x?]0;t?y/n?[2Js` (m4) |
| `test_prompt_bang_escapes_names` | `current-context: 'a!b'`; `setopt prompt_bang`; precmd; then `unsetopt prompt_bang`; precmd | raw seg contains `a!!b` and `${(%%)seg}` contains `a!b`; without PROMPT_BANG the raw seg has `a!b` |

### tests/test_git_parse.zsh (no git needed)
The Appendix B texts are used as input.

| Test | Expected |
|---|---|
| `test_parse_clean_upstream` (B1) | branch `main`, oid `1234567890abcdef1234567890abcdef12345678`, upstream `origin/main`, ahead 0, behind 0, other counters 0, detached 0, repo 1 |
| `test_parse_full` (B2) | branch `feature/x`, upstream `origin/feature/x`, ahead 2, behind 1, staged 4, modified 3, untracked 2, conflicts 1, stash 1. Then set `bare=0`, `_emjay_render_git` → `⎇ feature/x ↑2 ↓1 ●4 ✚3 …2 ⚑1 ✖1` |
| `test_parse_initial` (B3) | oid '', branch `main`, untracked 1 |
| `test_parse_detached` (B4) | branch '', detached 1, oid = full hex |
| `test_parse_upstream_gone` (B5) | upstream `origin/gone`, ahead 0, behind 0 |
| `test_parse_empty` (`''`) | repo 1, branch '', all counters 0 |
| `test_parse_resets_previous` | B2 then B1 | counters back to 0, stash 0 |
| `test_parse_quoted_paths` (B6) | modified 1, untracked 1 |
| `test_parse_many_untracked` | header plus 5000 lines `? f$i` | untracked 5000 in under 2 s |
| `test_op_rebase_merge` | `$TT/g/rebase-merge/msgnum`=`2`, `end`=`5` | `REBASE 2/5` |
| `test_op_rebase_merge_no_counts` | empty `rebase-merge/` | `REBASE` |
| `test_op_rebase_apply` | `rebase-apply/{next=3,last=4,rebasing}` | `REBASE 3/4` |
| `test_op_am` | `rebase-apply/{next=1,last=3,applying}` | `AM 1/3` |
| `test_op_merge` / `_cherry` / `_revert` / `_bisect` | `MERGE_HEAD` / `CHERRY_PICK_HEAD` / `REVERT_HEAD` / `BISECT_LOG` | `MERGING` / `CHERRY-PICKING` / `REVERTING` / `BISECTING` |
| `test_op_precedence` | `rebase-merge/{1,2}` + `MERGE_HEAD` → `REBASE 1/2`; separately `MERGE_HEAD` + `BISECT_LOG` → `MERGING` | as stated |
| `test_op_none` | empty dir; nonexistent dir | `''` for both |
| `test_read_head_branch` | HEAD = `ref: refs/heads/feature/x` | branch `feature/x`, detached 0 |
| `test_read_head_detached` | HEAD = 40-hex | detached 1, oid = hex, branch '' |
| `test_find_root_*` | dirs built with `mkdir`: `r/.git/`; `r/a/b`; `r/.git/{HEAD,objects/,refs/}` and then from `r/.git/refs`; `wt/.git` as a file; `plain/`; `GIT_DIR=$TT/x.git` | `$TT/r` from `r` and from `r/a/b`; `$TT/r/.git` from `r/.git/refs`; `$TT/wt`; `''` with status 1; `GIT_DIR=$TT/x.git` |
| `test_render_clean` | `(repo 1 bare 0 branch main detached 0)` | `⎇ main ✔`; raw contains `%F{76}` |
| `test_render_requirements_example` | ahead 2, behind 1, staged 3, modified 1, untracked 2, stash 1, conflicts 1, op `REBASE 2/5` | `⎇ main ↑2 ↓1 ●3 ✚1 …2 ⚑1 ✖1 REBASE 2/5`; head raw contains `%F{178}` |
| `test_render_clean_ahead_stash` | ahead 1, stash 2 | `⎇ main ✔ ↑1 ⚑2` |
| `test_render_detached` | detached 1, oid `abc1234def…` | `➦ abc1234 ✔` |
| `test_render_bare` / `_bare_op` | bare 1, branch main / plus op `MERGING` | `⎇ main` / `⎇ main MERGING` |
| `test_render_not_repo` | `(repo 0)` and `()` | `''` |
| `test_render_toggle_off` | `EMJAY_SHOW_GIT=0` | `''` |
| `test_render_percent_escape` | branch `a%b` | raw contains `a%%b`; stripped `⎇ a%b ✔` |
| `test_serialize_roundtrip` | full assoc → `payload="$_emjay_git_reqid"$'\n'$REPLY`; `_emjay_git=()`; `_emjay_git_apply $payload` | returns 0; assoc equal to the original |
| `test_apply_rejects_stale` | `_emjay_git_reqid=5`; payload line 1 = `4` | returns 1; assoc unchanged |
| `test_apply_rejects_garbage` | `''`, `abc\nrepo=1` | returns 1 for both |
| `test_render_control_chars` | branch and op with ESC, BEL, CR | none of them in the raw seg; stripped `⎇ a?[31mb? ✔ X?Y?` (m4) |
| `test_op_counters_must_be_numbers` | `msgnum` = ESC sequence; `last` = `3x` | `REBASE` for both (m4) |
| `test_rebase_head_name` | `head-name` in rebase-merge / rebase-apply / `detached HEAD` / none | `feature/x`, `topic`, `''`, `''` |
| `test_read_head_reftable_placeholder` | HEAD = `ref: refs/heads/.invalid` | returns 1, keys unchanged |

### tests/test_git_repo.zsh (real git, sync)
Each test builds its repos under `$TT`, `cd`s, and calls `_emjay_precmd`. `sha7` means `${$(git rev-parse HEAD)[1,7]}`.

| Test | Setup | Expected seg / keys |
|---|---|---|
| `test_nonrepo` | `$TT/plain` | seg '', `_emjay_git_key` '', `${#_emjay_git}==0` |
| `test_fresh_no_commits` | `mkrepo_empty` | `⎇ main ✔`, oid '' |
| `test_fresh_untracked` | plus `u` | `⎇ main …1` |
| `test_clean_no_upstream` | `mkrepo` | `⎇ main ✔`, upstream '' |
| `test_dirty_counts` | add `b.txt`; append to `a.txt` (not added); create `u1` and `u2` | `⎇ main ●1 ✚1 …2` |
| `test_ahead_behind` | `checkout -qb feature --track main`; 2 commits; on main 1 commit; back to feature | `⎇ feature ✔ ↑2 ↓1`, upstream `main` |
| `test_stash` | modify `a.txt`; `git stash -q` | `⎇ main ✔ ⚑1` |
| `test_detached` | `checkout -q --detach` | `➦ <sha7> ✔`, detached 1 |
| `test_merge_conflict` | branch `other` changes `a.txt`; main changes it differently; `git merge other` | `⎇ main ✖1 MERGING` |
| `test_cherry_pick_conflict` | same setup; `git cherry-pick other` | `⎇ main ✖1 CHERRY-PICKING` |
| `test_rebase_conflict` | `f`=base on main; topic: `f`=t1, then add `g`; main: `f`=m1; on topic `git rebase main` | `⎇ topic ✖1 REBASE 1/2` (branch from `head-name`, as in the requirements mock), `detached` 0, head in the dirty colour |
| `test_rebase_detached_start_keeps_sha` | as above but `checkout --detach topic` before rebasing | `➦ <sha7 of main> ✖1 REBASE 1/1` |
| `test_bisect` | `git bisect start` | `⎇ main ✔ BISECTING` |
| `test_inside_dot_git` | cd `r/.git`, then `r/.git/refs` | `⎇ main`, bare 1, key `$TT/r/.git` |
| `test_worktree` | `git -C r worktree add -q $TT/wt -b feature`; cd `wt` | `⎇ feature ✔`; `${_emjay_git[gitdir]:A} == ${:-$TT/r/.git/worktrees/wt}:A`; key `$TT/wt` |
| `test_submodule` | `mkrepo subsrc`, `mkrepo super`; `git -C super submodule add -q $TT/subsrc sub` | in `super/sub`: `⎇ main ✔`, gitdir `:A` = `super/.git/modules/sub`. After `checkout -q --detach`: `➦ <sha7> ✔`. In `super`: `⎇ main ●2` |
| `test_subdir_same_key` | cd `r/x/y` | same seg as at the root; key `$TT/r` |
| `test_show_git_off` | `EMJAY_SHOW_GIT=0` | seg '', `${#_emjay_git}==0` |
| `test_git_missing` | `PATH=$TT/emptybin` (empty dir) inside a repo; `capture_err _emjay_precmd` | seg ''; stderr '' |
| `test_branch_name_not_evaluated` | `checkout -qb 'x$(echo>pwned)%F'` (`:` is not allowed in a ref name, so the original `x$(:>pwned)%F` cannot be created); precmd; `: ${(%%)PROMPT}` | no `pwned`; seg `⎇ x$(echo>pwned)%F ✔` |
| `test_fsmonitor_hook_not_run` | `core.fsmonitor` = a script that creates `pwned`; precmd | `⎇ main ✔`, no `pwned`; control: plain `git status` then does create it (m5) |
| `test_fsmonitor_boolean_kept` | `core.fsmonitor=true`, git wrapper logging its arguments | the status call has no `core.fsmonitor=false` (m5) |
| `test_reftable_head` (skipped without reftable) | `init --ref-format=reftable`; work tree, `.git`, `.git` detached, bare clone | `⎇ main ✔`, `⎇ main`, `➦ <sha7>`, `⎇ main` |

### tests/test_git_async.zsh (`EMJAY_GIT_ASYNC=1`)
Setup: `mkrepo $TT/A alpha`, `mkrepo $TT/B beta`, `mkdir -p $TT/A/sub $TT/plain`.

| Test | Steps | Expected |
|---|---|---|
| `test_async_fills_after_callback` | cd A; precmd | `_emjay_git_fd > 0`, seg '' |
| | then `_emjay_git_callback $_emjay_git_fd` | seg `⎇ alpha ✔`, `_emjay_git_fd == 0` |
| `test_async_cd_clears_immediately` | A: precmd and drain; cd B; precmd | seg '' and `_emjay_prompt` does not contain `alpha` |
| | drain | `⎇ beta ✔` |
| `test_async_pending_cancelled` | cd A; precmd (not drained); `id=$_emjay_git_reqid`; cd B; precmd | `_emjay_git_reqid == id+1` |
| | drain | `⎇ beta ✔` |
| | `_emjay_git_apply "$id"$'\nrepo=1\nbranch=alpha\nbare=0\ndetached=0'` | returns 1; seg still beta |
| `test_async_same_repo_keeps_info` | A: precmd and drain; cd A/sub; precmd | seg still `⎇ alpha ✔` while pending |
| | drain | `⎇ alpha ✔` |
| `test_async_nonrepo_no_worker` | A: precmd and drain; cd plain; precmd | seg '', `_emjay_git_fd == 0` |
| `test_worker_wire_format` | `exec {fd}< <(_emjay_git_worker 42 $TT/A)`; `read -u $fd pid`; `IFS= read -r -u $fd -d '' rest` | pid matches `<->`; line 1 of rest is `42`; rest contains the lines `repo=1` and `branch=alpha` |
| `test_worker_nonrepo_payload` | worker 7 on `plain` | rest lines are `7` and `repo=0` |
| `test_reqid_increments` | in A: precmd 3 times, draining each | reqid increases by 1 each time |
| `test_cancel_spares_finished_worker_pid` | A: precmd; wait until the pipe is readable; set `_emjay_git_pid` to an unrelated process; `_emjay_git_cancel` | that process is still alive (M1) |
| `test_cancel_applies_finished_result_same_repo` | A: precmd; wait until readable; precmd again | `⎇ alpha ✔` at once, a new request pending (M1) |
| `test_cancel_discards_finished_result_other_repo` | A: precmd; wait until readable; `builtin cd -q B`; precmd | seg '', no `alpha`; drain → beta |
| `test_worker_pid_line_not_evaluated` | worker prints `path[$(: > pwned)]` as its pid line | `_emjay_git_pid` 0, no `pwned` (M1) |
| `test_callback_drops_result_after_cd_without_precmd` | A drained; precmd; `builtin cd -q B`; drain | seg '', `_emjay_git` empty, no `alpha` (m1) |
| `test_chpwd_clears_git_segment` | A drained; precmd; `cd B` (no precmd) | seg '' and no `alpha` at once, pending request cancelled, key B; `cd A/sub` keeps alpha (m1) |
| `test_zle_busy_decision` | `LASTWIDGET` / `ISEARCHMATCH_ACTIVE` combinations | busy for completion/menu widgets, `history-search-*` and `ISEARCHMATCH_ACTIVE=1`; not for typing, vi, or a finished isearch (m3) |
| `test_callback_defers_redraw_when_busy` | callback with `LASTWIDGET=expand-or-complete`, then pre-redraw hook while busy / not busy | data applied, `_emjay_redraw_pending` 1 → 1 → 0; no deferral while typing; precmd clears it (m3) |
| `test_cancelled_worker_leaves_no_git_running` | no `monitor`; git wrapper whose `status` execs `sleep 30` and logs its pid; precmd in A, then 4 quick cd+precmd, cancel | no logged pid is alive (m8) |

### tests/test_render.zsh
| Test | Setup | Expected |
|---|---|---|
| `test_requirements_line` | `HOME=$TT/home`; cd `~/projects/api`; `_emjay_git` as in the requirements example; `_emjay_kube=(ctx eks-prod ns payments)`; `_emjay_last_status=1 _emjay_cmd_duration=4`; call render_dir, render_git, render_kube, render_status, assemble | `seg_text prompt` == `~/projects/api  ⎇ main ↑2 ↓1 ●3 ✚1 …2 ⚑1 ✖1 REBASE 2/5  ⎈ eks-prod/payments  ✘ 1  took 4s` + `\n` + `❯ ` |
| `test_assemble_skips_empty` | segs set by hand: only dir `~/p` and took | line1 `~/p  took 4s` |
| `test_assemble_only_char` | every seg '' except char | prompt `❯ ` (no newline) |
| `test_separator_override` | `EMJAY_SEPARATOR=' | '` | `~/p | ⎈ a/b | took 4s` |
| `test_dir_home_abbrev` | as in the first test | dir `~/projects/api` |
| `test_dir_toggle_off` | `EMJAY_SHOW_DIR=0` | dir '' |
| `test_status_render_error` | last 1, duration 0 | status `✘ 1`, took '', char raw contains `%F{196}` |
| `test_status_render_signal` | last 130 | `✘ INT` |
| `test_status_render_success` | last 0 | status '', char raw contains `%F{76}` |
| `test_took_threshold` | duration 3 → ''; 4 → `took 4s`; `EMJAY_CMD_MAX_DURATION=10` with 5 → ''; `=x` with 4 → `took 4s`; `=0` with 1 → `took 1s` | as listed |
| `test_status_toggle_off` | `EMJAY_SHOW_STATUS=0`, last 1 | status '', char red |
| `test_duration_toggle_off` | `EMJAY_SHOW_DURATION=0`, duration 99 | took '' |
| `test_precmd_nonrepo_minimal` | cd plain; no kubeconfig; precmd | prompt == `${(%):-%~}` + `\n❯ ` |
| `test_precmd_failure_then_empty_enter` | `_emjay_preexec; false; _emjay_precmd` → status `✘ 1`; then `_emjay_precmd` (no preexec) | status '', char raw contains `%F{76}` |
| `test_precmd_took` | `_emjay_preexec; _emjay_cmd_start=$(( EPOCHREALTIME - 5 )); true; _emjay_precmd` | took `took 5s` |
| `test_precmd_works_with_empty_path` | basic kubeconfig at default path; cd plain; `PATH=$TT/emptybin`; `capture_err _emjay_precmd` | stderr ''; kube `⎈ dev/team-a` |
| `test_prompt_wiring` | source the theme a second time | `PROMPT == '${_emjay_prompt}'`; `[[ -o prompt_subst ]]`; `_emjay_precmd` appears exactly once in `precmd_functions` and `_emjay_preexec` exactly once in `preexec_functions` |
| `test_chpwd_hook_registered_once` | source the theme twice more | `_emjay_chpwd` exactly once in `chpwd_functions` |
| `test_no_zerr_on_prompt_path` | a counting `TRAPZERR`; precmd in non-repo / with kubeconfig / after a failure (`! true`) / empty Enter / repo sync / async + drain / chpwd cancel / missing kubeconfig / toggles off | the trap never fires (m7) |
| `test_perf_nonrepo` (skipped if `EMJAY_TEST_SKIP_PERF=1`) | cd plain, basic kubeconfig, one warm-up precmd, then 50× | average under 10 ms |

### tests/test_static.zsh
| Test | Check |
|---|---|
| `test_theme_syntax` | `zsh -n zsh/emjay.zsh-theme` exits 0 |
| `test_install_syntax` | `sh -n install.sh` exits 0 |
| `test_no_gnu_only_flags` | theme and install.sh contain none of `stat -c`, `date -d`, `sed -r`, `sed -i`, `readlink -f`, `grep -P` |
| `test_no_subshell_on_sync_path` | For `_emjay_precmd _emjay_preexec _emjay_status_update _emjay_glyphs_select _emjay_glyphs_load _emjay_fmt_duration _emjay_fmt_status _emjay_kube_update _emjay_kube_files _emjay_kube_cache_key _emjay_kube_load _emjay_kube_parse_file _emjay_yaml_unquote _emjay_kube_shorten _emjay_kube_is_prod _emjay_render_dir _emjay_render_git _emjay_render_kube _emjay_render_status _emjay_assemble _emjay_git_update _emjay_git_find_root`: `${functions[f]}` contains no backtick, and every `$(` is followed by optional spaces and `<` |
| `test_source_silent_outside_omz` | `zsh -f -c 'source $1' _ <theme>` | stdout and stderr both empty |
| `test_namespace_hygiene` | in `zsh -f`, compare `${(k)functions}` before and after sourcing | every new name matches `_emjay_*` |
| `test_theme_is_ascii` | theme bytes in the C locale | no non-ASCII or control bytes (glyphs are escapes) |
| `test_git_lookup_after_find_root` | `${functions[_emjay_git_update]}` | `_emjay_git_find_root` comes before the `commands[git]` lookup |
| `test_source_under_hostile_options` | `zsh -f` with `sh_glob ignore_braces ignore_close_braces ksh_arrays` and aliases for `read`, `cd`, `git`; source twice; precmd sync and async + drain in a repo | options and aliases restored; each hook once; `%F{76}⎇ main ✔%f` both times; stderr empty (m6) |

### tests/test_install.zsh
Setup: `H=$TT/home`, `mkdir -p $H/.oh-my-zsh/custom`. `.zshrc` contains `export ZSH="$HOME/.oh-my-zsh"`, `# ZSH_THEME="old"`, `ZSH_THEME="robbyrussell"`, `source $ZSH/oh-my-zsh.sh`. Run: `HOME=$H ZSH=$H/.oh-my-zsh sh $EMJAY_ROOT/install.sh` with `ZSH_CUSTOM` and `ZDOTDIR` unset.

| Test | Expected |
|---|---|
| `test_install_symlink` | exits 0; `$H/.oh-my-zsh/custom/themes/emjay.zsh-theme` is a symlink whose `:A` equals the repo theme's `:A` |
| `test_install_sets_theme_and_backup` | exactly one uncommented line `ZSH_THEME="emjay"`; no `robbyrussell`; the `# ZSH_THEME="old"` line is kept; `.zshrc.bak` equals the original |
| `test_install_idempotent` | a second run: `.zshrc` byte-identical; `.zshrc.bak` still equals the **original** |
| `test_install_inserts_when_missing` | `.zshrc` without any ZSH_THEME line: `ZSH_THEME="emjay"` sits on the line directly before `source $ZSH/oh-my-zsh.sh` |
| `test_install_respects_zsh_custom` | with `ZSH_CUSTOM=$TT/cust` the link is at `$TT/cust/themes/emjay.zsh-theme` |
| `test_install_zdotdir` | with `ZDOTDIR=$TT/zd`, it edits `$TT/zd/.zshrc` |
| `test_install_missing_omz_fails` | with `ZSH=$TT/none`: exit ≠ 0, `.zshrc` unchanged, no `.bak` |
| `test_install_zsh_custom_from_zshrc` | `.zshrc` has `ZSH_CUSTOM="$HOME/dotfiles/omz-custom"` (not exported) | link under `$H/dotfiles/omz-custom/themes`, none under `$ZSH/custom` (M2) |
| `test_install_zsh_custom_export_with_zsh_var` | `export ZSH_CUSTOM=${ZSH}/my-custom   # mine` | link under `$H/.oh-my-zsh/my-custom/themes` (M2) |
| `test_install_zsh_custom_unresolvable_fails` | `ZSH_CUSTOM="$(dotfiles-dir)/omz"` | exit ≠ 0; stderr names `ZSH_CUSTOM` and `ln -s`; nothing changed, no link (M2) |
| `test_install_zsh_from_zshrc` | `ZSH="$HOME/.config/oh-my-zsh"` in `.zshrc`, `ZSH` empty in the env | link under `$H/.config/oh-my-zsh/custom/themes` |
| `test_install_zdotdir_from_zshenv` | `~/.zshenv`: `export ZDOTDIR="$HOME/.config/zsh"`; env ZDOTDIR unset | that `.zshrc` edited, `~/.zshrc` untouched, stderr warns about ZDOTDIR (M2) |
| `test_install_zdotdir_unresolvable_fails` | `~/.zshenv`: `ZDOTDIR=$(find-my-zdotdir)` | exit ≠ 0, nothing changed (M2) |
| `test_install_replaces_only_the_token` | `ZSH_THEME="agnoster"; DEFAULT_USER=me` and `␠␠ZSH_THEME=robbyrussell  # old one` | `ZSH_THEME="emjay"; DEFAULT_USER=me` and `␠␠ZSH_THEME="emjay"  # old one`; second run says already set (M3) |
| `test_install_comment_after_emjay_is_set` | `ZSH_THEME="emjay" # my theme` | already set; file untouched; no `.bak` (M3) |
| `test_install_ignores_computed_theme` | `ZSH_THEME="$1"` on its own line in a function body, `x=1; ZSH_THEME=$PICKED` | both untouched; `ZSH_THEME="emjay"` inserted before the source line (M3) |
| `test_install_guarded_source_line` | `[ -f $ZSH/oh-my-zsh.sh ] && source $ZSH/oh-my-zsh.sh`, no ZSH_THEME | inserted directly before it; stderr empty (m9) |
| `test_install_no_source_line_warns` | `.zshrc` never sources oh-my-zsh | appended; stderr contains `appended` (m9) |
| `test_install_keeps_older_backup` | an unrelated `.zshrc.bak` exists | kept; exactly one `.zshrc.bak.<epoch>` equal to the original; stdout names it |
| `test_install_refuses_regular_file_at_link` | regular file at `custom/themes/emjay.zsh-theme` | exit ≠ 0; file, `.zshrc` unchanged; no `.bak` |

## Appendix A: fixtures (`tests/fixtures/kube/`, exact content)

**basic.yaml** (kubectl style)
```yaml
apiVersion: v1
clusters:
- cluster:
    certificate-authority-data: LS0tLS1CRUdJTiBDRVJUSUZJQ0FURS0tLS0tCk1JSUM=
    server: https://127.0.0.1:6443
  name: kind-kind
- cluster:
    server: https://dev.example.com
  name: dev-cluster
contexts:
- context:
    cluster: dev-cluster
    namespace: team-a
    user: dev-user
  name: dev
- context:
    cluster: kind-kind
    user: kind-kind
  name: kind-kind
current-context: dev
kind: Config
preferences: {}
users:
- name: dev-user
  user:
    token: abc
- name: kind-kind
  user:
    client-certificate-data: LS0tLS1CRUdJTiBDRVJUSUZJQ0FURS0tLS0t
```
**indented.yaml**
```yaml
# hand-written
apiVersion: v1
kind: Config
current-context: "prod-eu"   # active
contexts:
  - name: 'staging'
    context:
      cluster: staging
      namespace: web
  - name: prod-eu
    context:
      user: admin
      namespace: "payments" # team
  # comment inside list
clusters:
  - name: should-not-match
    cluster:
      namespace: nope
users: []
```
**minikube.yaml**
```yaml
apiVersion: v1
clusters:
- cluster:
    extensions:
    - extension:
        provider: minikube.sigs.k8s.io
        version: v1.33.0
      name: cluster_info
    server: https://192.168.49.2:8443
  name: minikube
contexts:
- context:
    cluster: minikube
    extensions:
    - extension:
        provider: minikube.sigs.k8s.io
        version: v1.33.0
      name: context_info
    namespace: kube-system
    user: minikube
  name: minikube
current-context: minikube
kind: Config
preferences: {}
users:
- name: minikube
  user:
    client-certificate: /home/u/.minikube/profiles/minikube/client.crt
```
**eks.yaml**
```yaml
apiVersion: v1
clusters:
- cluster:
    server: https://ABC.gr7.us-east-1.eks.amazonaws.com
  name: arn:aws:eks:us-east-1:123456789012:cluster/payments-prod
contexts:
- context:
    cluster: arn:aws:eks:us-east-1:123456789012:cluster/payments-prod
    namespace: checkout
    user: arn:aws:eks:us-east-1:123456789012:cluster/payments-prod
  name: arn:aws:eks:us-east-1:123456789012:cluster/payments-prod
current-context: arn:aws:eks:us-east-1:123456789012:cluster/payments-prod
kind: Config
preferences: {}
users:
- name: arn:aws:eks:us-east-1:123456789012:cluster/payments-prod
  user:
    exec:
      apiVersion: client.authentication.k8s.io/v1beta1
      args:
      - --region
      - us-east-1
      command: aws
```
**gke.yaml**
```yaml
apiVersion: v1
contexts:
- context:
    cluster: gke_my-proj_europe-west1-b_web
    user: gke_my-proj_europe-west1-b_web
  name: gke_my-proj_europe-west1-b_web
current-context: gke_my-proj_europe-west1-b_web
kind: Config
```
**no-current.yaml**
```yaml
apiVersion: v1
contexts:
- context:
    cluster: x
  name: x
current-context: ""
kind: Config
```
**flow.yaml**
```yaml
contexts:
- name: flowy
  context: {cluster: c, namespace: hidden}
current-context: flowy
```
**multi-a.yaml**
```yaml
apiVersion: v1
kind: Config
current-context: shared
contexts:
- context:
    namespace: from-a
  name: local
```
**multi-b.yaml**
```yaml
apiVersion: v1
kind: Config
current-context: other
contexts:
- context:
    namespace: ops
  name: shared
- context:
    namespace: from-b
  name: local
```

## Appendix B: canned porcelain v2 text

Each block is the literal input, one line per entry. In B2 the type-2 line has a TAB between `new name.txt` and `old name.txt`.

- **B1**
  ```
  # branch.oid 1234567890abcdef1234567890abcdef12345678
  # branch.head main
  # branch.upstream origin/main
  # branch.ab +0 -0
  ```
- **B2**
  ```
  # branch.oid 1234567890abcdef1234567890abcdef12345678
  # branch.head feature/x
  # branch.upstream origin/feature/x
  # branch.ab +2 -1
  # stash 1
  1 M. N... 100644 100644 100644 aaaa bbbb staged.txt
  1 A. N... 000000 100644 100644 0000 cccc new.txt
  1 MM N... 100644 100644 100644 aaaa bbbb both.txt
  1 .M N... 100644 100644 100644 aaaa aaaa mod.txt
  2 R. N... 100644 100644 100644 aaaa aaaa R100 new name.txt<TAB>old name.txt
  1 .D N... 100644 100644 000000 aaaa aaaa deleted.txt
  u UU N... 100644 100644 100644 100644 aaaa bbbb cccc conflict.txt
  ? untracked1
  ? dir/
  ! ignored.txt
  ```
- **B3**
  ```
  # branch.oid (initial)
  # branch.head main
  ? a
  ```
- **B4**
  ```
  # branch.oid abcdef1234567890abcdef1234567890abcdef12
  # branch.head (detached)
  ```
- **B5**
  ```
  # branch.oid 1234567890abcdef1234567890abcdef12345678
  # branch.head main
  # branch.upstream origin/gone
  ```
- **B6**
  ```
  # branch.oid 1234567890abcdef1234567890abcdef12345678
  # branch.head main
  1 .M N... 100644 100644 100644 aaaa aaaa "we\"ird name.txt"
  ? "sp ace.txt"
  ```

## Manual checks (not automatable headless)

1. In a `/mnt/c` repo the prompt appears instantly and git info fills in afterwards, without a keypress.
2. A fast `cd A; cd B` never shows A's info.
3. Ctrl-C at the prompt still works while a slow status runs.
4. No `[1] done` job messages appear.
5. Run on macOS `/bin/zsh` 5.9 with Apple git.
6. With a slow `git status` pending: a completion list or menu-select, Ctrl-R, typing mid-line and vi command mode are not disturbed when the info arrives; the prompt repaints after the menu or search ends (scripted once in tmux: 2026-10-10).
7. A widget that runs `cd` + `zle reset-prompt` drops the old repo's info at once and no late result reappears.

## Critical files for implementation
- `/home/mujeeb/projects/emjay-configs/zsh/emjay.zsh-theme` (new)
- `/home/mujeeb/projects/emjay-configs/tests/lib.zsh` and `/home/mujeeb/projects/emjay-configs/tests/run.zsh` (new)
- `/home/mujeeb/projects/emjay-configs/tests/fixtures/kube/` (new; Appendix A)
- `/home/mujeeb/projects/emjay-configs/install.sh` (new)
- Reference only: `/home/mujeeb/.oh-my-zsh/lib/async_prompt.zsh` (fd, pid and kill pattern), `/home/mujeeb/projects/emjay-configs/docs/REQUIREMENTS.md`

Verified on this box (zsh 5.9.2, git 2.53):
- zsh restores `$?` for each precmd hook.
- `$(<file)` is fork-free (2 µs, against 250 µs for a subshell).
- `zstat -H h -F '%s.%N'` gives nanosecond mtime.
- `$!` is not set for `<(…)`, so the pid must come over the pipe.
- `zle` with no arguments returns 1 outside ZLE, and `zle -F` is inert in scripts.
- A `$'\u2387'` escape is converted with the locale in force at conversion time. In the sourced theme that can be after a switch to `LC_ALL=C`, where it fails with `character not in range`. Hence byte escapes in the theme (§3.2).
- An invalid `=~` regex prints to stderr and returns 1.
- `$signals[code-127]` maps 130→INT, 137→KILL, 141→PIPE, 143→TERM.
- Inside `.git`, rev-parse prints `false` for the work-tree check and `git status` fails.
- `~/.kube/config` uses kubectl's zero-indented sequence layout.

- `${+assoc[key]}` is 1 for a key whose value is empty.
- `${#${(M)arr:#pat}}` counts matching elements in an assignment; inside double quotes it needs `(@M)`, or it measures the joined string.
- `zle .reset-prompt` + `zle -R` from a `zle -F` handler repaints the prompt without a keypress (the same pattern as OMZ's `_omz_async_callback`; checked in a pty and in tmux).
- `emulate -L zsh` keeps `monitor` in interactive shells.
- Reading pipe data into an integer variable arithmetic-evaluates it: `path[$(cmd)]` runs `cmd`.
- An `(( expr ))` statement that evaluates to 0 inside a function fires a user `TRAPZERR`. A function whose last statement fails does not, when it is called from a condition or as `f || :`.
- A user `TRAPEXIT`/`zshexit` does not run in a `<( )` worker; a worker's TERM trap runs while it is blocked in `read -p` on a coproc.
- `add-zle-hook-widget` keeps an existing user `zle-line-pre-redraw` widget when it installs its dispatcher.
- A repo-local `core.fsmonitor` hook command runs under plain `git status`, and `-c core.fsmonitor=false` stops it; `core.fsmonitor=true` works on Linux git 2.53.
- `git init --ref-format=reftable` writes `ref: refs/heads/.invalid` to HEAD.
- `LC_CTYPE=UTF-8` with no other locale variables gives codeset `ANSI_X3.4-1968` on Linux.