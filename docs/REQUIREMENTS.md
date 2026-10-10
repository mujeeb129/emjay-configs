# emjay zsh theme: requirements

Decisions taken with the user on 2026-10-10. These are fixed; don't re-open them.

## Targets
- Machines: **WSL2** (this box: Debian, zsh 5.9, oh-my-zsh 2025-08) and **macOS** (work station, Apple zsh 5.9, possibly Apple git ≥ 2.39).
- Must use only portable tools: no GNU-only flags (`stat -c`, `date -d`, `sed -r`, `readlink -f`). Prefer zsh builtins/modules (`zsh/stat`, `zsh/datetime`, `zsh/system`).
- Packaging: **oh-my-zsh theme only**: `zsh/emjay.zsh-theme`, loaded with `ZSH_THEME="emjay"`. OMZ's lib is available; reuse its async helper (`lib/async_prompt.zsh`: `_omz_register_handler`, `_omz_async_request`) if it fits, else a self-contained `zle -F` worker.

## Layout: two-line
```
~/projects/api  ⎇ main ↑2 ↓1 ●3 ✚1 …2 ⚑1 ✖1 REBASE 2/5  ⎈ eks-prod/payments  ✘ 1  took 4s
❯ 
```
- Line 1: dir · git · kube · last-command status. Line 2: `❯` (green after success, red after failure).
- Segments that have nothing to show disappear completely (no stray separators/spaces).

## Glyphs
- Default: plain Unicode that renders in any UTF-8 terminal (⎇ ↑ ↓ ● ✚ … ⚑ ✖ ⎈ ✘ ❯).
- Opt-in Nerd Font icons via one env var (e.g. `EMJAY_NERD_FONT=1`).
- An ASCII fallback is nice-to-have only if trivial (e.g. when the locale isn't UTF-8).

## Git segment (always: branch or detached short SHA + clean/dirty)
All of the following, each shown only when non-zero:
- ahead/behind upstream (from last fetch: **never** run `git fetch`)
- staged / modified / untracked counts
- stash count, conflict count
- in-progress operation: REBASE n/m, MERGING, CHERRY-PICKING, REVERTING, BISECTING, AM
- Use one `git status --porcelain=v2 --branch --show-stash` call (+ file checks under the git dir for operations).
- **Async**: prompt must render immediately; git info fills in when ready. Repos under `/mnt/c` in WSL can take seconds. Old info must never be shown for a different repo after `cd`.
- Must work in: non-repo dirs, fresh repo with no commits, detached HEAD, worktrees, submodules, bare-ish/`.git` dir itself, repo with no upstream.

## Kube segment: always shown when a kubeconfig + current-context exist
- Show `context/namespace`; namespace falls back to `default`.
- **No kubectl calls.** On this box kubectl is `kubectl.exe` via Docker Desktop (100-300 ms per call). Parse the kubeconfig file(s) in pure zsh.
- Honour `$KUBECONFIG` (colon-separated list, first `current-context` wins; context entry may live in any file), default `~/.kube/config`.
- Cache parsed result; invalidate on change of `$KUBECONFIG` value or any file's mtime (so `kubectl config use-context` / `kubens` / `set-context --current --namespace` show up on the next prompt).
- Shorten long names: EKS ARN `arn:aws:eks:<region>:<acct>:cluster/<name>` → `<name>`; GKE `gke_<project>_<zone>_<name>` → `<name>`.
- **Prod guard**: context matching a configurable regex (default `prod|prd|live`, case-insensitive) renders bold red.
- Hide when no kubeconfig / no current-context.

## Last-command status
- `✘ <code>` when last exit status ≠ 0 (show signal name for >128 if cheap, e.g. `✘ INT`).
- `took <dur>` when the command took > 3 s (configurable); human format `4s`, `1m12s`, `1h3m`.
- Nothing shown on an empty Enter.

## Performance budget
- Synchronous prompt work (everything except async git) < 10 ms on WSL in a non-repo dir; no forks on the sync path except where unavoidable.
- No subshell `$(...)` per prompt for kube/time/status.

## Configuration (env vars, all optional)
`EMJAY_NERD_FONT`, `EMJAY_KUBE_PROD_PATTERN`, `EMJAY_CMD_MAX_DURATION` (seconds threshold), and on/off toggles per segment (`EMJAY_SHOW_GIT`, `EMJAY_SHOW_KUBE`, ...). Colors overridable.

## Install
- `install.sh` (POSIX sh, works on macOS + WSL): symlink `zsh/emjay.zsh-theme` into `${ZSH_CUSTOM:-$ZSH/custom}/themes/`, set `ZSH_THEME="emjay"` in `~/.zshrc` (back up to `~/.zshrc.bak` first, idempotent).

## Tests
- Runnable with `zsh tests/run.zsh`, no external deps beyond zsh + git.
- Cover: kubeconfig parsing (single file, multi-file KUBECONFIG, missing ns, missing file, quoted values, prod pattern, ARN/GKE shortening, cache invalidation on mtime), git states listed above (built in temp repos), duration formatting, segment hiding, glyph mode switching, async result not leaking across `cd`.
