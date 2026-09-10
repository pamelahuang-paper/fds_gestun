"""Weekly gestun scoring.

Selects companies with recent activity, builds the feature matrix from BigQuery,
scores them and lands the result in BigQuery for the review queue.

The heavy work happens inside BigQuery; the worker only does the XGBoost forward
pass, so this is light on Airflow resources. Feature building is the slow step
(~10 min per 1k companies) and is retried independently of scoring.

Written for Airflow 3.x (airflow.sdk). Requires `fds-gestun` installed on the
workers:  pip install git+ssh://git@github.com/paper-id/fds-gestun.git@main

Pipeline role : the weekly schedule. Calls the package; holds no feature logic.
Deploy        : REQUIRED, but it goes to the Airflow DAG folder, NOT into the
                installed package.
Change when   : the cadence, the candidate query, or the queue thresholds move.
"""
from __future__ import annotations

import logging
import pendulum
from airflow.sdk import Param, dag, task

log = logging.getLogger(__name__)

GCP_CONN_ID = "google_cloud_default"
BQ_LOCATION = "asia-southeast1"
RESULT_TABLE = "paper-prod.datascience_public.fds_gestun_scores"

# 0.7, not the 0.5 default. Out-of-fold that is precision 0.932 against 0.866 --
# this output is a human review queue, so precision is the binding constraint.
DEFAULT_THRESHOLD = 0.7


@dag(
    dag_id="fds_gestun_scoring",
    description="Weekly gestun (credit-card cash-out) scoring",
    schedule="0 3 * * 1",                       # Mondays 03:00
    start_date=pendulum.datetime(2026, 9, 1, tz="Asia/Jakarta"),
    catchup=False,
    max_active_runs=1,
    default_args={
        "owner": "data-science",
        "retries": 2,
        "retry_delay": pendulum.duration(minutes=10),
        "email_on_failure": True,
    },
    tags=["fds", "gestun", "ml"],
    params={
        "lookback_days": Param(30, type="integer",
                               description="Activity window for candidate selection"),
        "min_transactions": Param(10, type="integer",
                                  description="Skip companies below this; the model "
                                              "over-flags thin accounts"),
        "threshold": Param(DEFAULT_THRESHOLD, type="number",
                           description="Decision cutoff"),
        "max_companies": Param(5000, type="integer",
                               description="Safety cap on batch size"),
    },
)
def fds_gestun_scoring():

    @task
    def select_candidates(params: dict) -> list[str]:
        """Active, non-trivial companies that carry no label yet.

        Unlabelled only: scoring a company the model trained on returns a fitted
        value, not a prediction.
        """
        from airflow.providers.google.cloud.hooks.bigquery import BigQueryHook

        sql = """
        WITH labelled AS (
          SELECT DISTINCT company_id
          FROM `paper-prod.datascience_public.fds_gestung_actual_label_130826`
        ),
        active AS (
          SELECT company_id, COUNT(*) AS n_txn
          FROM `paper-prod.data_mart_layer.rpt__raw_data_digital_payments_daily`
          WHERE payment_status_name = 'PAID'
            AND DATE(transaction_created_datetime)
                >= DATE_SUB(CURRENT_DATE(), INTERVAL @lookback_days DAY)
          GROUP BY company_id
          HAVING n_txn >= @min_transactions
        )
        SELECT a.company_id
        FROM active a
        LEFT JOIN labelled l USING (company_id)
        WHERE l.company_id IS NULL
        ORDER BY a.n_txn DESC
        LIMIT @max_companies
        """
        # Go through the underlying client rather than get_pandas_df: named query
        # parameters are passed through reliably here, and this is the same code
        # path the package itself uses.
        from google.cloud import bigquery

        client = BigQueryHook(gcp_conn_id=GCP_CONN_ID, location=BQ_LOCATION,
                              use_legacy_sql=False).get_client()
        job_config = bigquery.QueryJobConfig(query_parameters=[
            bigquery.ScalarQueryParameter("lookback_days", "INT64",
                                          int(params["lookback_days"])),
            bigquery.ScalarQueryParameter("min_transactions", "INT64",
                                          int(params["min_transactions"])),
            bigquery.ScalarQueryParameter("max_companies", "INT64",
                                          int(params["max_companies"])),
        ])
        frame = client.query(sql, job_config=job_config).result().to_dataframe()
        ids = frame["company_id"].astype(str).tolist()
        if not ids:
            raise ValueError("no candidate companies -- check the source table")
        log.info("selected %d candidates", len(ids))
        return ids

    @task(execution_timeout=pendulum.duration(hours=2))
    def build_features(company_ids: list[str], ds: str) -> str:
        """Slow step: one BigQuery job per feature source. Cached to disk so a
        scoring failure does not force a rebuild."""
        from pathlib import Path
        from fds_gestun import build_features as build

        frame = build(company_ids)
        path = Path(f"/tmp/fds_gestun/{ds}/features.csv")
        path.parent.mkdir(parents=True, exist_ok=True)
        frame.to_csv(path, index=False)
        log.info("features %s -> %s", frame.shape, path)
        return str(path)

    @task
    def score(features_path: str, params: dict, ds: str) -> str:
        import pandas as pd
        from pathlib import Path
        from fds_gestun import GestunModel

        model = GestunModel.load()
        frame = pd.read_csv(features_path)
        result = model.score(frame, threshold=params["threshold"])
        result["scored_date"] = ds
        result["model_trained_on"] = model.trained_on

        path = Path(features_path).with_name("scores.csv")
        result.to_csv(path, index=False)
        flagged = int((result.decision == "GESTUN").sum())
        log.info("scored %d companies, %d flagged at %.2f",
                 len(result), flagged, params["threshold"])
        # A flag rate this high means the batch does not resemble the training
        # population -- surface it rather than quietly filling the review queue.
        if flagged / max(len(result), 1) > 0.5:
            log.warning("flag rate %.1f%% is implausibly high; check the candidate "
                        "query before working this queue", 100 * flagged / len(result))
        return str(path)

    @task
    def publish(scores_path: str) -> dict:
        import pandas as pd
        from airflow.providers.google.cloud.hooks.bigquery import BigQueryHook

        from google.cloud import bigquery

        frame = pd.read_csv(scores_path)
        client = BigQueryHook(gcp_conn_id=GCP_CONN_ID, location=BQ_LOCATION).get_client()
        # A load job, not streaming inserts: this is a batch of a few thousand rows
        # and a load job is atomic, cheaper, and immediately queryable.
        job = client.load_table_from_dataframe(
            frame, RESULT_TABLE,
            job_config=bigquery.LoadJobConfig(
                write_disposition=bigquery.WriteDisposition.WRITE_APPEND,
                schema_update_options=[
                    bigquery.SchemaUpdateOption.ALLOW_FIELD_ADDITION],
            ),
        )
        job.result()
        summary = {
            "scored": len(frame),
            "flagged": int((frame.decision == "GESTUN").sum()),
            "very_high": int((frame.risk_band == "very high").sum()),
        }
        log.info("published to %s: %s", RESULT_TABLE, summary)
        return summary

    candidates = select_candidates()
    features = build_features(candidates)
    scores = score(features)
    publish(scores)


fds_gestun_scoring()
