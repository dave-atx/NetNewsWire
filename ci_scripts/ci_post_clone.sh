#!/bin/bash

# Xcode Cloud post-clone hook. Runs for every Xcode Cloud build of this repo.
#
# Secrets generation always runs, since the build won't compile without it.
# The personal signing override below only applies when the specific Xcode
# Cloud workflow opts in via a workflow-level environment variable named
# PERSONAL_TESTFLIGHT_BUILD (set to 1 in the workflow's own settings, not
# committed anywhere) -- so this script can't silently push Dave's team ID
# and org identifier onto some other Xcode Cloud workflow that happens to
# build this repo.

set -euo pipefail

cd "$CI_PRIMARY_REPOSITORY_PATH"
PROJECT_DIR="$CI_PRIMARY_REPOSITORY_PATH" ./buildscripts/updateSecrets.sh

if [[ "${PERSONAL_TESTFLIGHT_BUILD:-}" != "1" ]]; then
  echo "PERSONAL_TESTFLIGHT_BUILD not set; skipping personal signing overrides."
  exit 0
fi

settings_dir="$CI_PRIMARY_REPOSITORY_PATH/../SharedXcodeSettings"
mkdir -p "$settings_dir"
cat > "$settings_dir/DeveloperSettings.xcconfig" <<EOF
DEVELOPMENT_TEAM = 5WM6947328
CODE_SIGN_STYLE = Automatic
ORGANIZATION_IDENTIFIER = org.marquard
DEVELOPER_ENTITLEMENTS = -dev
EOF
