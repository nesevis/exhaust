#!/usr/bin/env bash
set -euo pipefail

export EXHAUST_BUILD_XCFRAMEWORK=1
PACKAGE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${PACKAGE_DIR}/.build/xcframework-staging"
OUTPUT_DIR="${PACKAGE_DIR}/Frameworks"

EVOLUTION_FLAGS=(-Xswiftc -enable-library-evolution -Xswiftc -emit-module-interface -Xswiftc -enable-testing)
IOS_SIM_SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
IOS_DEPLOYMENT_TARGET="18.0"

echo "==> Cleaning staging area"
rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}"

# ---------- Build for each triple ----------
# Use --target to avoid building tool dependencies (like SwiftLint, DocC)
# which fail module-interface verification with evolution flags.

build_triple() {
    local triple=$1
    shift
    echo "==> Building ExhaustCore for ${triple}"
    swift build \
        --package-path "${PACKAGE_DIR}" \
        --triple "${triple}" \
        --configuration release \
        "${EVOLUTION_FLAGS[@]}" \
        "$@" \
        --target ExhaustCore 2>&1 | tail -1
}

build_triple arm64-apple-macosx

build_triple arm64-apple-ios-simulator \
    -Xswiftc -sdk -Xswiftc "${IOS_SIM_SDK}" \
    -Xswiftc -target -Xswiftc "arm64-apple-ios${IOS_DEPLOYMENT_TARGET}-simulator"

build_triple x86_64-apple-ios-simulator \
    -Xswiftc -sdk -Xswiftc "${IOS_SIM_SDK}" \
    -Xswiftc -target -Xswiftc "x86_64-apple-ios${IOS_DEPLOYMENT_TARGET}-simulator"

# ---------- Collect artefacts per-platform ----------
#
# With --target, SPM doesn't produce a .a; we create it from the .o files.
# Module artefacts:
#   Modules/ExhaustCore.swiftmodule  (compiled binary)
#   Modules/ExhaustCore.swiftdoc
#   ExhaustCore.build/ExhaustCore.swiftinterface
#   ExhaustCore.build/ExhaustCore.private.swiftinterface

collect() {
    local triple=$1 arch_qualifier=$2 dest=$3
    local build_products="${PACKAGE_DIR}/.build/${triple}/release"

    mkdir -p "${dest}/ExhaustCore.swiftmodule"

    # Create static library from object files
    ar rcs "${dest}/libExhaustCore.a" "${build_products}/ExhaustCore.build/"*.o

    # Compiled module (binary .swiftmodule)
    cp "${build_products}/Modules/ExhaustCore.swiftmodule" \
       "${dest}/ExhaustCore.swiftmodule/${arch_qualifier}.swiftmodule"

    # Swiftdoc
    if [ -f "${build_products}/Modules/ExhaustCore.swiftdoc" ]; then
        cp "${build_products}/Modules/ExhaustCore.swiftdoc" \
           "${dest}/ExhaustCore.swiftmodule/${arch_qualifier}.swiftdoc"
    fi

    # ABI descriptor
    if [ -f "${build_products}/Modules/ExhaustCore.abi.json" ]; then
        cp "${build_products}/Modules/ExhaustCore.abi.json" \
           "${dest}/ExhaustCore.swiftmodule/${arch_qualifier}.abi.json"
    fi

    # Textual interfaces (for library evolution)
    if [ -f "${build_products}/ExhaustCore.build/ExhaustCore.swiftinterface" ]; then
        cp "${build_products}/ExhaustCore.build/ExhaustCore.swiftinterface" \
           "${dest}/ExhaustCore.swiftmodule/${arch_qualifier}.swiftinterface"
    fi
    if [ -f "${build_products}/ExhaustCore.build/ExhaustCore.private.swiftinterface" ]; then
        cp "${build_products}/ExhaustCore.build/ExhaustCore.private.swiftinterface" \
           "${dest}/ExhaustCore.swiftmodule/${arch_qualifier}.private.swiftinterface"
    fi
}

MACOS_DIR="${BUILD_DIR}/macos-arm64"
IOS_SIM_ARM64_DIR="${BUILD_DIR}/ios-simulator-arm64"
IOS_SIM_X86_DIR="${BUILD_DIR}/ios-simulator-x86_64"
IOS_SIM_FAT_DIR="${BUILD_DIR}/ios-simulator-fat"

collect arm64-apple-macosx         "arm64-apple-macos"             "${MACOS_DIR}"
collect arm64-apple-ios-simulator  "arm64-apple-ios-simulator"     "${IOS_SIM_ARM64_DIR}"
collect x86_64-apple-ios-simulator "x86_64-apple-ios-simulator"    "${IOS_SIM_X86_DIR}"

# ---------- Create fat iOS Simulator library ----------

echo "==> Creating fat iOS Simulator library"
mkdir -p "${IOS_SIM_FAT_DIR}/ExhaustCore.swiftmodule"

lipo -create \
    "${IOS_SIM_ARM64_DIR}/libExhaustCore.a" \
    "${IOS_SIM_X86_DIR}/libExhaustCore.a" \
    -output "${IOS_SIM_FAT_DIR}/libExhaustCore.a"

# Merge swiftmodule directories (both architectures into one)
cp "${IOS_SIM_ARM64_DIR}/ExhaustCore.swiftmodule/"* "${IOS_SIM_FAT_DIR}/ExhaustCore.swiftmodule/"
for f in "${IOS_SIM_X86_DIR}/ExhaustCore.swiftmodule/"*; do
    cp -n "$f" "${IOS_SIM_FAT_DIR}/ExhaustCore.swiftmodule/" 2>/dev/null || true
done

# ---------- Assemble xcframework ----------

echo "==> Assembling ExhaustCore.xcframework"
mkdir -p "${OUTPUT_DIR}"
rm -rf "${OUTPUT_DIR}/ExhaustCore.xcframework"

# Create bare xcframework with just the libraries
xcodebuild -create-xcframework \
    -library "${MACOS_DIR}/libExhaustCore.a" \
    -library "${IOS_SIM_FAT_DIR}/libExhaustCore.a" \
    -output "${OUTPUT_DIR}/ExhaustCore.xcframework"

# Inject Swift module directories into each slice.
# SPM resolves binary modules from <slice>/ExhaustCore.swiftmodule/
for slice_dir in "${OUTPUT_DIR}/ExhaustCore.xcframework/"*/; do
    [ -d "${slice_dir}" ] || continue
    local_name="$(basename "${slice_dir}")"
    case "${local_name}" in
        macos-arm64)
            cp -R "${MACOS_DIR}/ExhaustCore.swiftmodule" "${slice_dir}/"
            ;;
        ios-arm64_x86_64-simulator)
            cp -R "${IOS_SIM_FAT_DIR}/ExhaustCore.swiftmodule" "${slice_dir}/"
            ;;
    esac
done

echo "==> Done: ${OUTPUT_DIR}/ExhaustCore.xcframework"
echo ""
echo "Contents:"
find "${OUTPUT_DIR}/ExhaustCore.xcframework" -type f | sort | sed "s|${OUTPUT_DIR}/||"
