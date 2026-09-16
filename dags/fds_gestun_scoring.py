"""Weekly gestun scoring.

Scores every company that transacted during the run's Friday-to-Thursday week.
The window is derived from the run day, not CURRENT_DATE(), so a re-run or a
backfill scores the week it was meant to -- re-running August in October still
scores August.

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
from airflow.exceptions import AirflowSkipException
from airflow.sdk import Param, dag, task

log = logging.getLogger(__name__)

GCP_CONN_ID = "google_cloud_default"
BQ_LOCATION = "asia-southeast1"
RESULT_TABLE = "paper-prod.datascience_public.fds_gestun_scores"

# 0.7, not the 0.5 default. Out-of-fold that is precision 0.932 against 0.866 --
# this output is a human review queue, so precision is the binding constraint.
DEFAULT_THRESHOLD = 0.7


WINDOW_DAYS = 7


def resolve_window(params: dict, data_interval_start, data_interval_end
                   ) -> tuple[str, str]:
    """The inclusive transaction-date window for a run: Friday to Thursday.

    The window ENDS on the run day rather than the day before, because the point
    of a Thursday run is to cover the week through Thursday. A run on Thu 17 Sep
    scores 11 Sep (Fri) .. 17 Sep (Thu).

    Derived from the run day rather than the raw interval, so the window is the
    same 7 calendar days regardless of what time the cron fires.

    Explicit params win, so a one-off rescore of a named week needs no code change.
    """
    run_day = data_interval_end.date()
    end = params.get("window_end") or run_day.isoformat()
    start = (params.get("window_start")
             or run_day.subtract(days=WINDOW_DAYS - 1).isoformat())
    if start > end:
        raise ValueError(f"window_start {start} is after window_end {end}")
    return start, end


@dag(
    dag_id="fds_gestun_scoring",
    description="Weekly gestun (credit-card cash-out) scoring",
    # Thursday 20:00 Jakarta. Each run scores the Friday-to-Thursday week ending
    # that same day, so the result is on the reviewers' desk Thursday evening.
    #
    # The trade-off: Thursday is not over when the job runs. Transactions after
    # 20:00 on the run day fall between windows and are never scored. That is
    # roughly 4 hours a week. To close the gap instead, move to "0 3 * * 5"
    # (Friday 03:00) -- same Friday-to-Thursday window, complete data, result
    # available Friday morning rather than Thursday evening.
    schedule="0 20 * * 4",
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
        # Leave both null to use the run's own week. Set them to score a
        # specific window by hand, e.g. {"window_start": "2026-08-04",
        # "window_end": "2026-08-10"}.
        "window_start": Param(None, type=["null", "string"], format="date",
                              description="First transaction date, inclusive. "
                                          "Defaults to the run's data interval."),
        "window_end": Param(None, type=["null", "string"], format="date",
                            description="Last transaction date, inclusive."),
        "min_rescore_days": Param(0, type="integer",
                                  description="Skip a company scored more recently "
                                              "than this. 0 = score every active "
                                              "company each week, which is the "
                                              "point of a weekly assessment. Raise "
                                              "it if reviewers see repeats."),
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
    def select_candidates(params: dict, data_interval_start, data_interval_end) -> list[str]:
        """Distinct companies that transacted during the window, excluding
        anything already labelled.

        Unlabelled only: scoring a company the model trained on returns a fitted
        value, not a prediction.

        The window is the Friday-to-Thursday week ending on the run day: a run
        on Thu 17 Sep scores companies that transacted 11-17 Sep inclusive.
        """
        from airflow.providers.google.cloud.hooks.bigquery import BigQueryHook

        window_start, window_end = resolve_window(
            params, data_interval_start, data_interval_end)
        log.info("scoring companies that transacted %s .. %s (inclusive)",
                 window_start, window_end)

        sql = """
        WITH labelled AS (
          SELECT DISTINCT company_id
          FROM `paper-prod.datascience_public.fds_gestung_actual_label_130826`
        ),
        -- already in the queue recently: re-scoring adds a duplicate, not a signal
        recently_scored AS (
          SELECT company_id, MAX(DATE(scored_date)) AS last_scored
          FROM `paper-prod.datascience_public.fds_gestun_scores`
          GROUP BY company_id
        ),
        active AS (
          SELECT company_id, COUNT(*) AS n_txn
          FROM `paper-prod.data_mart_layer.rpt__raw_data_digital_payments_daily`
          WHERE payment_status_name = 'PAID'
            AND DATE(transaction_created_datetime)
                BETWEEN @window_start AND @window_end
          GROUP BY company_id
          HAVING n_txn >= @min_transactions
        )
        SELECT a.company_id
        FROM active a
        LEFT JOIN labelled l USING (company_id)
        LEFT JOIN recently_scored r USING (company_id)
        WHERE l.company_id IS NULL
          AND (@min_rescore_days = 0
               OR r.last_scored IS NULL
               OR r.last_scored < DATE_SUB(@window_end,
                                           INTERVAL @min_rescore_days DAY))
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
            bigquery.ScalarQueryParameter("window_start", "DATE", window_start),
            bigquery.ScalarQueryParameter("window_end", "DATE", window_end),
            bigquery.ScalarQueryParameter("min_transactions", "INT64",
                                          int(params["min_transactions"])),
            bigquery.ScalarQueryParameter("min_rescore_days", "INT64",
                                          int(params["min_rescore_days"])),
            bigquery.ScalarQueryParameter("max_companies", "INT64",
                                          int(params["max_companies"])),
        ])
        frame = client.query(sql, job_config=job_config).result().to_dataframe()
        ids = frame["company_id"].astype(str).tolist()
        if not ids:
            # Normal on a quiet day once the backlog is scored: skip the rest of
            # the run rather than failing and paging someone.
            raise AirflowSkipException(
                f"no candidates transacted between {window_start} and {window_end}")
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
