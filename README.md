# BashScripts-WIN

Utility scripts for the Git Bash environment used by `dotfiles-WIN`.

## Companion Repository

Git Bash configuration and aliases:

https://github.com/soyuz43/dotfiles-WIN

## Scripts

| Script | Purpose |
|---|---|
| `diffp.sh` | Generate a Git diff review prompt and copy it to the clipboard |
| `git-add-commit.sh` | Interactive add → format → lint → commit workflow (`bet`) |
| `git-remove-local-branch.sh` | Interactive local branch cleanup with `fzf` (`slay`) |
| `initproject.sh` | Create a new project using the configured project structure |
| `concatenate_code.sh` | Export source files into a Markdown document |
| `concatenate_code.ps1` | PowerShell version of `concatenate_code.sh` |
| `dbserve.sh` | Start the configured development database server |
| `update-winrar.sh` | Reinstall the latest WinRAR version using `winget` |
| `install.sh` | Bootstrap the BashScripts-WIN environment, install dependencies, and configure permissions |

## Required Tools

| Tool | Purpose |
|---|---|
| Git Bash | Shell environment |
| `gh` | GitHub CLI integration |
| `fzf` | Interactive selection menus |
| `ShellCheck` | Shell script linting |
| `shfmt` | Shell formatting |
| `winget` | Windows package installation and updates |

## Installation

```bash
git clone git@github.com:soyuz43/BashScripts-WIN.git ~/BashScripts
cd ~/BashScripts
./install.sh
```

The installer checks dependencies and provides guidance for connecting `dotfiles-WIN`.