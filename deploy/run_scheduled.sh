#!/usr/bin/env bash
# Container entry point for the scheduled run: pull the candidate list from
# BigQuery, score it, write results back. Non-zero exit makes Cloud Run retry
# and surfaces in Cloud Monitoring.
set -Eeuo pipefail

RUN_DATE="$(date -u +%Y%m%d)"
WORK=/tmp/run
mkdir -p "${WORK}"

: "${FDS_GCP_PROJECT:?}"
: "${FDS_OUTPUT_BUCKET:?}"

echo "[$(date -u +%FT%TZ)] selecting candidates"
# Companies active in the last 30 days that carry no label yet.
bq --project_id="${FDS_GCP_PROJECT}" --location=asia-southeast1 \
   --format=csv query --nouse_legacy_sql --max_rows=100000 '
SELECT DISTINCT r.company_id
FROM `paper-prod.data_mart_layer.rpt__raw_data_digital_payments_daily` r
WHERE r.payment_status_name = "PAID"
  AND DATE(r.transaction_created_datetime) >= DATE_SUB(CURRENT_DATE(), INTERVAL 30 DAY)
' > "${WORK}/companies.csv"

echo "[$(date -u +%FT%TZ)] $(( $(wc -l < "${WORK}/companies.csv") - 1 )) candidates"

fds-gestun score \
  --companies "${WORK}/companies.csv" \
  --save-features "${WORK}/features.csv" \
  --out "${WORK}/scores.csv"

echo "[$(date -u +%FT%TZ)] uploading"
gsutil -q cp "${WORK}/scores.csv"   "${FDS_OUTPUT_BUCKET}/scores/${RUN_DATE}/scores.csv"
gsutil -q cp "${WORK}/features.csv" "${FDS_OUTPUT_BUCKET}/features/${RUN_DATE}/features.csv"

bq --project_id="${FDS_GCP_PROJECT}" --location=asia-southeast1 \
   load --replace --source_format=CSV --skip_leading_rows=1 --autodetect \
   "datascience_public.fds_gestun_scores_${RUN_DATE}" "${WORK}/scores.csv"

echo "[$(date -u +%FT%TZ)] done"
