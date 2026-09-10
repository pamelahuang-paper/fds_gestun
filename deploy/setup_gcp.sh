#!/usr/bin/env bash
# One-off: create the Cloud Run job and the schedule that triggers it.
# Run once by hand, then GitHub Actions only updates the image.
set -Eeuo pipefail

PROJECT="${GCP_PROJECT:?set GCP_PROJECT}"
REGION="${REGION:-asia-southeast2}"
JOB="${JOB:-fds-gestun-score}"
BUCKET="${BUCKET:?set BUCKET, e.g. gs://paper-fds-gestun}"
RUNTIME_SA="${RUNTIME_SA:?set RUNTIME_SA, e.g. fds-gestun@${PROJECT}.iam.gserviceaccount.com}"
IMAGE="${REGION}-docker.pkg.dev/${PROJECT}/fds/fds-gestun:latest"

gcloud config set project "${PROJECT}"

echo "==> APIs"
gcloud services enable run.googleapis.com cloudscheduler.googleapis.com \
  artifactregistry.googleapis.com bigquery.googleapis.com

echo "==> Artifact Registry"
gcloud artifacts repositories describe fds --location="${REGION}" >/dev/null 2>&1 || \
  gcloud artifacts repositories create fds --repository-format=docker --location="${REGION}"

echo "==> Runtime service account needs BigQuery read + GCS write"
for role in roles/bigquery.jobUser roles/bigquery.dataViewer roles/storage.objectAdmin; do
  gcloud projects add-iam-policy-binding "${PROJECT}" \
    --member="serviceAccount:${RUNTIME_SA}" --role="${role}" --condition=None --quiet
done

echo "==> Cloud Run job"
# 2 vCPU / 4Gi is enough: the heavy work happens inside BigQuery, not here.
# task-timeout must exceed the feature build (~10 min for ~1k companies).
gcloud run jobs describe "${JOB}" --region="${REGION}" >/dev/null 2>&1 && VERB=update || VERB=create
gcloud run jobs "${VERB}" "${JOB}" \
  --image="${IMAGE}" \
  --region="${REGION}" \
  --service-account="${RUNTIME_SA}" \
  --cpu=2 --memory=4Gi \
  --task-timeout=3600s \
  --max-retries=1 \
  --set-env-vars="FDS_GCP_PROJECT=${PROJECT},FDS_BQ_LOCATION=asia-southeast1,FDS_THRESHOLD=0.7,FDS_OUTPUT_BUCKET=${BUCKET}" \
  --command="/app/deploy/run_scheduled.sh"

echo "==> Schedule: 03:00 Jakarta, Mondays"
gcloud scheduler jobs describe "${JOB}-weekly" --location="${REGION}" >/dev/null 2>&1 \
  && SVERB=update || SVERB=create
gcloud scheduler jobs "${SVERB}" http "${JOB}-weekly" \
  --location="${REGION}" \
  --schedule="0 3 * * 1" \
  --time-zone="Asia/Jakarta" \
  --uri="https://${REGION}-run.googleapis.com/apis/run.googleapis.com/v1/namespaces/${PROJECT}/jobs/${JOB}:run" \
  --http-method=POST \
  --oauth-service-account-email="${RUNTIME_SA}"

echo "done. Trigger a run now with:"
echo "  gcloud run jobs execute ${JOB} --region=${REGION}"
