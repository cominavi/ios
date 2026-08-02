#!/bin/sh

set -eu

# Xcode 26.6 invokes Apple's /usr/bin/rsync while exporting an archive. That
# client starts a second `rsync` process through PATH. If Homebrew's rsync wins,
# the two implementations disagree about Apple's extended-attribute option and
# the export ends with the unhelpful "Copy failed" error.
if [ "${CI_XCODE_CLOUD:-}" != "TRUE" ]; then
    exit 0
fi

resolved_rsync=$(command -v rsync)

if ! "$resolved_rsync" --help 2>&1 | grep -q -- '--extended-attributes'; then
    case "$resolved_rsync" in
        /opt/homebrew/bin/rsync|/usr/local/bin/rsync)
            echo "Unlinking incompatible Homebrew rsync at $resolved_rsync"
            brew unlink rsync
            ;;
        *)
            echo "error: Xcode Cloud resolved an incompatible rsync at $resolved_rsync"
            exit 1
            ;;
    esac
fi

resolved_rsync=$(command -v rsync)

if [ "$resolved_rsync" != "/usr/bin/rsync" ]; then
    echo "error: Xcode Cloud must use /usr/bin/rsync, resolved $resolved_rsync"
    exit 1
fi

echo "Using Apple-compatible rsync at $resolved_rsync"
