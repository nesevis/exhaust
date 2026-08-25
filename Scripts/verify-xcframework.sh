#!/usr/bin/env bash
# Builds and runs ArtifactSmoke, an external-package consumer of the ExhaustCore xcframework, in both configurations. In-package test targets load ExhaustCore's package interface; only a package outside the `exhaust` boundary compiles against the public interface and therefore sees the layout and export mistakes that reach real consumers.
set -euo pipefail

PACKAGE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SMOKE_DIR="${PACKAGE_DIR}/ArtifactSmoke"

if [ ! -d "${PACKAGE_DIR}/Frameworks/ExhaustCore.xcframework" ]; then
    echo "::error::Frameworks/ExhaustCore.xcframework is missing; run Scripts/build-xcframework.sh first."
    exit 1
fi

# A source-built ExhaustCore module left in .build shadows the artifact's interface, so start clean.
rm -rf "${SMOKE_DIR}/.build"

for configuration in debug release; do
    echo "==> ArtifactSmoke (${configuration})"
    EXHAUST_RELEASE=1 swift build --package-path "${SMOKE_DIR}" --configuration "${configuration}" --product ArtifactSmoke
    "${SMOKE_DIR}/.build/${configuration}/ArtifactSmoke"
done
