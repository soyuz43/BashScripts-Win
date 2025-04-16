#!/usr/bin/env bash

set -o pipefail

# Function to check if the current branch is main or master
check_branch() {
    local branch_name
    branch_name=$(git rev-parse --abbrev-ref HEAD)
    if [[ "$branch_name" == "main" || "$branch_name" == "master" ]]; then
        printf "\e[1;31mError, on main, you must manually commit\e[0m\n" >&2
        return 1
    fi
}

main() {

    # Check if .git directory exists in the current directory
    if [ ! -d ".git" ]; then
        echo -e "\e[1;31mThis directory is not a git repository.\e[0m"
        return 1
    fi

    if ! check_branch; then
        return 1
    fi

    git add .

    echo -e "\n\e[1;3;36mCurrent Git Status:\e[0m"

    git status

    # Prompt the user to decide whether to commit
    read -p $'\e[1;33mWould you like to commit ([y]/n)? \e[0m' commit_decision

    # Default to "y" if no input (Enter is pressed)
    commit_decision=${commit_decision:-y}

    # Check the user's decision
    if [[ "$commit_decision" == "y" ]]; then
        
        # Prompt the user for a commit message
        read -p $'\e[1;32mEnter commit message, quotes not needed: \e[0m' commit_message

        # Add quotes around the commit message and commit
        git commit -m "$commit_message"
        echo -e "\e[1;32mCommit successful.\e[0m"
    else
        echo -e "\e[1;31mCommit aborted.\e[0m"
        return 1
    fi
}

main "$@"
