#!/usr/bin/env bash
set -euo pipefail

export EXHAUST_BUILD_XCFRAMEWORK=1
PACKAGE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${PACKAGE_DIR}/.build/xcframework-staging"
OUTPUT_DIR="${PACKAGE_DIR}/Frameworks"

EVOLUTION_FLAGS=(-Xswiftc -enable-library-evolution -Xswiftc -emit-module-interface -Xswiftc -package-name -Xswiftc exhaust -Xswiftc -gnone)
MACOS_DEPLOYMENT_TARGET="12.0"

IOS_SIM_SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
IOS_DEV_SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
IOS_DEPLOYMENT_TARGET="15.0"

TVOS_SIM_SDK="$(xcrun --sdk appletvsimulator --show-sdk-path)"
TVOS_DEV_SDK="$(xcrun --sdk appletvos --show-sdk-path)"
TVOS_DEPLOYMENT_TARGET="15.0"

WATCHOS_SIM_SDK="$(xcrun --sdk watchsimulator --show-sdk-path)"
WATCHOS_DEV_SDK="$(xcrun --sdk watchos --show-sdk-path)"
WATCHOS_DEPLOYMENT_TARGET="9.0"
# watchOS 26 introduced the arm64 device ABI; older watches use arm64_32.
WATCHOS_ARM64_DEPLOYMENT_TARGET="26.0"

VISIONOS_SIM_SDK="$(xcrun --sdk xrsimulator --show-sdk-path)"
VISIONOS_DEV_SDK="$(xcrun --sdk xros --show-sdk-path)"
VISIONOS_DEPLOYMENT_TARGET="1.0"

echo "==> Cleaning staging area and stale build products"
rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}"

# Remove stale .o files from SPM's incremental build cache.
# Without this, object files from deleted source files survive and
# get archived into the static library by the ar glob below.
for triple in arm64-apple-macosx arm64e-apple-macosx x86_64-apple-macosx \
    arm64-apple-ios arm64-apple-ios-simulator x86_64-apple-ios-simulator \
    arm64-apple-tvos arm64-apple-tvos-simulator x86_64-apple-tvos-simulator \
    arm64-apple-watchos arm64_32-apple-watchos arm64-apple-watchos-simulator x86_64-apple-watchos-simulator; do
    rm -rf "${PACKAGE_DIR}/.build/${triple}/release/ExhaustCore.build"
done
# visionOS uses separate scratch paths (--sdk workaround)
rm -rf "${PACKAGE_DIR}/.build/xros-device" "${PACKAGE_DIR}/.build/xros-sim"

# Pre-resolve so parallel builds don't race on the workspace lock
swift package resolve --package-path "${PACKAGE_DIR}"

# ---------- Build for each triple ----------
# Use --target to avoid building tool dependencies (like SwiftLint, DocC)
# which fail module-interface verification with evolution flags.

build_triple() {
    local triple=$1
    shift
    echo "==> Building ExhaustCore for ${triple}"
    swift build \
        --build-system native \
        --package-path "${PACKAGE_DIR}" \
        --triple "${triple}" \
        --configuration release \
        "${EVOLUTION_FLAGS[@]}" \
        "$@" \
        --target ExhaustCore 2>&1 | tail -20
}

# SwiftPM 6.3 crashes on --triple arm64-apple-xros (Triple+Basics.swift fatalError
# for "unknown os" when computing dynamic library extensions). Work around by using
# --sdk with a separate --scratch-path and passing the target triple via -Xswiftc, and via -Xcc so the
# ExhaustCoverageRuntime C target is compiled for visionOS rather than the macOS host.
XROS_DEV_SCRATCH="${PACKAGE_DIR}/.build/xros-device"
XROS_SIM_SCRATCH="${PACKAGE_DIR}/.build/xros-sim"

build_xros() {
    local label=$1 sdk_path=$2 target_triple=$3 scratch_path=$4
    echo "==> Building ExhaustCore for ${label}"
    swift build \
        --build-system native \
        --package-path "${PACKAGE_DIR}" \
        --scratch-path "${scratch_path}" \
        --sdk "${sdk_path}" \
        --configuration release \
        "${EVOLUTION_FLAGS[@]}" \
        -Xswiftc -target -Xswiftc "${target_triple}" \
        -Xcc -target -Xcc "${target_triple}" \
        --target ExhaustCore 2>&1 | tail -20
}

PIDS=()

# Keep both Swift and C object files at the package's macOS deployment minimum.
build_triple arm64-apple-macosx \
    -Xswiftc -target -Xswiftc "arm64-apple-macosx${MACOS_DEPLOYMENT_TARGET}" \
    -Xcc -target -Xcc "arm64-apple-macosx${MACOS_DEPLOYMENT_TARGET}" &
PIDS+=($!)

# Xcode builds package dependencies for arm64e when a workspace sets iOSPackagesShouldBuildARM64e, which Xcode 27 also applies to macOS destinations. Without this slice those consumers fail with "Unable to resolve module dependency: 'ExhaustCore'".
build_triple arm64e-apple-macosx \
    -Xswiftc -target -Xswiftc "arm64e-apple-macosx${MACOS_DEPLOYMENT_TARGET}" \
    -Xcc -target -Xcc "arm64e-apple-macosx${MACOS_DEPLOYMENT_TARGET}" &
PIDS+=($!)

build_triple x86_64-apple-macosx \
    -Xswiftc -target -Xswiftc "x86_64-apple-macosx${MACOS_DEPLOYMENT_TARGET}" \
    -Xcc -target -Xcc "x86_64-apple-macosx${MACOS_DEPLOYMENT_TARGET}" &
PIDS+=($!)

# iOS
build_triple arm64-apple-ios \
    --sdk "${IOS_DEV_SDK}" \
    -Xswiftc -target -Xswiftc "arm64-apple-ios${IOS_DEPLOYMENT_TARGET}" &
PIDS+=($!)

build_triple arm64-apple-ios-simulator \
    --sdk "${IOS_SIM_SDK}" \
    -Xswiftc -target -Xswiftc "arm64-apple-ios${IOS_DEPLOYMENT_TARGET}-simulator" &
PIDS+=($!)

build_triple x86_64-apple-ios-simulator \
    --sdk "${IOS_SIM_SDK}" \
    -Xswiftc -target -Xswiftc "x86_64-apple-ios${IOS_DEPLOYMENT_TARGET}-simulator" &
PIDS+=($!)

# tvOS
build_triple arm64-apple-tvos \
    --sdk "${TVOS_DEV_SDK}" \
    -Xswiftc -target -Xswiftc "arm64-apple-tvos${TVOS_DEPLOYMENT_TARGET}" &
PIDS+=($!)

build_triple arm64-apple-tvos-simulator \
    --sdk "${TVOS_SIM_SDK}" \
    -Xswiftc -target -Xswiftc "arm64-apple-tvos${TVOS_DEPLOYMENT_TARGET}-simulator" &
PIDS+=($!)

build_triple x86_64-apple-tvos-simulator \
    --sdk "${TVOS_SIM_SDK}" \
    -Xswiftc -target -Xswiftc "x86_64-apple-tvos${TVOS_DEPLOYMENT_TARGET}-simulator" &
PIDS+=($!)

# watchOS
build_triple arm64-apple-watchos \
    --sdk "${WATCHOS_DEV_SDK}" \
    -Xswiftc -target -Xswiftc "arm64-apple-watchos${WATCHOS_ARM64_DEPLOYMENT_TARGET}" \
    -Xcc -target -Xcc "arm64-apple-watchos${WATCHOS_ARM64_DEPLOYMENT_TARGET}" &
PIDS+=($!)

build_triple arm64_32-apple-watchos \
    --sdk "${WATCHOS_DEV_SDK}" \
    -Xswiftc -target -Xswiftc "arm64_32-apple-watchos${WATCHOS_DEPLOYMENT_TARGET}" &
PIDS+=($!)

build_triple arm64-apple-watchos-simulator \
    --sdk "${WATCHOS_SIM_SDK}" \
    -Xswiftc -target -Xswiftc "arm64-apple-watchos${WATCHOS_DEPLOYMENT_TARGET}-simulator" &
PIDS+=($!)

build_triple x86_64-apple-watchos-simulator \
    --sdk "${WATCHOS_SIM_SDK}" \
    -Xswiftc -target -Xswiftc "x86_64-apple-watchos${WATCHOS_DEPLOYMENT_TARGET}-simulator" &
PIDS+=($!)

# visionOS (arm64 only — no x86_64 slices exist)
# Uses build_xros workaround; see comment above build_xros.
build_xros "arm64-apple-xros" \
    "${VISIONOS_DEV_SDK}" \
    "arm64-apple-xros${VISIONOS_DEPLOYMENT_TARGET}" \
    "${XROS_DEV_SCRATCH}" &
PIDS+=($!)

build_xros "arm64-apple-xros-simulator" \
    "${VISIONOS_SIM_SDK}" \
    "arm64-apple-xros${VISIONOS_DEPLOYMENT_TARGET}-simulator" \
    "${XROS_SIM_SCRATCH}" &
PIDS+=($!)

for pid in "${PIDS[@]}"; do wait "${pid}"; done

# ---------- Collect artefacts per-platform ----------
#
# With --target, SPM doesn't produce a .a; we create it from the .o files.
# Module artefacts:
#   Modules/ExhaustCore.swiftmodule  (compiled binary)
#   Modules/ExhaustCore.swiftdoc
#   ExhaustCore.build/ExhaustCore.swiftinterface
#   ExhaustCore.build/ExhaustCore.private.swiftinterface

# TODO: Support the Swift Build layout used by default in Swift 6.4 (Xcode 27):
# .build/out/Products/Release-<platform>/ instead of .build/<triple>/release/.
# Both collect() and collect_xros(), plus stale-object cleanup, need adapting.
# The builds above temporarily use --build-system native to retain the layout
# these collectors expect. Native is deprecated; this is a migration workaround.
collect() {
    local triple=$1 arch_qualifier=$2 dest=$3
    local build_products="${PACKAGE_DIR}/.build/${triple}/release"

    mkdir -p "${dest}/ExhaustCore.swiftmodule"

    # Create static library from object files.
    #
    # ExhaustCore depends on the ExhaustCoverageRuntime C target (the uninstrumented sancov hooks that
    # ComparisonRuntime.swift and TracePCGuardCoverageSource.swift call), whose objects land in a
    # sibling .build directory. They must be archived alongside ExhaustCore's own, or the shipped
    # library carries unresolved exhaust_cmp_* and exhaust_tpg_* symbols and every binary consumer
    # fails to link. This is ExhaustCore's only cross-target dependency; add another glob here if that
    # ever changes.
    if ! compgen -G "${build_products}/ExhaustCoverageRuntime.build/*.o" > /dev/null; then
        echo "error: no ExhaustCoverageRuntime objects at ${build_products}/ExhaustCoverageRuntime.build/ — libExhaustCore.a would ship with undefined exhaust_cmp_* and exhaust_tpg_* symbols." >&2
        exit 1
    fi
    ar rcs "${dest}/libExhaustCore.a" \
        "${build_products}/ExhaustCore.build/"*.o \
        "${build_products}/ExhaustCoverageRuntime.build/"*.o

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
    # .private.swiftinterface omitted — no @_spi declarations exist, and shipping
    # both .private and .package interfaces causes "Conflicting parseable interfaces"
    # warnings in consumers.
    if [ -f "${build_products}/ExhaustCore.build/ExhaustCore.package.swiftinterface" ]; then
        cp "${build_products}/ExhaustCore.build/ExhaustCore.package.swiftinterface" \
           "${dest}/ExhaustCore.swiftmodule/${arch_qualifier}.package.swiftinterface"
    fi
}

# Same as collect() but reads from a --scratch-path directory where products
# land under the host triple (arm64-apple-macosx) instead of the cross triple.
collect_xros() {
    local scratch_path=$1 arch_qualifier=$2 dest=$3
    local build_products="${scratch_path}/arm64-apple-macosx/release"

    mkdir -p "${dest}/ExhaustCore.swiftmodule"

    # See collect(): ExhaustCoverageRuntime's objects must ship alongside ExhaustCore's.
    if ! compgen -G "${build_products}/ExhaustCoverageRuntime.build/*.o" > /dev/null; then
        echo "error: no ExhaustCoverageRuntime objects at ${build_products}/ExhaustCoverageRuntime.build/ — libExhaustCore.a would ship with undefined exhaust_cmp_* and exhaust_tpg_* symbols." >&2
        exit 1
    fi
    ar rcs "${dest}/libExhaustCore.a" \
        "${build_products}/ExhaustCore.build/"*.o \
        "${build_products}/ExhaustCoverageRuntime.build/"*.o

    cp "${build_products}/Modules/ExhaustCore.swiftmodule" \
       "${dest}/ExhaustCore.swiftmodule/${arch_qualifier}.swiftmodule"

    if [ -f "${build_products}/Modules/ExhaustCore.swiftdoc" ]; then
        cp "${build_products}/Modules/ExhaustCore.swiftdoc" \
           "${dest}/ExhaustCore.swiftmodule/${arch_qualifier}.swiftdoc"
    fi

    if [ -f "${build_products}/Modules/ExhaustCore.abi.json" ]; then
        cp "${build_products}/Modules/ExhaustCore.abi.json" \
           "${dest}/ExhaustCore.swiftmodule/${arch_qualifier}.abi.json"
    fi

    if [ -f "${build_products}/ExhaustCore.build/ExhaustCore.swiftinterface" ]; then
        cp "${build_products}/ExhaustCore.build/ExhaustCore.swiftinterface" \
           "${dest}/ExhaustCore.swiftmodule/${arch_qualifier}.swiftinterface"
    fi
    if [ -f "${build_products}/ExhaustCore.build/ExhaustCore.package.swiftinterface" ]; then
        cp "${build_products}/ExhaustCore.build/ExhaustCore.package.swiftinterface" \
           "${dest}/ExhaustCore.swiftmodule/${arch_qualifier}.package.swiftinterface"
    fi
}

MACOS_ARM64_DIR="${BUILD_DIR}/macos-arm64"
MACOS_ARM64E_DIR="${BUILD_DIR}/macos-arm64e"
MACOS_X86_DIR="${BUILD_DIR}/macos-x86_64"
MACOS_FAT_DIR="${BUILD_DIR}/macos-fat"
IOS_DEV_DIR="${BUILD_DIR}/ios-arm64"
IOS_SIM_ARM64_DIR="${BUILD_DIR}/ios-simulator-arm64"
IOS_SIM_X86_DIR="${BUILD_DIR}/ios-simulator-x86_64"
IOS_SIM_FAT_DIR="${BUILD_DIR}/ios-simulator-fat"
TVOS_DEV_DIR="${BUILD_DIR}/tvos-arm64"
TVOS_SIM_ARM64_DIR="${BUILD_DIR}/tvos-simulator-arm64"
TVOS_SIM_X86_DIR="${BUILD_DIR}/tvos-simulator-x86_64"
TVOS_SIM_FAT_DIR="${BUILD_DIR}/tvos-simulator-fat"
WATCHOS_DEV_ARM64_DIR="${BUILD_DIR}/watchos-arm64"
WATCHOS_DEV_ARM64_32_DIR="${BUILD_DIR}/watchos-arm64_32"
WATCHOS_DEV_DIR="${BUILD_DIR}/watchos-device-fat"
WATCHOS_SIM_ARM64_DIR="${BUILD_DIR}/watchos-simulator-arm64"
WATCHOS_SIM_X86_DIR="${BUILD_DIR}/watchos-simulator-x86_64"
WATCHOS_SIM_FAT_DIR="${BUILD_DIR}/watchos-simulator-fat"
VISIONOS_DEV_DIR="${BUILD_DIR}/visionos-arm64"
VISIONOS_SIM_DIR="${BUILD_DIR}/visionos-simulator-arm64"

collect arm64-apple-macosx              "arm64-apple-macos"                 "${MACOS_ARM64_DIR}"
collect arm64e-apple-macosx             "arm64e-apple-macos"                "${MACOS_ARM64E_DIR}"
collect x86_64-apple-macosx             "x86_64-apple-macos"                "${MACOS_X86_DIR}"
collect arm64-apple-ios                 "arm64-apple-ios"                   "${IOS_DEV_DIR}"
collect arm64-apple-ios-simulator       "arm64-apple-ios-simulator"         "${IOS_SIM_ARM64_DIR}"
collect x86_64-apple-ios-simulator      "x86_64-apple-ios-simulator"        "${IOS_SIM_X86_DIR}"
collect arm64-apple-tvos                "arm64-apple-tvos"                  "${TVOS_DEV_DIR}"
collect arm64-apple-tvos-simulator      "arm64-apple-tvos-simulator"        "${TVOS_SIM_ARM64_DIR}"
collect x86_64-apple-tvos-simulator     "x86_64-apple-tvos-simulator"       "${TVOS_SIM_X86_DIR}"
collect arm64-apple-watchos             "arm64-apple-watchos"               "${WATCHOS_DEV_ARM64_DIR}"
collect arm64_32-apple-watchos          "arm64_32-apple-watchos"            "${WATCHOS_DEV_ARM64_32_DIR}"
collect arm64-apple-watchos-simulator   "arm64-apple-watchos-simulator"     "${WATCHOS_SIM_ARM64_DIR}"
collect x86_64-apple-watchos-simulator  "x86_64-apple-watchos-simulator"    "${WATCHOS_SIM_X86_DIR}"
collect_xros "${XROS_DEV_SCRATCH}" "arm64-apple-xros"           "${VISIONOS_DEV_DIR}"
collect_xros "${XROS_SIM_SCRATCH}" "arm64-apple-xros-simulator" "${VISIONOS_SIM_DIR}"

# ---------- Create fat libraries ----------

# Usage: create_fat <label> <fat_dir> <primary_dir> <other_dir>...
# The primary slice's module files are copied first; the others only add files the primary lacks.
create_fat() {
    local label=$1 fat_dir=$2 primary_dir=$3
    shift 2
    local slice_dirs=("$@")
    echo "==> Creating fat ${label} library"
    mkdir -p "${fat_dir}/ExhaustCore.swiftmodule"
    local libraries=()
    for dir in "${slice_dirs[@]}"; do
        libraries+=("${dir}/libExhaustCore.a")
    done
    lipo -create "${libraries[@]}" -output "${fat_dir}/libExhaustCore.a"
    cp "${primary_dir}/ExhaustCore.swiftmodule/"* "${fat_dir}/ExhaustCore.swiftmodule/"
    for dir in "${slice_dirs[@]:1}"; do
        for f in "${dir}/ExhaustCore.swiftmodule/"*; do
            cp -n "$f" "${fat_dir}/ExhaustCore.swiftmodule/" 2>/dev/null || true
        done
    done
}

create_fat "macOS"             "${MACOS_FAT_DIR}"       "${MACOS_ARM64_DIR}"       "${MACOS_ARM64E_DIR}" "${MACOS_X86_DIR}"
create_fat "iOS Simulator"     "${IOS_SIM_FAT_DIR}"     "${IOS_SIM_ARM64_DIR}"     "${IOS_SIM_X86_DIR}"
create_fat "tvOS Simulator"    "${TVOS_SIM_FAT_DIR}"    "${TVOS_SIM_ARM64_DIR}"    "${TVOS_SIM_X86_DIR}"
create_fat "watchOS"           "${WATCHOS_DEV_DIR}"     "${WATCHOS_DEV_ARM64_DIR}" "${WATCHOS_DEV_ARM64_32_DIR}"
create_fat "watchOS Simulator" "${WATCHOS_SIM_FAT_DIR}" "${WATCHOS_SIM_ARM64_DIR}" "${WATCHOS_SIM_X86_DIR}"

# ---------- Assemble xcframework ----------

echo "==> Assembling ExhaustCore.xcframework"
mkdir -p "${OUTPUT_DIR}"
rm -rf "${OUTPUT_DIR}/ExhaustCore.xcframework"

# Create bare xcframework with just the libraries
xcodebuild -create-xcframework \
    -library "${MACOS_FAT_DIR}/libExhaustCore.a" \
    -library "${IOS_DEV_DIR}/libExhaustCore.a" \
    -library "${IOS_SIM_FAT_DIR}/libExhaustCore.a" \
    -library "${TVOS_DEV_DIR}/libExhaustCore.a" \
    -library "${TVOS_SIM_FAT_DIR}/libExhaustCore.a" \
    -library "${WATCHOS_DEV_DIR}/libExhaustCore.a" \
    -library "${WATCHOS_SIM_FAT_DIR}/libExhaustCore.a" \
    -library "${VISIONOS_DEV_DIR}/libExhaustCore.a" \
    -library "${VISIONOS_SIM_DIR}/libExhaustCore.a" \
    -output "${OUTPUT_DIR}/ExhaustCore.xcframework"

# Inject Swift module directories into each slice.
# SPM resolves binary modules from <slice>/ExhaustCore.swiftmodule/
for slice_dir in "${OUTPUT_DIR}/ExhaustCore.xcframework/"*/; do
    [ -d "${slice_dir}" ] || continue
    local_name="$(basename "${slice_dir}")"
    case "${local_name}" in
        macos-arm64_arm64e_x86_64)
            cp -R "${MACOS_FAT_DIR}/ExhaustCore.swiftmodule" "${slice_dir}/"
            ;;
        ios-arm64)
            cp -R "${IOS_DEV_DIR}/ExhaustCore.swiftmodule" "${slice_dir}/"
            ;;
        ios-arm64_x86_64-simulator)
            cp -R "${IOS_SIM_FAT_DIR}/ExhaustCore.swiftmodule" "${slice_dir}/"
            ;;
        tvos-arm64)
            cp -R "${TVOS_DEV_DIR}/ExhaustCore.swiftmodule" "${slice_dir}/"
            ;;
        tvos-arm64_x86_64-simulator)
            cp -R "${TVOS_SIM_FAT_DIR}/ExhaustCore.swiftmodule" "${slice_dir}/"
            ;;
        watchos-arm64_arm64_32)
            cp -R "${WATCHOS_DEV_DIR}/ExhaustCore.swiftmodule" "${slice_dir}/"
            ;;
        watchos-arm64_x86_64-simulator)
            cp -R "${WATCHOS_SIM_FAT_DIR}/ExhaustCore.swiftmodule" "${slice_dir}/"
            ;;
        xros-arm64)
            cp -R "${VISIONOS_DEV_DIR}/ExhaustCore.swiftmodule" "${slice_dir}/"
            ;;
        xros-arm64-simulator)
            cp -R "${VISIONOS_SIM_DIR}/ExhaustCore.swiftmodule" "${slice_dir}/"
            ;;
    esac
done

echo "==> Done: ${OUTPUT_DIR}/ExhaustCore.xcframework"
echo ""
echo "Contents:"
find "${OUTPUT_DIR}/ExhaustCore.xcframework" -type f | sort | sed "s|${OUTPUT_DIR}/||"

# ---------- Zip & checksum for SPM distribution ----------

ZIP_PATH="${OUTPUT_DIR}/ExhaustCore.xcframework.zip"
echo ""
echo "==> Creating zip archive for SPM distribution"
rm -f "${ZIP_PATH}"
(cd "${OUTPUT_DIR}" && zip -r -q "ExhaustCore.xcframework.zip" "ExhaustCore.xcframework")

CHECKSUM=$(swift package compute-checksum "${ZIP_PATH}")
echo "==> Checksum: ${CHECKSUM}"
echo ""
echo "SPM binary target:"
echo "  .binaryTarget("
echo "      name: \"ExhaustCore\","
echo "      url: \"<RELEASE_URL>/ExhaustCore.xcframework.zip\","
echo "      checksum: \"${CHECKSUM}\""
echo "  )"
