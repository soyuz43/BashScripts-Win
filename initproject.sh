#!/bin/bash

# Usage: ./initproject.sh <project-name> [branch-name]
# Example: ./initproject.sh cool-tool wrs-feat-1

set -euo pipefail

# === Global Variables ===
BASE_DIR="/c/Users/thisi/workspace/personal"
PROJECT_NAME="$1"
BRANCH_NAME="${2:-main}"
PROJECT_PATH="$BASE_DIR/$PROJECT_NAME"

# === Function: Validate Inputs ===
validate_inputs() {
  if [[ -z "$PROJECT_NAME" ]]; then
    printf "❌ Project name is required.\n" >&2
    printf "Usage: %s <project-name> [branch-name]\n" "$0" >&2
    return 1
  fi
}

# === Function: Create Project Structure ===
create_structure() {
  mkdir -p "$PROJECT_PATH/src" "$PROJECT_PATH/tests" "$PROJECT_PATH/docs"
  touch "$PROJECT_PATH/README.md" "$PROJECT_PATH/.gitignore" "$PROJECT_PATH/LICENSE"
  touch "$PROJECT_PATH/docs/overview.md"
}

# === Function: Initialize Git Repo ===
init_git_repo() {
  cd "$PROJECT_PATH" || return 1
  if [[ ! -d ".git" ]]; then
    git init || return 1
    printf "✅ Initialized new Git repository\n"
  else
    printf "⚠️ Git repository already exists — skipping init\n"
  fi
}

# === Function: Add Remote if Missing ===
setup_remote() {
  if ! command -v gh &>/dev/null; then
    printf "❌ GitHub CLI (gh) not found. Install it from https://cli.github.com/\n" >&2
    return 1
  fi

  if ! git remote | grep -q "^origin$"; then
    gh repo create "$PROJECT_NAME" --source=. --public --remote=origin || return 1
    printf "✅ Remote 'origin' created and linked\n"
  else
    printf "⚠️ Remote 'origin' already exists — skipping repo creation\n"
  fi
}

# === Function: Make Initial Commit ===
make_initial_commit() {
  if ! git log &>/dev/null; then
    git add . || return 1
    git commit -m "initial commit" || return 1
    git branch -M main || return 1
    git push -u origin main || return 1
    printf "✅ Initial commit pushed to 'main'\n"
  else
    printf "⚠️ Repo already has commits — skipping commit & push\n"
  fi
}

# === Function: Create and Switch Branch Without Push ===
create_and_switch_branch() {
  if git rev-parse --verify "$BRANCH_NAME" >/dev/null 2>&1; then
    git switch "$BRANCH_NAME" || return 1
    printf "✅ Switched to existing branch: %s\n" "$BRANCH_NAME"
  else
    git switch -c "$BRANCH_NAME" || return 1
    printf "✅ Created and switched to new branch: %s\n" "$BRANCH_NAME"
  fi
}

# === Function: Final Output ===
print_summary() {
  local user;
  if ! user=$(gh api user --jq .login 2>/dev/null); then
    printf "❌ Failed to fetch GitHub username via gh CLI\n" >&2
    return 1
  fi

  printf "\n🎉 Project '%s' initialized on branch '%s'.\n" "$PROJECT_NAME" "$BRANCH_NAME"
  printf "🌐 GitHub: https://github.com/%s/%s\n" "$user" "$PROJECT_NAME"
  printf "📁 Local:  cd \"%s\"\n\n" "$PROJECT_PATH"
  printf "👉 Next Steps:\n"
  printf "   cd \"%s\"\n" "$PROJECT_PATH"
  printf "   code .\n"
  printf "   git push -u origin %s  # when ready\n" "$BRANCH_NAME"
}

# === Main Execution ===
main() {
  validate_inputs || return 1
  create_structure || return 1
  init_git_repo || return 1
  setup_remote || return 1
  make_initial_commit || return 1
  create_and_switch_branch || return 1
  print_summary || return 1
}

main "$@"
