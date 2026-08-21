#!/usr/bin/env python3
"""Tree-edit-distance analysis for the Etna shrinking benchmark.

Consumes etna-shrinking-results.jsonl (written by the ExhaustBenchmarks Etna
runner) and reports, per task and per workload, the Zhang-Shasha tree edit
distance from Exhaust's reported counterexample to the paper's ground-truth
minimum (Keles, Miao, and Lampropoulos, "Evaluating Shrinking (Experience
Report)", 2026). Uses the same zss package as the paper.

Metrics mirror the paper's Figures 6-8:
  - TED(post, ground truth): shrinking effectiveness (their Fig. 6)
  - TED(pre, ground truth):  where the original counterexample started
  - reduction ms and ms per edit of TED(pre, post): cost (their Figs. 7-8)

Tree encoding replicates the paper's artifact exactly (scripts/
workload_analysis.py in github.com/alpaylan/shrinking-evaluation): every
parenthesized group becomes a node labeled "*" whose children are its parsed
contents, so constructor names are leaf children rather than node labels;
atoms are leaves labeled with their token text; commas act as whitespace, so
tuple inputs are just the outer parenthesized group. One normalization bridges
the formats: the paper prints empty BSTs as (E) while the Swift port prints
bare E, so Swift-side terms get bare E tokens wrapped to (E) before parsing.

Usage: python3 Scripts/etna_shrinking_ted.py <etna-shrinking-results.jsonl> <path to a clone of github.com/alpaylan/shrinking-evaluation>
"""

import json
import statistics
import sys
from pathlib import Path

try:
    import zss
except ImportError:
    sys.exit("The zss package is required: pip install zss")


class Node:
    __slots__ = ("label", "children")

    def __init__(self, label, children=None):
        self.label = label
        self.children = children or []

    @staticmethod
    def get_children(node):
        return node.children

    @staticmethod
    def get_label(node):
        return node.label


def tokenize(text):
    """Verbatim port of the artifact's tokenize(): parens are tokens, commas and whitespace are delimiters."""
    tokens, current = [], ""
    for character in text:
        if character in "()":
            if current:
                tokens.append(current)
                current = ""
            tokens.append(character)
        elif character in ", \t\n":
            if current:
                tokens.append(current)
                current = ""
        else:
            current += character
    if current:
        tokens.append(current)
    return tokens


def parse_tree(tokens, position=0):
    """Verbatim port of the artifact's parse_tree(): every parenthesized group is a "*" node."""
    if position >= len(tokens):
        return None, position
    if tokens[position] == "(":
        node = Node("*")
        cursor = position + 1
        while cursor < len(tokens) and tokens[cursor] != ")":
            child, cursor = parse_tree(tokens, cursor)
            if child is not None:
                node.children.append(child)
        return node, cursor + 1
    if tokens[position] == ")":
        return None, position
    return Node(tokens[position]), position + 1


def wrap_bare_empties(tokens):
    """Wraps bare E tokens (Swift's empty-BST printing) as (E) to match the paper's format. An E already alone inside parens is left as is."""
    wrapped = []
    for index, token in enumerate(tokens):
        already_wrapped = (
            index > 0
            and tokens[index - 1] == "("
            and index + 1 < len(tokens)
            and tokens[index + 1] == ")"
        )
        if token == "E" and already_wrapped == False:
            wrapped.extend(["(", "E", ")"])
        else:
            wrapped.append(token)
    return wrapped


def parse(text, swift=False):
    tokens = tokenize(text)
    if swift:
        tokens = wrap_bare_empties(tokens)
    if tokens[0] != "(":
        # Artifact behavior: flat inputs get a synthetic ROOT node.
        return Node("ROOT", [Node(token) for token in tokens])
    node, _ = parse_tree(tokens)
    return node


def ted(a, b):
    return zss.simple_distance(a, b, Node.get_children, Node.get_label)


def median(values):
    return statistics.median(values) if values else None


STORE_NAMES = {"BST": "bst", "RBT": "rbt", "STLC": "stlc"}


def load_ground_truth(workload, artifact_root):
    """Loads the exhaustive-search minima from the paper's artifact clone, keyed by (mutant, property).

    LeanRev is preferred over Lean where both enumerations solved a task: on the
    four STLC tasks where the two reach different symmetric minima, LeanRev's is
    the variant the paper's Table 3 prints.
    """
    store = artifact_root / f"store.{STORE_NAMES[workload]}.det.jsonl"
    if not store.exists():
        sys.exit(f"{store} not found; pass the path to a clone of github.com/alpaylan/shrinking-evaluation")
    truths = {}
    for line in store.read_text().splitlines():
        record = json.loads(line)["data"]
        if record.get("strategy") not in ("Lean", "LeanRev") or record.get("status") != "Failed":
            continue
        counterexample = record.get("counterexample") or record.get("pre_counterexample") or ""
        key = (record["mutations"][0], record["property"])
        if record["strategy"] == "LeanRev" or key not in truths:
            truths[key] = counterexample
    return truths


def fmt(value, width=8):
    if value is None:
        return " " * (width - 1) + "-"
    return f"{value:{width}.1f}"


def main():
    if len(sys.argv) != 3:
        sys.exit("usage: etna_shrinking_ted.py <etna-shrinking-results.jsonl> <shrinking-evaluation-clone>")
    path = Path(sys.argv[1])
    artifact_root = Path(sys.argv[2])
    if not path.exists():
        sys.exit(f"{path} not found; run the Etna benchmarks first")

    records = [json.loads(line) for line in path.read_text().splitlines() if line.strip()]

    # The Benchmark harness runs each workload closure several times and the
    # log accumulates across iterations; identical (task, seed) rows are exact
    # duplicates, so keep the first.
    seen = set()
    deduped = []
    for record in records:
        key = (record["workload"], record["task"], record["seed"])
        if key in seen:
            continue
        seen.add(key)
        deduped.append(record)
    records = deduped

    by_task = {}
    for record in records:
        by_task.setdefault((record["workload"], record["task"]), []).append(record)

    ground_truth = {workload: load_ground_truth(workload, artifact_root) for workload in STORE_NAMES}

    workload_rows = {}
    print(f"{'task':<42} {'n':>3} {'preTED':>8} {'postTED':>8} {'redMs':>8} {'ms/edit':>8} {'fail%':>8}")
    for (workload, task), rows in by_task.items():
        mutant, prop = task.split(" × ")
        truth_text = ground_truth[workload].get((mutant, prop))
        solved = [r for r in rows if r["solved"] and r["postCounterexample"]]
        if truth_text is None:
            print(f"{workload}/{task:<38} {len(solved):>3} (no ground truth; skipped)")
            continue
        truth = parse(truth_text)

        pre_teds, post_teds, red_ms, ms_per_edit, fail_rates = [], [], [], [], []
        for row in solved:
            post = parse(row["postCounterexample"], swift=True)
            post_teds.append(ted(post, truth))
            red_ms.append(row["reductionMs"])
            if row["preCounterexample"]:
                pre = parse(row["preCounterexample"], swift=True)
                pre_teds.append(ted(pre, truth))
                shrink_progress = ted(pre, post)
                if shrink_progress > 0:
                    ms_per_edit.append(row["reductionMs"] / shrink_progress)
            # Sample efficiency in the paper's sense: of the shrink candidates
            # that actually executed the property, what fraction still failed?
            executed = row.get("reductionProbesFailed", 0) + row.get("reductionProbesPassed", 0)
            if executed > 0:
                fail_rates.append(100.0 * row["reductionProbesFailed"] / executed)

        label = f"{workload}/{task}"
        print(
            f"{label:<42} {len(solved):>3} {fmt(median(pre_teds))} {fmt(median(post_teds))}"
            f" {fmt(median(red_ms))} {fmt(median(ms_per_edit))} {fmt(median(fail_rates))}"
        )
        if post_teds:
            workload_rows.setdefault(workload, []).append(
                (median(pre_teds), median(post_teds), median(red_ms), median(ms_per_edit), median(fail_rates))
            )

    print()
    print("Per-workload medians of per-task medians (compare with the paper's Fig. 6-8 CBC campaigns):")
    print(f"{'workload':<10} {'tasks':>5} {'preTED':>8} {'postTED':>8} {'redMs':>8} {'ms/edit':>8} {'fail%':>8}")
    for workload, task_rows in workload_rows.items():
        pre = median([r[0] for r in task_rows if r[0] is not None])
        post = median([r[1] for r in task_rows if r[1] is not None])
        red = median([r[2] for r in task_rows if r[2] is not None])
        per_edit = median([r[3] for r in task_rows if r[3] is not None])
        fail = median([r[4] for r in task_rows if r[4] is not None])
        print(f"{workload:<10} {len(task_rows):>5} {fmt(pre)} {fmt(post)} {fmt(red)} {fmt(per_edit)} {fmt(fail)}")

    print()
    print("CCP buckets of per-task median postTED (their Fig. 6 x axis):")
    for workload, task_rows in workload_rows.items():
        posts = sorted(r[1] for r in task_rows if r[1] is not None)
        buckets = {"=0": 0, "1-3": 0, "4-9": 0, "10+": 0}
        for value in posts:
            if value == 0:
                buckets["=0"] += 1
            elif value <= 3:
                buckets["1-3"] += 1
            elif value <= 9:
                buckets["4-9"] += 1
            else:
                buckets["10+"] += 1
        summary = "  ".join(f"{k}: {v}" for k, v in buckets.items())
        print(f"{workload:<10} {summary}")


if __name__ == "__main__":
    main()
