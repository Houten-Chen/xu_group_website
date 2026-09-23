#!/bin/bash
set -e

# Always work from the directory containing this script
cd "$(dirname "$0")"

echo "Checking GitHub..."
git fetch origin master

# Remember where GitHub master was before this update
BASE=$(git rev-parse origin/master)

echo "Adding local changes..."
git add -A

# Commit only if there are staged changes
if ! git diff --cached --quiet; then
    git commit -m "Update Xu Group website"
else
    echo "No new uncommitted changes."
fi

echo "Pushing to GitHub..."
git push origin master

# Generate a list of everything changed in this push
git diff --name-status --find-renames "$BASE" HEAD > ../deploy_changes.txt

echo ""
echo "Files changed in this update:"
cat ../deploy_changes.txt

echo ""
echo "Change list saved to:"
echo "../deploy_changes.txt"

echo "Done!"