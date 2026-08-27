#!/bin/bash
# Fetches the pinned Sparkle release into vendor/. Idempotent; verifies by hash,
# because a release label can be repointed and a hash cannot.
set -euo pipefail
cd "$(dirname "$0")/.."

SPARKLE_VERSION="2.9.6"
SPARKLE_SHA256="52bf9e88cdd972fc0c81501377a880e90d47031bd8ca5462488f843e2609e192"

[ -d vendor/Sparkle.framework ] && exit 0
mkdir -p vendor
ARCHIVE="vendor/Sparkle-$SPARKLE_VERSION.tar.xz"
curl -sL -o "$ARCHIVE" \
	"https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz"
echo "$SPARKLE_SHA256  $ARCHIVE" | shasum -a 256 -c - >/dev/null
tar -xf "$ARCHIVE" -C vendor
