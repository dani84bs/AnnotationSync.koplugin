#!/bin/bash

# AnnotationSync Test Runner
# Usage: ./run_tests.sh <path_to_koreader_root>

set -e

if [ "$#" -ne 1 ]; then
    echo "Usage: $0 <path_to_koreader_root>"
    exit 1
fi

# Resolve absolute paths
KO_DIR=$(cd "$1" && pwd)
PLUGIN_DIR="$KO_DIR/plugins/AnnotationSync.koplugin"
PLUGIN_SPEC_DIR="$PLUGIN_DIR/spec/unit"
SPEC_DST_DIR="$KO_DIR/spec/unit"

# Automatically detect all .lua files in the plugin spec directory
FILES=($(cd "$PLUGIN_SPEC_DIR" && ls *.lua))

# Derive test names from files ending in _spec.lua
TEST_NAMES=()
for file in "${FILES[@]}"; do
    if [[ "$file" == *_spec.lua ]]; then
        # Remove _spec.lua suffix
        TEST_NAMES+=("${file%_spec.lua}")
    fi
done

cleanup() {
    echo ""
    echo ">> Cleaning up symlinks in $SPEC_DST_DIR..."
    for file in "${FILES[@]}"; do
        if [ -L "$SPEC_DST_DIR/$file" ]; then
            rm "$SPEC_DST_DIR/$file"
        fi
    done
}

# Ensure cleanup happens on exit
trap cleanup EXIT

echo ">> Linking AnnotationSync specs into $SPEC_DST_DIR..."
for file in "${FILES[@]}"; do
    ln -sf "$PLUGIN_SPEC_DIR/$file" "$SPEC_DST_DIR/$file"
done

echo ">> Executing tests: ${TEST_NAMES[*]}..."
cd "$KO_DIR"
./kodev test front "${TEST_NAMES[@]}"