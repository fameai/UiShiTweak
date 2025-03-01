#!/bin/bash

DYLIB_PATH="libs/libHandleURLScheme.dylib"

# Fix main dylib install name
install_name_tool -id @rpath/libHandleURLScheme.dylib "$DYLIB_PATH"

# Function to check if rpath exists
check_rpath() {
    local dylib="$1"
    local rpath="$2"
    otool -l "$dylib" | grep -A2 LC_RPATH | grep -q "path $rpath"
    return $?
}

# Detect if we're building for rootless
IS_ROOTLESS=0
if [ -n "$ROOTLESS" ] && [ "$ROOTLESS" = "1" ]; then
    IS_ROOTLESS=1
fi

# Set framework paths based on rootless status
if [ "$IS_ROOTLESS" = "1" ]; then
    FRAMEWORKS_PATH="/var/jb/Library/Frameworks"
else
    FRAMEWORKS_PATH="/Library/Frameworks"
fi

# Add rpaths for framework lookup only if they don't exist
if ! check_rpath "$DYLIB_PATH" "$FRAMEWORKS_PATH"; then
    install_name_tool -add_rpath "$FRAMEWORKS_PATH" "$DYLIB_PATH"
fi

if ! check_rpath "$DYLIB_PATH" "@loader_path/../Frameworks"; then
    install_name_tool -add_rpath @loader_path/../Frameworks "$DYLIB_PATH"
fi 