#!/usr/bin/env python3

import argparse
from pathlib import Path
import re
import sys


REPOSITORY_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_MANIFEST = REPOSITORY_ROOT / "Package.swift"
MACRO_REPOSITORY = "https://github.com/nesevis/exhaust-macros.git"
EXHAUST_REPOSITORY = "https://github.com/nesevis/exhaust"


def replace_once(contents: str, old: str, new: str, description: str) -> str:
    count = contents.count(old)
    if count != 1:
        raise ValueError(
            f"Expected exactly one {description} marker, found {count}."
        )
    return contents.replace(old, new, 1)


def validate_version(version: str) -> None:
    if re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?", version):
        return
    raise ValueError(f"Invalid release version: {version!r}")


def use_remote_macro(contents: str, version: str) -> str:
    validate_version(version)
    local_dependency = '.package(path: "Packages/exhaust-macros"),'
    remote_dependency = (
        f'.package(url: "{MACRO_REPOSITORY}", exact: "{version}"),'
    )
    return replace_once(
        contents,
        local_dependency,
        remote_dependency,
        "local macro dependency",
    )


def use_release_binary(contents: str, tag: str, checksum: str) -> str:
    if not tag.startswith("v"):
        raise ValueError(f"Release tag must start with 'v': {tag!r}")
    validate_version(tag[1:])
    if re.fullmatch(r"[0-9a-f]{64}", checksum) is None:
        raise ValueError("The XCFramework checksum must be 64 lowercase hex characters.")

    development_switch = (
        'let usePrecompiled = '
        'ProcessInfo.processInfo.environment["EXHAUST_RELEASE"] != nil'
    )
    release_switch = (
        "let usePrecompiled = isDarwinHost && "
        'ProcessInfo.processInfo.environment["EXHAUST_FORCE_SOURCE"] == nil'
    )
    contents = replace_once(
        contents,
        development_switch,
        release_switch,
        "development binary switch",
    )

    local_binary = (
        '.binaryTarget(name: "ExhaustCore", '
        'path: "Frameworks/ExhaustCore.xcframework")'
    )
    release_url = (
        f"{EXHAUST_REPOSITORY}/releases/download/{tag}/"
        "ExhaustCore.xcframework.zip"
    )
    release_binary = (
        '.binaryTarget(name: "ExhaustCore", '
        f'url: "{release_url}", checksum: "{checksum}")'
    )
    return replace_once(
        contents,
        local_binary,
        release_binary,
        "local XCFramework target",
    )


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Prepare Exhaust's generated release manifest."
    )
    parser.add_argument("--manifest", type=Path, default=DEFAULT_MANIFEST)
    subparsers = parser.add_subparsers(dest="operation", required=True)

    macro_parser = subparsers.add_parser("macro")
    macro_parser.add_argument("--version", required=True)

    binary_parser = subparsers.add_parser("binary")
    binary_parser.add_argument("--tag", required=True)
    binary_parser.add_argument("--checksum", required=True)
    return parser.parse_args()


def main() -> int:
    arguments = parse_arguments()
    manifest = arguments.manifest.resolve()
    contents = manifest.read_text()

    try:
        if arguments.operation == "macro":
            contents = use_remote_macro(contents, arguments.version)
        else:
            contents = use_release_binary(contents, arguments.tag, arguments.checksum)
    except ValueError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1

    manifest.write_text(contents)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
