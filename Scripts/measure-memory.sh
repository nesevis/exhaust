#!/bin/bash

# Measures one already-built command. The command's combined output, raw time(1)
# data, and shell-readable metrics are written beside the supplied prefix.
set -uo pipefail

if [ "$#" -lt 3 ] || [ "$2" != "--" ]; then
  echo "usage: measure-memory.sh <output-prefix> -- <command> [arguments...]" >&2
  exit 64
fi

OUTPUT_PREFIX="$1"
shift 2

OUTPUT_DIRECTORY="$(dirname "$OUTPUT_PREFIX")"
LOG_PATH="${OUTPUT_PREFIX}.log"
TIME_PATH="${OUTPUT_PREFIX}.time.txt"
METRICS_PATH="${OUTPUT_PREFIX}.metrics.env"
PLATFORM="$(uname -s)"

mkdir -p "$OUTPUT_DIRECTORY"

case "$PLATFORM" in
  Darwin)
    /usr/bin/time -lp -o "$TIME_PATH" "$@" 2>&1 | tee "$LOG_PATH"
    COMMAND_STATUS=${PIPESTATUS[0]}
    MAX_RSS_BYTES="$(awk '/maximum resident set size/ { print $1 }' "$TIME_PATH")"
    PEAK_FOOTPRINT_BYTES="$(awk '/peak memory footprint/ { print $1 }' "$TIME_PATH")"
    ;;
  Linux)
    /usr/bin/time -v -o "$TIME_PATH" "$@" 2>&1 | tee "$LOG_PATH"
    COMMAND_STATUS=${PIPESTATUS[0]}
    MAX_RSS_KIB="$(awk -F: '/Maximum resident set size/ { gsub(/^[ \t]+/, "", $2); print $2 }' "$TIME_PATH")"
    if ! [[ "$MAX_RSS_KIB" =~ ^[0-9]+$ ]]; then
      echo "could not parse maximum resident set size from $TIME_PATH" >&2
      exit 66
    fi
    MAX_RSS_BYTES=$((MAX_RSS_KIB * 1024))
    PEAK_FOOTPRINT_BYTES="$MAX_RSS_BYTES"
    ;;
  *)
    echo "unsupported platform for memory measurement: $PLATFORM" >&2
    exit 65
    ;;
esac

if ! [[ "$MAX_RSS_BYTES" =~ ^[0-9]+$ ]] || ! [[ "$PEAK_FOOTPRINT_BYTES" =~ ^[0-9]+$ ]]; then
  echo "could not parse memory metrics from $TIME_PATH" >&2
  exit 66
fi

MAX_RSS_MIB="$(awk -v bytes="$MAX_RSS_BYTES" 'BEGIN { printf "%.1f", bytes / 1048576 }')"
PEAK_FOOTPRINT_MIB="$(awk -v bytes="$PEAK_FOOTPRINT_BYTES" 'BEGIN { printf "%.1f", bytes / 1048576 }')"

{
  printf 'platform=%s\n' "$PLATFORM"
  printf 'command_status=%s\n' "$COMMAND_STATUS"
  printf 'max_rss_bytes=%s\n' "$MAX_RSS_BYTES"
  printf 'max_rss_mib=%s\n' "$MAX_RSS_MIB"
  printf 'peak_footprint_bytes=%s\n' "$PEAK_FOOTPRINT_BYTES"
  printf 'peak_footprint_mib=%s\n' "$PEAK_FOOTPRINT_MIB"
} > "$METRICS_PATH"

echo "memory: maximum resident set size ${MAX_RSS_MIB} MiB"
echo "memory: peak footprint ${PEAK_FOOTPRINT_MIB} MiB"

exit "$COMMAND_STATUS"
