#!/usr/bin/env bash

# Enable extended globbing for better pattern matching
shopt -s extglob

# Define colors
PINK='\033[1;35m'  # Bold Pink for branches other than main
GREEN='\033[1;32m' # Bold Green for the main branch
BOLD='\033[1m'
ITALIC='\033[3m'
RED='\033[1;31m'    # Bold Red for warnings
RESET='\033[0m'
BOLDYELLOW='\033[1;33m' # Bold Yellow
YELLOW='\033[33m'  # Yellow for author names

# Enable pipefail to catch errors in piped commands
set -o pipefail

function list_local_branches {
  # Fetch branches with their creation dates and authors
  local branches_with_info=$(git for-each-ref --sort=creatordate --format='%(refname:short) %(creatordate:short) %(authorname)' refs/heads/)
  
  # Find the maximum length of the branch names to align the output
  local max_branch_length=$(echo "$branches_with_info" | awk '{print length($1)}' | sort -nr | head -n1)

  # Iterate through each branch and apply color formatting with alignment
  echo "$branches_with_info" | while IFS=' ' read -r branch creation_date author; do
    # Format the creation date as "mm-dd-yy"
    formatted_date=$(date -d "$creation_date" +"%m-%d-%y")
    # Determine color based on branch name
    local color end_color author_color
    if [[ "$branch" == "main" || "$branch" == "master" ]]; then
        color=$GREEN end_color=$RESET
    else
        color=$PINK end_color=$RESET
    fi
    author_color=$YELLOW
    # Calculate padding for alignment
    local padding=$((max_branch_length + 2 - ${#branch}))
    # Print the branch name in color with aligned date and author
    printf "%b%s%*s%s | %bAuthor:%b %s\n" "$color" "$branch" "$padding" "" "$formatted_date" "$author_color" "$end_color" "$author"
  done
}

function delete_branch {
  local branches=($@)
  local num_branches=${#branches[@]}
  if [[ $num_branches -eq 0 ]]; then
    printf "No branch selected. Exiting.\n" >&2
    return 1
  fi

  # Confirmation prompt
  echo ""
 if [[ $num_branches -ge 1 ]]; then
  printf "${RED}Warning!${RESET} ${YELLOW}You are about to delete branche(s):${RESET} ${PINK}%s${RESET}.\n" "${branches[*]}"
  echo ""
  printf "${YELLOW}Type ${ITALIC}${GREEN}confirm${RESET}${YELLOW} to delete all listed branches, or ${ITALIC}q${RESET}${YELLOW} to quit:${RESET} "
  read -r user_input

  if [[ "$user_input" == "confirm" || "$user_input" == "con" || "$user_input" == "conf" ]]; then
    for branch in "${branches[@]}"; do
      if ! git branch -d "$branch"; then
        printf "${RED}Failed to delete branch ${RESET}'%s'.\n" "$branch" >&2
        continue
      fi
      printf "${GREEN}Branch '%s' deleted successfully.${RESET}\n" "$branch"
    done
  elif [[ "$user_input" == "n" || "$user_input" == "q" ]]; then
    printf "Quitting.\n"
    return 0
  else
    printf "${RED}Invalid option. Exiting.${RESET}\n"
    return 1
  fi
else
  echo "No branches to delete."
fi
}
function main {
  # List all local branches in a vertical column with styles and details
  echo ""
  echo "Local branches:"
  echo ""
  list_local_branches
  printf "\nWhat branches? (separate multiple branches with spaces): "
  
  local branches
  read -r branches

  delete_branch $branches
}

main