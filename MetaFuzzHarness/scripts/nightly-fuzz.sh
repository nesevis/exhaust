#!/bin/bash
# Trap-resilient wrapper for the nightly self-fuzz lane. Relaunches MetaFuzzProbe until it
# exits cleanly or the relaunch cap is hit: a Swift trap in ExhaustCore kills only the probe,
# and the next launch resumes from the progress log (EXHAUST_STATE_DIR), reports the trap as
# a finding, quarantines the crash region, and spends the remaining budget elsewhere.
#
# Exit codes: 0 = clean run, no findings; 1 = findings, traps, or relaunch cap exhausted.
# Expects the probe binary path as $1; remaining arguments are forwarded to the probe on every
# launch (budget, seed, findings directory — see MetaFuzzProbe --help). EXHAUST_* framework
# seams stay environment-driven.
set -u

PROBE="${1:?usage: nightly-fuzz.sh <path-to-MetaFuzzProbe> [probe flags...]}"
shift
RELAUNCH_CAP="${METAFUZZ_MAX_RELAUNCHES:-5}"
TRAPS=0
FINDINGS=0

for attempt in $(seq 1 "$RELAUNCH_CAP"); do
  echo "metafuzz: probe launch ${attempt}/${RELAUNCH_CAP}"
  "$PROBE" "$@"
  status=$?
  case $status in
    0)
      break
      ;;
    2)
      # Oracle violations: the probe already printed the clusters and wrote freeze candidates.
      FINDINGS=1
      break
      ;;
    *)
      # Signal death: a trap inside ExhaustCore. Resume machinery picks up on relaunch.
      TRAPS=$((TRAPS + 1))
      echo "metafuzz: probe died with status ${status} (trap); relaunching to resume and quarantine"
      ;;
  esac
done

if [ "$TRAPS" -gt 0 ]; then
  echo "metafuzz: ${TRAPS} trap(s) during the run — the progress log and breadcrumb in \$EXHAUST_STATE_DIR identify the inputs"
fi

if [ "$FINDINGS" -eq 1 ] || [ "$TRAPS" -gt 0 ]; then
  exit 1
fi
if [ "$status" -ne 0 ]; then
  echo "metafuzz: relaunch cap exhausted without a clean exit"
  exit 1
fi
exit 0
