#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
: "${RELEASE_REPOSITORY:?Set RELEASE_REPOSITORY}"
: "${RELEASE_TAG:?Set RELEASE_TAG}"
: "${VERSION:?Set VERSION}"
test "$RELEASE_TAG" = "v$VERSION"
exec python3 -B script/ci-release.py publish "$RELEASE_TAG" "$RELEASE_REPOSITORY" "${RELEASE_DIR:-.release}"
