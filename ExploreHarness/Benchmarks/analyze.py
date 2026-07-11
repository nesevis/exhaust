#!/usr/bin/env python3
"""Paired A/B analyzer for ExploreBenchmark JSONL output.

Usage:
    python3 Benchmarks/analyze.py baseline.jsonl candidate.jsonl \
        [--metrics attemptsPerSecond,coveredEdges,clusterCount,reducedTotal] \
        [--discovery "label=channel: 3;flags: 35"] ...

Records are paired by (fixture, seed); every comparison is per-seed first, aggregates second.
For each metric the script prints the per-seed table, medians and IQRs for both arms, the
median delta, and a two-sided paired sign-test verdict. Ties are dropped from the sign test.

--discovery defines an attempts-to-discovery metric: the minimum firstSeenAttempt over
clusters whose canonicalDescription contains every semicolon-separated marker. A run that
never found a matching cluster is censored: it counts as strictly worse than any run that
did, and censored-in-both pairs are dropped.
"""

import argparse
import json
import math
import sys
from statistics import median

DEFAULT_METRICS = ["attemptsPerSecond", "coveredEdges", "clusterCount", "reducedTotal"]


def load(path):
    records = {}
    with open(path) as handle:
        for line in handle:
            line = line.strip()
            if not line:
                continue
            record = json.loads(line)
            key = (record["fixture"], record["seed"])
            if key in records:
                print(f"warning: duplicate record for {key} in {path}; keeping the last one", file=sys.stderr)
            records[key] = record
    return records


def metric_value(record, metric, discovery_markers):
    if metric in record:
        return record[metric]
    if metric == "clusterCount":
        return len(record["clusters"])
    if metric == "reducedTotal":
        return sum(c["reduced"] for c in record["clusters"])
    if metric in discovery_markers:
        markers = discovery_markers[metric]
        attempts = [
            c["firstSeenAttempt"]
            for c in record["clusters"]
            if all(marker in c["canonicalDescription"] for marker in markers)
        ]
        return min(attempts) if attempts else None
    raise KeyError(f"unknown metric {metric}")


def sign_test(deltas):
    positive = sum(1 for d in deltas if d > 0)
    negative = sum(1 for d in deltas if d < 0)
    n = positive + negative
    if n == 0:
        return positive, negative, 1.0
    k = min(positive, negative)
    tail = sum(math.comb(n, i) for i in range(k + 1)) / 2**n
    return positive, negative, min(1.0, 2 * tail)


def iqr(values):
    ordered = sorted(values)
    def quantile(fraction):
        position = (len(ordered) - 1) * fraction
        low = int(math.floor(position))
        high = int(math.ceil(position))
        return ordered[low] + (ordered[high] - ordered[low]) * (position - low)
    return quantile(0.25), quantile(0.75)


def fmt(value):
    if value is None:
        return "notfound"
    if isinstance(value, float):
        return f"{value:.1f}"
    return str(value)


def analyze_metric(metric, pairs, discovery_markers):
    print(f"\n=== {metric} ===")
    print(f"{'fixture':8} {'seed':>5} {'baseline':>12} {'candidate':>12} {'delta':>12}")
    deltas = []
    baseline_values = []
    candidate_values = []
    for (fixture, seed), (base, cand) in sorted(pairs.items()):
        base_value = metric_value(base, metric, discovery_markers)
        cand_value = metric_value(cand, metric, discovery_markers)
        if base_value is None and cand_value is None:
            print(f"{fixture:8} {seed:>5} {'notfound':>12} {'notfound':>12} {'dropped':>12}")
            continue
        if base_value is None:
            deltas.append(-1)  # candidate found what the baseline never did: an improvement
            print(f"{fixture:8} {seed:>5} {'notfound':>12} {fmt(cand_value):>12} {'improved':>12}")
            continue
        if cand_value is None:
            deltas.append(1)
            print(f"{fixture:8} {seed:>5} {fmt(base_value):>12} {'notfound':>12} {'regressed':>12}")
            continue
        delta = cand_value - base_value
        deltas.append(delta)
        baseline_values.append(base_value)
        candidate_values.append(cand_value)
        print(f"{fixture:8} {seed:>5} {fmt(base_value):>12} {fmt(cand_value):>12} {fmt(delta):>12}")

    if not deltas:
        print("no comparable pairs")
        return
    if baseline_values:
        base_low, base_high = iqr(baseline_values)
        cand_low, cand_high = iqr(candidate_values)
        print(f"baseline : median {fmt(median(baseline_values))}  IQR [{fmt(base_low)}, {fmt(base_high)}]")
        print(f"candidate: median {fmt(median(candidate_values))}  IQR [{fmt(cand_low)}, {fmt(cand_high)}]")
        numeric_deltas = [c - b for b, c in zip(baseline_values, candidate_values)]
        print(f"delta    : median {fmt(median(numeric_deltas))}")
    positive, negative, p_value = sign_test(deltas)
    verdict = "significant at 0.05" if p_value < 0.05 else "not significant"
    print(f"sign test: {positive} up, {negative} down, {len(deltas) - positive - negative} ties dropped; p = {p_value:.4f} ({verdict})")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("baseline")
    parser.add_argument("candidate")
    parser.add_argument("--metrics", default=",".join(DEFAULT_METRICS))
    parser.add_argument(
        "--discovery",
        action="append",
        default=[],
        help='label=marker[;marker...] — attempts-to-discovery of the cluster matching all markers',
    )
    arguments = parser.parse_args()

    discovery_markers = {}
    metrics = [m for m in arguments.metrics.split(",") if m]
    for spec in arguments.discovery:
        label, _, markers = spec.partition("=")
        if not markers:
            parser.error(f"--discovery '{spec}' must be label=marker[;marker...]")
        discovery_markers[label] = markers.split(";")
        metrics.append(label)

    baseline = load(arguments.baseline)
    candidate = load(arguments.candidate)
    shared = sorted(set(baseline) & set(candidate))
    missing = sorted(set(baseline) ^ set(candidate))
    if missing:
        print(f"warning: {len(missing)} unpaired records skipped: {missing[:6]}{'...' if len(missing) > 6 else ''}", file=sys.stderr)
    if not shared:
        sys.exit("no paired (fixture, seed) records between the two files")
    pairs = {key: (baseline[key], candidate[key]) for key in shared}
    print(f"{len(pairs)} paired runs: {arguments.baseline} vs {arguments.candidate}")
    for metric in metrics:
        analyze_metric(metric, pairs, discovery_markers)


if __name__ == "__main__":
    main()
