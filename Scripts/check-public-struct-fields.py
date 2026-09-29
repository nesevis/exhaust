#!/usr/bin/env python3
# Fails when a public struct in the Exhaust module stores a value whose type mentions an ExhaustCore `package` type.
#
# Consumers compile against ExhaustCore's public `.swiftinterface`, where `package` types have no layout and no exported metadata. A public struct that stores one inline, or as an `Array` element or `Dictionary` key or value, copies correctly inside the package and crashes in consumers once the field holds data. Wrap such fields in a `package final class` (see `ExhaustReportDiagnostics`) or convert them to public types before storing them.
#
# The check is textual: it reads stored property declarations at the top level of each public struct body. Computed properties (declarations ending in `{`) are skipped because they have no storage.

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
CORE_SOURCES = ROOT / "Sources" / "ExhaustCore"
EXHAUST_SOURCES = ROOT / "Sources" / "Exhaust"

# Top-level declarations only: a nested package type is spelled through its enclosing type, which this also catches, and nested names such as `Kind` or `Outcome` recur across both modules.
PACKAGE_DECLARATION = re.compile(
    r"^(?:@[\w.]+(?:\([^)]*\))?\s+)*package\s+(?:final\s+|indirect\s+)*(?:struct|enum|class|actor|typealias|protocol)\s+(\w+)"
)
ANY_DECLARATION = re.compile(r"^\s*(?:@[\w.]+(?:\([^)]*\))?\s+)*(?:\w+\s+)*(?:struct|enum|class|actor|typealias|protocol)\s+(\w+)")
PUBLIC_STRUCT = re.compile(r"^\s*(?:@[\w.]+(?:\([^)]*\))?\s+)*public\s+(?:final\s+)?struct\s+(\w+)")
STORED_PROPERTY = re.compile(
    r"^\s*(?:@[\w.]+(?:\([^)]*\))?\s+)*(?:(?:public|package|internal|private|fileprivate)(?:\(set\))?\s+)*(?:nonisolated(?:\(unsafe\))?\s+)?(?:var|let)\s+(\w+)\s*(?::\s*([^={]+?))?\s*(?:=\s*(.*))?$"
)
IDENTIFIER = re.compile(r"[A-Za-z_]\w*")


def strip_comment(line):
    index = line.find("//")
    return line if index == -1 else line[:index]


def package_type_names():
    names = set()
    for path in CORE_SOURCES.rglob("*.swift"):
        for line in path.read_text().splitlines():
            match = PACKAGE_DECLARATION.match(line)
            if match:
                names.add(match.group(1))
    # A name the Exhaust module declares itself resolves to that declaration inside Exhaust sources.
    for path in EXHAUST_SOURCES.rglob("*.swift"):
        for line in path.read_text().splitlines():
            match = ANY_DECLARATION.match(line)
            if match:
                names.discard(match.group(1))
    return names


def stored_property_violations(path, package_names):
    violations = []
    lines = path.read_text().splitlines()
    depth = 0
    struct_name = None
    struct_depth = None
    for number, raw in enumerate(lines, start=1):
        line = strip_comment(raw).rstrip()
        if struct_name is None:
            match = PUBLIC_STRUCT.match(line)
            if match:
                struct_name = match.group(1)
                struct_depth = depth + 1
        elif depth == struct_depth and line.endswith("{") is False:
            match = STORED_PROPERTY.match(line)
            if match:
                property_name, annotation, initializer = match.groups()
                type_text = annotation or ""
                if annotation is None and initializer:
                    # Unannotated: the initializer's leading identifier is the inferred type, as in `= Foo()`.
                    leading = IDENTIFIER.match(initializer.strip())
                    type_text = leading.group(0) if leading else ""
                offending = sorted(set(IDENTIFIER.findall(type_text)) & package_names)
                if offending:
                    violations.append(
                        f"{path.relative_to(ROOT)}:{number}: {struct_name}.{property_name} stores ExhaustCore package type(s) {', '.join(offending)}"
                    )
        depth += line.count("{") - line.count("}")
        if struct_name is not None and depth < struct_depth:
            struct_name = None
            struct_depth = None
    return violations


def main():
    package_names = package_type_names()
    violations = []
    for path in sorted(EXHAUST_SOURCES.rglob("*.swift")):
        violations.extend(stored_property_violations(path, package_names))
    if violations:
        for violation in violations:
            print(f"::error::{violation}")
        return 1
    print("Public struct fields: OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
