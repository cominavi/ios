#!/bin/sh

set -eu

# Xcode 26.6 invokes Apple's /usr/bin/rsync while exporting an archive. That
# client starts a second `rsync` process through PATH. If Homebrew's rsync wins,
# the two implementations disagree about Apple's extended-attribute option and
# the export ends with the unhelpful "Copy failed" error.
if [ "${CI_XCODE_CLOUD:-}" != "TRUE" ]; then
    exit 0
fi

# Trust the checked-in Swift OpenAPI build plugin on fresh Xcode Cloud workers.
defaults write com.apple.dt.Xcode IDESkipPackagePluginFingerprintValidatation -bool YES

# Deployment preparation can prepend Homebrew after this script finishes, so
# check the installed formula rather than trusting the current PATH alone.
if command -v brew >/dev/null 2>&1 && brew list --versions rsync >/dev/null 2>&1; then
    echo "Unlinking Homebrew rsync before Xcode Cloud deployment preparation"
    brew unlink rsync
fi

resolved_rsync=$(command -v rsync)

if [ "$resolved_rsync" != "/usr/bin/rsync" ] || \
    ! "$resolved_rsync" --help 2>&1 | grep -q -- '--extended-attributes'; then
    echo "error: Xcode Cloud must use /usr/bin/rsync, resolved $resolved_rsync"
    exit 1
fi

echo "Using Apple-compatible rsync at $resolved_rsync"
