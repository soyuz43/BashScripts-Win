# BashScripts-WIN

Utility scripts for the Git Bash environment used with [`dotfiles-WIN`](https://github.com/soyuz43/dotfiles-WIN).

This repository owns scripts, package bootstrapping, maintenance workflows, and Makefile shortcuts.

The companion `dotfiles-WIN` repository owns shell, Git, WSL, VS Code, and Windows Terminal configuration.

## Companion Repository

Git Bash configuration, aliases, and managed user configuration:

https://github.com/soyuz43/dotfiles-WIN

Expected local path:

```bash
~/dotfiles
````

## First-Time Setup on a New Windows Machine

Install Git for Windows first so Git Bash is available.

Then clone this repository:

```bash
git clone https://github.com/soyuz43/BashScripts-WIN.git ~/BashScripts
cd ~/BashScripts
```

Run the full first-time setup:

```bash
make new
```

`make new` runs the bootstrap installer, restores managed dotfiles, and prints configuration status.

This is the preferred new-machine command.

## Manual Bootstrap

You can also run the installer directly:

```bash
./install.sh
```

Then choose:

```text
1 - bootstrap
```

Or run bootstrap non-interactively:

```bash
./install.sh --bootstrap
```

Bootstrap handles:

* dependency installation
* GitHub CLI authentication
* cloning `dotfiles-WIN`
* script permission updates
* managed dotfiles restoration through `dotfiles-manager.sh`
* diagnostics and status output

## Scripts

| Script                       | Purpose                                                                 |
| ---------------------------- | ----------------------------------------------------------------------- |
| `install.sh`                 | Bootstrap, maintain, upgrade, and check the BashScripts-WIN environment |
| `dotfiles-manager.sh`        | Restore, capture, and check managed dotfiles and VS Code extensions     |
| `diffp.sh`                   | Generate a Git diff review prompt and copy it to the clipboard          |
| `git-add-commit.sh`          | Interactive add → format → lint → commit workflow                       |
| `git-remove-local-branch.sh` | Interactive local branch cleanup with `fzf`                             |
| `gitdirty.sh`                | Show dirty Git repositories or working tree status                      |
| `initproject.sh`             | Create a new project using the configured project structure             |
| `concatenate_code.sh`        | Export source files into a Markdown document                            |
| `concatenate_code.ps1`       | PowerShell version of `concatenate_code.sh`                             |
| `dbserve.sh`                 | Start the configured development database server                        |
| `update-winrar.sh`           | Reinstall or update WinRAR using `winget`                               |

## Required Tools

The installer attempts to install or verify these tools:

| Tool             | Purpose                                              |
| ---------------- | ---------------------------------------------------- |
| Git Bash         | Shell environment                                    |
| Git              | Repository operations                                |
| GitHub CLI `gh`  | GitHub authentication and Git credential integration |
| `fzf`            | Interactive selection menus                          |
| `ShellCheck`     | Shell script linting                                 |
| `shfmt`          | Shell formatting                                     |
| `tree`           | Directory tree display                               |
| `ripgrep` / `rg` | Fast recursive search                                |
| `jq`             | JSON processing                                      |
| `winget`         | Primary Windows package manager                      |
| Scoop            | Per-package fallback package manager                 |
| Chocolatey       | Per-package fallback package manager                 |

`winget` is preferred. If `winget` fails for a package, the installer falls back to Scoop and then Chocolatey for that package only.

## Dotfiles Manager

`dotfiles-manager.sh` is the single owner of managed user configuration.

It manages:

| Local path                       | Dotfiles path                               |
| -------------------------------- | ------------------------------------------- |
| `~/.bashrc`                      | `~/dotfiles/bashrc`                         |
| `~/.gitconfig`                   | `~/dotfiles/gitconfig`                      |
| `~/.wslconfig`                   | `~/dotfiles/wslconfig`                      |
| VS Code `settings.json`          | `~/dotfiles/vscode/settings.json`           |
| VS Code extensions               | `~/dotfiles/vscode/extensions.txt`          |
| Windows Terminal `settings.json` | `~/dotfiles/windows-terminal/settings.json` |

Restore managed configuration:

```bash
./dotfiles-manager.sh --restore
```

Check status:

```bash
./dotfiles-manager.sh --status
```

Capture the current machine configuration into the dotfiles repository:

```bash
./dotfiles-manager.sh --capture
```

The manager attempts native Windows symlinks when possible. If symlinks are unavailable, it safely backs up the existing file and creates a copy fallback.

## Makefile Commands

| Command          | Purpose                                                                   |
| ---------------- | ------------------------------------------------------------------------- |
| `make new`       | First-time setup: bootstrap installer, restore dotfiles, then show status |
| `make bootstrap` | Run `install.sh --bootstrap`                                              |
| `make maintain`  | Run `install.sh --maintain`                                               |
| `make upgrade`   | Run `install.sh --upgrade`                                                |
| `make check`     | Run `install.sh --check`                                                  |
| `make restore`   | Run `dotfiles-manager.sh --restore`                                       |
| `make status`    | Run `dotfiles-manager.sh --status`                                        |
| `make capture`   | Run `dotfiles-manager.sh --capture`                                       |
| `make chmod`     | Make repository shell scripts executable                                  |
| `make lint`      | Run ShellCheck on shell scripts                                           |
| `make format`    | Format shell scripts with `shfmt`                                         |
| `make test`      | Run `bash -n` syntax checks                                               |
| `make clean`     | Remove installer logs from the home directory                             |

## Recommended Workflow

For a new machine:

```bash
git clone https://github.com/soyuz43/BashScripts-WIN.git ~/BashScripts
cd ~/BashScripts
make new
```

For regular maintenance:

```bash
make maintain
```

For dependency upgrades:

```bash
make upgrade
```

Before committing script changes:

```bash
make format
make lint
make test
```

To save updated local configuration back into `dotfiles-WIN`:

```bash
make capture
cd ~/dotfiles
git status
git add .
git commit -m "Update managed dotfiles"
git push
```

## Logs

Installer logs are written to:

```bash
~/bashscripts-install_<timestamp>.log
```

