# BashScripts-WIN

Shell scripts used by the Git Bash environment in dotfiles-WIN.

## Scripts

### `diffp.sh`

Creates a Git review prompt containing:

- Current branch
- Timestamp
- Changed file summary
- Staged and/or unstaged diff
- Review instructions

Supports clipboard output or writing to a file.

---

### `git-add-commit.sh`

Interactive commit helper.

Functions include:

- Normalize line endings
- Run configured formatters
- Run ShellCheck
- Show a staged summary
- Prompt for a commit message
- Create the commit

---

### `git-remove-local-branch.sh`

Interactive local branch cleanup.

Functions include:

- List local branches with metadata
- Select branches using `fzf`
- Prevent deletion of protected branches
- Prevent deletion of the current branch
- Confirm before deletion
- Attempt safe deletion before offering force deletion
- Show deletion results

---

### `initproject.sh`

Creates a new project directory and initializes the configured project structure.

---

### `concatenate_code.sh`

Exports source files into a single Markdown document.

Functions include:

- Detect supported file types
- Apply appropriate Markdown language fences
- Combine files into a timestamped output file

---

### `concatenate_code.ps1`

PowerShell implementation of `concatenate_code.sh`.

---

### `dbserve.sh`

Starts the configured development database server.

---

### `make-executable.sh`

Applies executable permissions to shell scripts in the repository.

---

### `update-winrar.sh`

Uninstalls the current WinRAR installation and installs the latest version using `winget`.

## Dependencies

Recommended tools:

- Git Bash
- GitHub CLI (`gh`)
- `fzf`
- `ShellCheck`
- `shfmt`
- `winget`
