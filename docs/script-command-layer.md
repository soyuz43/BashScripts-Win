# Script Command Layer

Goal: make personal shell tools behave like real commands.

## Pattern

Put executable scripts on `PATH`.

Example:

```text
~/BashScripts/
├── bet
├── diffp
├── generate
├── git-del
├── slay
└── xbox
````

Each command is a standalone executable:

```sh
#!/usr/bin/env bash
set -euo pipefail
```

`.bashrc` should mainly configure the shell:

* environment variables
* PATH
* aliases
* prompt
* completions
* tiny interactive helpers

Larger tools should live as scripts.

## Why

* Commands work outside interactive shells.
* Scripts can call other scripts.
* Tools are easier to test with `shellcheck`, `shfmt`, and direct execution.
* `.bashrc` stays small.
* Command names become stable user-facing interfaces.

## Naming

Use clean command names for user-facing tools.

Implementation names can be longer.

```text
git-add-commit.sh          → bet
git-remove-local-branch.sh → git-del
launch_xemu.sh             → xbox
concatenate_code.sh        → generate
```
