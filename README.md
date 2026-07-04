# BashScripts-WIN

Git Bash utility scripts for setting up and maintaining a personal Windows development environment.

Companion repository: [`dotfiles-WIN`](https://github.com/soyuz43/dotfiles-WIN)

## Setup

```bash
git clone https://github.com/soyuz43/BashScripts-WIN.git ~/BashScripts
cd ~/BashScripts
make new
```

## Commands

```bash
make new       # bootstrap a new machine
make maintain  # run maintenance checks
make upgrade   # upgrade managed dependencies
make check     # show environment status
make restore   # restore dotfiles
make capture   # capture current config
make lint      # run ShellCheck
make format    # run shfmt
make test      # run bash syntax checks
```

## Main Scripts

| Script | Purpose |
| --- | --- |
| `install.sh` | Bootstrap, maintain, upgrade, and check the environment |
| `modify/dotfiles-manager.sh` | Restore, capture, and check managed dotfiles |
| `inspect/diffp.sh` | Generate a Git diff review prompt |
| `modify/git-add-commit.sh` | Stage, validate, and commit changes |
| `modify/git-remove-local-branch.sh` | Clean up local branches |
| `inspect/provenance` | Browse Git history and branch from selected commits |

## Responsibilities

This repository handles:

- dependency installation
- GitHub CLI authentication
- new-machine bootstrap
- script maintenance
- dotfiles restore/capture workflows
- Git Bash helper commands

`dotfiles-WIN` stores the managed configuration restored by these scripts.