#!/bin/bash
set -euo pipefail

# === Config ===
BASE_DIR="/c/Users/thisi/workspace/personal"
PROJECT_NAME="${1:-}"
FEATURE_BRANCH="${2:-}"

# === Prompt for Inputs ===
prompt_for_inputs() {
  if [[ -z "$PROJECT_NAME" ]]; then
    read -rp "📁 Enter project name: " PROJECT_NAME
  fi
  if [[ -z "$FEATURE_BRANCH" ]]; then
    read -rp "🌿 Enter feature branch (optional): " FEATURE_BRANCH
  fi

  PROJECT_PATH="$BASE_DIR/$PROJECT_NAME"
}

# === Create Project Structure ===
create_structure() {
  mkdir -p "$PROJECT_PATH/src" "$PROJECT_PATH/tests" "$PROJECT_PATH/docs"
  touch "$PROJECT_PATH/README.md" "$PROJECT_PATH/.gitignore" "$PROJECT_PATH/LICENSE"
  touch "$PROJECT_PATH/docs/overview.md"
}

# === Initialize Git Repo ===
init_git_repo() {
  cd "$PROJECT_PATH"
  if [[ ! -d .git ]]; then
    git init
    printf "✅ Git repository initialized\n"
  else
    printf "⚠️ Repo already exists — skipping init\n"
  fi
}

# === Create Remote Repo ===
setup_remote() {
  if ! command -v gh &>/dev/null; then
    printf "❌ GitHub CLI not found — install at https://cli.github.com/\n" >&2
    return 1
  fi

  if ! git remote | grep -q "^origin$"; then
    gh repo create "$PROJECT_NAME" --source=. --public --remote=origin
    printf "✅ Remote repo created and linked\n"
  else
    printf "⚠️ Remote 'origin' already exists — skipping\n"
  fi
}

# === Commit and Push main ===
make_initial_commit_and_push_main() {
  if ! git log &>/dev/null; then
    git add .
    git commit -m "initial commit"
    git branch -M main
    git push -u origin main
    printf "✅ Initial commit pushed to 'main'\n"
  else
    printf "⚠️ Repo already has commits — skipping push\n"
  fi
}

# === Create and Switch to Feature Branch (local only) ===
create_feature_branch() {
  if [[ -n "$FEATURE_BRANCH" ]]; then
    if git show-ref --verify --quiet "refs/heads/$FEATURE_BRANCH"; then
      git switch "$FEATURE_BRANCH"
      printf "✅ Switched to existing branch: %s\n" "$FEATURE_BRANCH"
    else
      git switch -c "$FEATURE_BRANCH"
      printf "✅ Created and switched to new branch: %s\n" "$FEATURE_BRANCH"
    fi
  fi
}

# === Summary ===
print_summary() {
  local user
  user=$(gh api user --jq .login 2>/dev/null || echo "unknown-user")

  printf "\n🎉 Project '%s' initialized.\n" "$PROJECT_NAME"
  printf "🌐 GitHub: https://github.com/%s/%s\n" "$user" "$PROJECT_NAME"
  printf "📁 Local:  cd \"%s\"\n\n" "$PROJECT_PATH"

  printf "👉 Next Steps:\n"
  printf "   cd \"%s\"\n" "$PROJECT_PATH"
  printf "   code .\n"
  if [[ -n "$FEATURE_BRANCH" ]]; then
    printf "   git push -u origin %s  # when ready\n" "$FEATURE_BRANCH"
  fi
}

# === Main ===
main() {
  prompt_for_inputs
  create_structure
  init_git_repo
  setup_remote
  make_initial_commit_and_push_main
  create_feature_branch
  print_summary
}

main "$@"
