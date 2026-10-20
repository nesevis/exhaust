#!/usr/bin/env python3

import sys, os, re

requested = sys.argv[1:]
summary_path = os.environ.get('GITHUB_STEP_SUMMARY', '')

if not summary_path:
    print("GITHUB_STEP_SUMMARY not set, skipping report")
    sys.exit(0)

found = [p for p in requested if os.path.exists(p)]
missing = [p for p in requested if not os.path.exists(p)]

if missing:
    print(f"Missing test output files: {missing}")
if not found:
    msg = f"No test output files found. Looked for: {requested}"
    print(msg)
    with open(summary_path, 'a') as f:
        f.write(f"### Test report unavailable\n\n{msg}\n")
    sys.exit(0)

failures = []
total = 0
summaries = 0
all_lines = []
for path in found:
    # Concurrent test output can split multi-byte characters, so the log is not guaranteed to be valid UTF-8.
    with open(path, encoding='utf-8', errors='replace') as f:
        lines = f.readlines()
    all_lines.extend(lines)
    for line in lines:
        m = re.search(r'Test "(.+?)" failed after .+ with (\d+) issue', line)
        if m:
            failures.append((m.group(1), int(m.group(2))))
    for line in reversed(lines):
        m = re.search(r'Test run with (\d+) tests? in (\d+) suites? (passed|failed)', line)
        if m:
            total += int(m.group(1))
            summaries += 1
            break

if not all_lines:
    msg = f"Test output file is empty: {', '.join(found)}"
    print(msg)
    with open(summary_path, 'a') as f:
        f.write(f"### Test report unavailable\n\n{msg}\n")
    sys.exit(0)

errors = [l.rstrip() for l in all_lines if re.search(r'\berror:', l)]

with open(summary_path, 'a') as f:
    if summaries == 0:
        f.write("### Test report unavailable\n\nCould not find test summary line in output.\n")
        if errors:
            f.write(f"\n**Build errors ({len(errors)}):**\n```\n")
            for line in errors:
                f.write(line + '\n')
            f.write("```\n")
        f.write(f"\nLast 20 lines of output:\n```\n")
        for line in all_lines[-20:]:
            f.write(line)
        f.write("```\n")
    elif not failures:
        f.write(f"### All {total} tests passed\n")
    else:
        f.write(f"### {len(failures)} of {total} tests failed\n\n")
        f.write("| Test | Issues |\n|------|--------|\n")
        for name, count in failures:
            f.write(f"| {name} | {count} |\n")
