#!/usr/bin/env bash
# Scheduled batch scoring. Exits non-zero on any failure so the scheduler alerts.
set -Eeuo pipefail

RUN_DATE="$(date -u +%Y-%m-%d)"
WORK_DIR="${FDS_WORK_DIR:-/tmp/fds-gestun}"
INPUT="${1:?usage: score_batch.sh <companies.csv> [output_dir]}"
OUT_DIR="${2:-${WORK_DIR}/${RUN_DATE}}"

mkdir -p "${OUT_DIR}"
trap 'echo "FAILED at line ${LINENO}" >&2' ERR

echo "[$(date -u +%H:%M:%S)] scoring ${INPUT}"
fds-gestun score \
  --companies "${INPUT}" \
  --save-features "${OUT_DIR}/features.csv" \
  --out "${OUT_DIR}/scores.csv"

echo "[$(date -u +%H:%M:%S)] done -> ${OUT_DIR}/scores.csv"
wc -l < "${OUT_DIR}/scores.csv"
