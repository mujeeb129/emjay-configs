# emjay

A fast, two-line [oh-my-zsh](https://ohmyz.sh) theme for zsh on macOS and Linux/WSL2.

```
~/projects/api  ⎇ main ↑2 ↓1 ●3 ✚1 …2 ⚑1 ✖1 REBASE 2/5  ⎈ eks-prod/payments  ✘ 1  took 4s
❯
```

The repo also ships a set of [Claude Code skills](#claude-code-skills) for
planning and documenting work.

Line 1 shows the directory, git status, kube context and the last command's result.
Line 2 is the prompt character: green after success, red after failure.
A segment with nothing to show is hidden, separator included.

## Features

- **Async git.** The prompt draws at once and git info fills in when it's ready.
  A slow repo (for example under `/mnt/c` on WSL) doesn't block typing, and
  results from a previous directory never show up after a `cd`.
  - branch, or short SHA when detached; clean/dirty colour
  - ahead/behind upstream, from the last fetch (the theme never runs `git fetch`)
  - staged `●`, modified `✚`, untracked `…`, stash `⚑` and conflict `✖` counts
  - in-progress operation: `REBASE n/m`, `MERGING`, `CHERRY-PICKING`, `REVERTING`, `BISECTING`, `AM`
- **Kube context without kubectl.** `context/namespace` is parsed from your
  kubeconfig in pure zsh and cached until `$KUBECONFIG` or a file's mtime changes.
  `kubectl config use-context` and `kubens` show up on the next prompt.
  - honours a colon-separated `$KUBECONFIG`; defaults to `~/.kube/config`
  - shortens EKS ARNs and GKE names to the cluster name
  - prod guard: contexts matching `prod|prd|live` render bold red
- **Last-command status.** `✘ <code>` (or a signal name such as `✘ INT`) on failure,
  and `took 1m12s` when a command runs longer than 3 s.
- **Glyphs.** Plain Unicode by default, Nerd Font icons with `EMJAY_NERD_FONT=1`,
  and ASCII when the locale isn't UTF-8.
- **Cheap.** No subshells or kubectl calls on the synchronous prompt path.

## Requirements

- zsh ≥ 5.8
- git (for the git segment)
- oh-my-zsh, if you want the installer. The theme itself needs nothing from
  oh-my-zsh and can be sourced from any zsh.

## Install

```sh
git clone https://github.com/mujeeb129/emjay-configs.git
cd emjay-configs
./install.sh
exec zsh
```

`install.sh` (POSIX sh) does two things:

1. symlinks `zsh/emjay.zsh-theme` into `${ZSH_CUSTOM:-$ZSH/custom}/themes/`
2. sets `ZSH_THEME="emjay"` in your `.zshrc` (under `$ZDOTDIR` if set), after
   backing it up to `.zshrc.bak` (or `.zshrc.bak.<timestamp>` if an older,
   different backup already exists)

It is idempotent. Because the theme is a symlink, `git pull` updates it.

### Without oh-my-zsh

```zsh
source /path/to/emjay-configs/zsh/emjay.zsh-theme
```

## Configuration

All settings are optional environment variables, read at every prompt, so you can
change them in a running shell.

| Variable | Default | Effect |
| --- | --- | --- |
| `EMJAY_NERD_FONT` | unset | `1` uses Nerd Font v3 icons |
| `EMJAY_ASCII` | auto | `1` forces ASCII glyphs, `0` forces Unicode; unset picks ASCII when the codeset isn't UTF-8 |
| `EMJAY_KUBE_PROD_PATTERN` | `prod\|prd\|live` | case-insensitive ERE for the prod guard; empty disables it |
| `EMJAY_CMD_MAX_DURATION` | `3` | show `took` when a command ran longer than this many seconds |
| `EMJAY_SHOW_DIR` | on | `0` hides the directory |
| `EMJAY_SHOW_GIT` | on | `0` hides the git segment and skips the git work |
| `EMJAY_SHOW_KUBE` | on | `0` hides the kube segment and skips the parsing |
| `EMJAY_SHOW_STATUS` | on | `0` hides the exit status |
| `EMJAY_SHOW_DURATION` | on | `0` hides `took` |
| `EMJAY_SEPARATOR` | two spaces | separator between line-1 segments |
| `EMJAY_GIT_ASYNC` | on | `0` collects git info synchronously (debugging) |

### Colours

Each colour accepts anything `%F{...}` does: a 256-colour number or a name.

| Variable | Default | | Variable | Default |
| --- | --- | --- | --- | --- |
| `EMJAY_COLOR_DIR` | 39 | | `EMJAY_COLOR_GIT_CONFLICT` | 196 |
| `EMJAY_COLOR_GIT_CLEAN` | 76 | | `EMJAY_COLOR_GIT_OP` | 208 |
| `EMJAY_COLOR_GIT_DIRTY` | 178 | | `EMJAY_COLOR_KUBE` | 33 |
| `EMJAY_COLOR_GIT_SYNC` | 75 | | `EMJAY_COLOR_KUBE_PROD` | 196 |
| `EMJAY_COLOR_GIT_STAGED` | 76 | | `EMJAY_COLOR_ERROR` | 196 |
| `EMJAY_COLOR_GIT_MODIFIED` | 214 | | `EMJAY_COLOR_TOOK` | 178 |
| `EMJAY_COLOR_GIT_UNTRACKED` | 244 | | `EMJAY_COLOR_PROMPT_OK` | 76 |
| `EMJAY_COLOR_GIT_STASH` | 141 | | `EMJAY_COLOR_PROMPT_ERR` | 196 |

Example, in `.zshrc` before oh-my-zsh is sourced:

```zsh
export EMJAY_NERD_FONT=1
export EMJAY_KUBE_PROD_PATTERN='prod|prd|live|production'
export EMJAY_COLOR_DIR=111
```

## Tests

```sh
zsh tests/run.zsh
```

Needs only zsh and git. The suite covers kubeconfig parsing, git states in
temporary repos, duration formatting, segment hiding, glyph modes, async
isolation across `cd`, and the installer.

## Claude Code skills

Three skills that turn a fuzzy task into a written plan, and a codebase into an
onboarding guide. Each one writes a single self-contained HTML file (Tailwind
and Mermaid from CDNs, light and dark mode).

| Skill | What it does | Output |
| --- | --- | --- |
| `emjay-grill` | Interviews you with multiple-choice questions, round by round, until every decision is made. Looks facts up instead of asking, records resolved terms in `GLOSSARY.md`, offers ADRs for hard-to-reverse decisions, then hands off to `emjay-plan`. | `GLOSSARY.md`, `docs/adr/` (if needed), then a plan doc |
| `emjay-plan` | Turns a plan into a design doc: summary, goals and non-goals, user stories, deliverables, architecture and sequence diagrams, DB schemas with DDL, test seams, open questions, risks. Records only what was decided; gaps become open questions. | `docs/plans/<date>-<slug>.html` |
| `emjay-map` | Maps an existing codebase into an onboarding guide for new developers: architecture, entry points, key flows, DB schemas, config, dev workflow and a reading list. | an HTML onboarding guide |

Typical flow: `/emjay-grill <idea>` → answer the rounds → it writes the plan doc.
If you already have a detailed plan, go straight to `/emjay-plan <plan or path>`.

### Install as a plugin

In Claude Code (2.1.275 or later):

```
/plugin install emjay-skills --marketplace mujeeb129/emjay-configs
```

On older versions, add the marketplace first, then install:

```
/plugin marketplace add mujeeb129/emjay-configs
/plugin install emjay-skills@emjay
```

Plugin skills are namespaced, so they show up as `/emjay-skills:emjay-grill`,
`/emjay-skills:emjay-plan` and `/emjay-skills:emjay-map`. Update with
`/plugin marketplace update emjay`, remove with `/plugin uninstall emjay-skills@emjay`.

To make the skills available to everyone working in a project, commit this to
that project's `.claude/settings.json`; Claude Code offers to install the
plugin when someone trusts the folder:

```json
{
  "extraKnownMarketplaces": {
    "emjay": { "source": { "source": "github", "repo": "mujeeb129/emjay-configs" } }
  },
  "enabledPlugins": { "emjay-skills@emjay": true }
}
```

### Install from a clone (for editing the skills)

Symlink the skills into your user skills folder, so edits in the repo take
effect in new sessions:

```sh
for s in emjay-grill emjay-plan emjay-map; do
  ln -sfn "$PWD/.claude/skills/$s" ~/.claude/skills/$s
done
```

From WSL, for Claude Code on Windows, copy them instead (Windows can't follow
symlinks into the WSL filesystem), and re-run after each change:

```sh
win_skills="$(wslpath "$(cmd.exe /c 'echo %USERPROFILE%' 2>/dev/null | tr -d '\r')")/.claude/skills"
for s in emjay-grill emjay-plan emjay-map; do cp -rL ".claude/skills/$s" "$win_skills/"; done
```

Don't install both ways at once, or each skill appears twice.

### Releasing a change

Bump `version` in `.claude-plugin/plugin.json` and push to `main`. Users pick
it up with `/plugin marketplace update emjay`. Check the manifests first with:

```sh
claude plugin validate .
```

## Docs

- [docs/REQUIREMENTS.md](docs/REQUIREMENTS.md): what the theme must do
- [docs/DESIGN.md](docs/DESIGN.md): how it does it
