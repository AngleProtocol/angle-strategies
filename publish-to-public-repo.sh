#!/bin/bash

# check that remote "public-repo" is correctly set
git remote get-url public-repo
if [[ $? -ne 0 ]]; then
    echo "public-repo remote is not set";
    echo "use 'git add remote public-repo https://...'";
    exit 1;
fi

if [[ "$(git symbolic-ref --short -q HEAD)" != "main" ]]; then
    echo "You must be on branch 'main'";
    exit 1;
fi

read -p "Are you sure you want to push? (y/n)? " choice
if [[ "$choice" != "y" ]]; then
    echo "abort...";
    exit 1;
fi

read -p "Branch name on the public repo? " branch_name
git checkout -b "$branch_name"
git push public-repo "$branch_name"
