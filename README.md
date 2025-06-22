# BashScripts-Win by soyuz43

This repo contains custom Bash scripts used in tandem with my [dotfiles](https://github.com/soyuz43/dotfiles), specifically designed for Git Bash on Windows 11. These scripts streamline development workflows across Git, Node, C#, and scripting tasks.

## Scripts

| Script                   | Description                                              |
|--------------------------|----------------------------------------------------------|
| `initproject.sh`         | Bootstraps a new project directory structure             |
| `git-remove-local-branch.sh` | Removes a local Git branch                            |
| `git-add-commit.sh`      | Quickly stages all changes and commits with a message    |
| `dbserve.sh`             | Launches a local development database (e.g. MongoDB)     |
| `concatenate_code.sh`    | Concatenates code files into a Markdown export           |
| `concatenate_code.ps1`   | PowerShell variant of the above                          |
| `make-executable.sh`     | Makes all `.sh` files in the directory executable        |

## Integration with `.bashrc`

These scripts are designed to work seamlessly with the aliases and environment defined in [my `.bashrc` setup](https://github.com/soyuz43/dotfiles). Clone both repos and you're good to go.

## Usage

Clone the repo:

```bash
git clone git@github.com:soyuz43/BashScripts-Win.git ~/workspace/BashScripts-Win
cd ~/workspace/BashScripts-Win
./make-executable.sh
````

Make sure your `.bashrc` (from [dotfiles](https://github.com/soyuz43/dotfiles)) includes this path:

```bash
export PATH="$HOME/workspace/BashScripts-Win:$PATH"
```

Then reload your shell:

```bash
source ~/.bashrc
```

## Philosophy

These scripts are designed to reduce cognitive friction. Type less, do more. The idea is to automate away decision fatigue and focus on the real work.

---

**Author:** [soyuz43](https://github.com/soyuz43)


