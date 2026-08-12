#!/bin/sh

set -eu

SENTRY_CLI_VERSION=${SENTRY_CLI_VERSION:-0.42.2}
SENTRY_INSTALL_DIR=${SENTRY_INSTALL_DIR:-$HOME/.local/bin}
export SENTRY_CLI_VERSION SENTRY_INSTALL_DIR

if [ -x "$SENTRY_INSTALL_DIR/sentry" ]; then
    installed_version=$($SENTRY_INSTALL_DIR/sentry --version)
    if [ "$installed_version" = "$SENTRY_CLI_VERSION" ]; then
        echo "Using Sentry CLI $installed_version at $SENTRY_INSTALL_DIR/sentry"
        exit 0
    fi
fi

echo "Installing Sentry CLI $SENTRY_CLI_VERSION into $SENTRY_INSTALL_DIR"
mkdir -p "$SENTRY_INSTALL_DIR"

installer_path="${TMPDIR:-/tmp}/cominavi-sentry-cli-install.sh"
curl https://cli.sentry.dev/install -fsS -o "$installer_path"
SENTRY_VERSION=$SENTRY_CLI_VERSION bash "$installer_path" \
    --no-modify-path \
    --no-completions \
    --no-agent-skills

installed_version=$($SENTRY_INSTALL_DIR/sentry --version)
if [ "$installed_version" != "$SENTRY_CLI_VERSION" ]; then
    echo "error: expected Sentry CLI $SENTRY_CLI_VERSION, installed $installed_version"
    exit 1
fi

echo "Installed Sentry CLI $installed_version at $SENTRY_INSTALL_DIR/sentry"
