#!/bin/bash

BASE_DIR="/mnt/apps/mediaserver/config"

# Auto-detect the underlying ZFS dataset
PARENT_DATASET=$(df -T "$BASE_DIR" | awk 'NR==2 {print $1}')

if [[ -z "$PARENT_DATASET" ]]; then
    echo "Error: Could not determine parent dataset for $BASE_DIR"
    exit 1
fi

echo "Detected Parent Dataset: $PARENT_DATASET"
cd "$BASE_DIR" || exit 1

for dir in */; do
    # Remove trailing slash
    APP_NAME="${dir%/}"

    # Skip if it is already a mountpoint (dataset)
    if mountpoint -q "$BASE_DIR/$APP_NAME"; then
        echo "Skipping: $APP_NAME (Already a dataset)"
        continue
    fi

    echo "Converting: $APP_NAME..."

    # 1. Rename existing directory safely
    mv "$APP_NAME" "${APP_NAME}_bak"

    # 2. Create the new ZFS dataset at the exact original path
    zfs create "$PARENT_DATASET/$APP_NAME"

    # 3. Copy data preserving all permissions, ACLs, and extended attributes
    rsync -aHAX "${APP_NAME}_bak/" "$APP_NAME/"

    echo "Completed: $APP_NAME. Original data kept as ${APP_NAME}_bak"
    echo "----------------------------------------"
done

echo "All directories processed."
