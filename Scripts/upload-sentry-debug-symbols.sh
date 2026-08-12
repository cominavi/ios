#!/bin/sh

set -u

case "${CONFIGURATION:-}" in
    Staging|TestFlight) ;;
    *) exit 0 ;;
esac

if [ "${PLATFORM_NAME:-}" != "iphoneos" ]; then
    exit 0
fi

export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
export SENTRY_ORG="${SENTRY_ORG:-cominavi}"
export SENTRY_PROJECT="${SENTRY_PROJECT:-cominavi}"

report_failure() {
    message=$1

    if [ "${CONFIGURATION:-}" = "TestFlight" ] || \
        [ "${SENTRY_SYMBOL_UPLOAD_REQUIRED:-0}" = "1" ]; then
        echo "error: $message"
        exit 1
    fi

    echo "warning: $message"
    exit 0
}

dsym_folder=${DWARF_DSYM_FOLDER_PATH:-}
dsym_name=${DWARF_DSYM_FILE_NAME:-}
if [ -z "$dsym_folder" ] || [ ! -d "$dsym_folder" ]; then
    report_failure "Sentry debug-symbol upload could not find the dSYM directory."
fi

if [ -n "$dsym_name" ] && [ -d "$dsym_folder/$dsym_name" ]; then
    dsym_path="$dsym_folder/$dsym_name"
else
    dsym_path=$dsym_folder
fi

if [ -n "${SENTRY_CLI_EXECUTABLE:-}" ]; then
    if [ ! -x "$SENTRY_CLI_EXECUTABLE" ]; then
        report_failure "SENTRY_CLI_EXECUTABLE is not executable: $SENTRY_CLI_EXECUTABLE"
    fi
    sentry_executable=$SENTRY_CLI_EXECUTABLE
    sentry_generation=${SENTRY_CLI_GENERATION:-4}
elif command -v sentry >/dev/null 2>&1; then
    sentry_executable=$(command -v sentry)
    sentry_generation=4
elif command -v sentry-cli >/dev/null 2>&1; then
    sentry_executable=$(command -v sentry-cli)
    sentry_generation=3
else
    report_failure "Sentry CLI is not installed. Run 'brew install getsentry/tools/sentry'."
fi

echo "Uploading debug symbols with $sentry_executable"

if [ "$sentry_generation" = "3" ]; then
    upload_output=$("$sentry_executable" debug-files upload \
        --include-sources \
        --force-foreground \
        "$dsym_path" 2>&1)
else
    upload_output=$("$sentry_executable" debug-files upload \
        --include-sources \
        --wait \
        "$dsym_path" 2>&1)
fi
upload_status=$?

if [ "$upload_status" -ne 0 ]; then
    report_failure "Sentry debug-symbol upload failed: $upload_output"
fi

printf '%s\n' "$upload_output"
