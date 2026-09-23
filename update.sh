#!/bin/bash
set -e

# ============================================================
# Xu Group website deployment
#
# Local repository:
#   Z:\GroupWebsite\xu_group_website
#
# Change list:
#   Z:\GroupWebsite\deploy_changes.txt
#
# Remote website:
#   /var/www/html/htdocs-groups/xugroup
#
# Run this script from Git Bash.
# ============================================================


# ------------------------------------------------------------
# Configuration
# ------------------------------------------------------------

REMOTE="haotian_chen@euclid.decf.berkeley.edu"
WEBROOT="/var/www/html/htdocs-groups/xugroup"

# Always use the directory containing this script as repository root
REPO="$(cd "$(dirname "$0")" && pwd)"

# push_to_git.sh creates this one directory above the repository
CHANGE_LIST="$REPO/../deploy_changes.txt"


# ------------------------------------------------------------
# Basic checks
# ------------------------------------------------------------

cd "$REPO"

if [ ! -f "$CHANGE_LIST" ]; then
    echo ""
    echo "ERROR: deploy_changes.txt was not found:"
    echo "$CHANGE_LIST"
    echo ""
    echo "Run push_to_git.sh first."
    exit 1
fi

if [ ! -s "$CHANGE_LIST" ]; then
    echo ""
    echo "No changed files to deploy."
    exit 0
fi


echo ""
echo "=========================================="
echo "Xu Group website deployment"
echo "=========================================="
echo ""
echo "Repository:"
echo "$REPO"
echo ""
echo "Changes:"
cat "$CHANGE_LIST"
echo ""


# ------------------------------------------------------------
# Create local temporary deployment directory
# ------------------------------------------------------------

TMPROOT="$(mktemp -d)"
STAGE="$TMPROOT/files"
DELETE_LIST="$TMPROOT/delete.list"
PACKAGE="$TMPROOT/deploy.tar.gz"

mkdir -p "$STAGE"
touch "$DELETE_LIST"

# Always clean local temporary files when script exits
cleanup_local() {
    rm -rf "$TMPROOT"
}

trap cleanup_local EXIT


# ------------------------------------------------------------
# Helper: decide whether a file should NOT be published
# ------------------------------------------------------------

should_skip() {
    local FILE="$1"

    case "$FILE" in
        .git|.git/*)
            return 0
            ;;
        .DS_Store|*/.DS_Store)
            return 0
            ;;
        deploy_changes.txt)
            return 0
            ;;
        push_to_git.sh)
            return 0
            ;;
        deploy_to_server.sh)
            return 0
            ;;
        update.sh)
            return 0
            ;;
    esac

    return 1
}


# ------------------------------------------------------------
# Helper: stage a changed file while preserving its path
# ------------------------------------------------------------

stage_file() {
    local FILE="$1"

    if should_skip "$FILE"; then
        echo "Skipping deployment file: $FILE"
        return
    fi

    if [ ! -f "$REPO/$FILE" ]; then
        echo "WARNING: file does not exist locally: $FILE"
        return
    fi

    mkdir -p "$STAGE/$(dirname "$FILE")"
    cp -p "$REPO/$FILE" "$STAGE/$FILE"

    echo "Upload: $FILE"
}


# ------------------------------------------------------------
# Read Git change list
#
# Expected examples:
#
# M       members.html
# A       images/person.jpg
# D       images/old.jpg
# R100    old.jpg     new.jpg
# ------------------------------------------------------------

while IFS=$'\t' read -r STATUS FILE1 FILE2
do
    # Ignore blank lines
    [ -z "$STATUS" ] && continue

    case "$STATUS" in

        A|M|T)
            stage_file "$FILE1"
            ;;

        D)
            if ! should_skip "$FILE1"; then
                echo "$FILE1" >> "$DELETE_LIST"
                echo "Delete: $FILE1"
            fi
            ;;

        R*)
            # Rename:
            # upload the new file
            # remove the old remote file
            stage_file "$FILE2"

            if ! should_skip "$FILE1"; then
                echo "$FILE1" >> "$DELETE_LIST"
                echo "Remove old renamed file: $FILE1"
            fi
            ;;

        C*)
            # Git copy detection
            stage_file "$FILE2"
            ;;

        *)
            echo "WARNING: unrecognized Git status:"
            echo "$STATUS $FILE1 $FILE2"
            ;;

    esac

done < "$CHANGE_LIST"


# ------------------------------------------------------------
# Create deployment package
#
# Structure:
#
# deploy.tar.gz
# ├── files/
# │   ├── members.html
# │   └── images/...
# └── delete.list
# ------------------------------------------------------------

tar -czf "$PACKAGE" \
    -C "$TMPROOT" \
    files \
    delete.list


echo ""
echo "Deployment package created."
echo "Package size:"
du -h "$PACKAGE"
echo ""


# ------------------------------------------------------------
# Deploy through ONE SSH connection
#
# The package is streamed through stdin.
# No tar.gz file is written to the remote server.
# ------------------------------------------------------------

echo "Connecting to euclid..."
echo "You should only need to enter your DECF password once."
echo ""


cat "$PACKAGE" | ssh "$REMOTE" "WEBROOT='$WEBROOT' bash -c '


set -e


# ------------------------------------------------------------
# Create private temporary directory on euclid
# ------------------------------------------------------------

TMP=\$(mktemp -d \"\$HOME/.xugroup-deploy.XXXXXX\")


# Remove temporary directory whether deployment succeeds or fails
cleanup_remote() {
    rm -rf \"\$TMP\"
}

trap cleanup_remote EXIT HUP INT TERM


# ------------------------------------------------------------
# Receive archive directly from SSH stdin
# ------------------------------------------------------------

tar -xzf - -C \"\$TMP\"


# ------------------------------------------------------------
# Safety check
# ------------------------------------------------------------

if [ ! -d \"\$WEBROOT\" ]; then
    echo \"ERROR: Website directory does not exist.\"
    exit 1
fi


# ------------------------------------------------------------
# Publish added/modified files
# ------------------------------------------------------------

if [ -d \"\$TMP/files\" ]; then

    cd \"\$TMP/files\"

    find . -type f -print0 | while IFS= read -r -d \"\" SRC
    do
        REL=\${SRC#./}

        # Reject unsafe paths
        case \"\$REL\" in
            \"\"|/*|../*|*/../*|*/..)
                echo \"ERROR: Unsafe path rejected: \$REL\"
                exit 1
                ;;
        esac

        DEST=\"\$WEBROOT/\$REL\"
        DESTDIR=\$(dirname \"\$DEST\")

        mkdir -p \"\$DESTDIR\"

        echo \"Updating: \$REL\"

        cp -f -- \"\$SRC\" \"\$DEST\"

        # Keep files writable by the Xu group
        chgrp xugrp \"\$DEST\" 2>/dev/null || true
        chmod g+rw \"\$DEST\" 2>/dev/null || true

        # Ensure containing directory remains group writable
        chgrp xugrp \"\$DESTDIR\" 2>/dev/null || true
        chmod g+rws \"\$DESTDIR\" 2>/dev/null || true

    done

fi


# ------------------------------------------------------------
# Apply Git deletions / old names from renames
# ------------------------------------------------------------

if [ -s \"\$TMP/delete.list\" ]; then

    while IFS= read -r REL
    do
        [ -z \"\$REL\" ] && continue

        # Reject unsafe paths
        case \"\$REL\" in
            /*|../*|*/../*|*/..)
                echo \"ERROR: Unsafe delete path rejected: \$REL\"
                exit 1
                ;;
        esac

        TARGET=\"\$WEBROOT/\$REL\"

        if [ -f \"\$TARGET\" ] || [ -L \"\$TARGET\" ]; then
            echo \"Deleting: \$REL\"
            rm -f -- \"\$TARGET\"
        else
            echo \"Already absent: \$REL\"
        fi

    done < \"\$TMP/delete.list\"

fi


echo \"\"
echo \"Deployment completed successfully.\"
echo \"Temporary deployment files removed automatically.\"

'"