"""Weekly gestun scoring.

Scores every company that transacted during the run's Thursday-to-Wednesday week.
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
import os

import pendulum
from airflow.sdk.exceptions import AirflowSkipException
from airflow.sdk import Param, dag, get_current_context, task

log = logging.getLogger(__name__)

GCP_CONN_ID = "google_cloud_default"
BQ_LOCATION = "asia-southeast1"
RESULT_TABLE = "paper-prod.datascience_public.fds_gestun_scores"
TXN_TABLE = "paper-prod.datascience_public.fds_gestun_scores_txn"

# Google Sheet the reviewers actually work in. BigQuery stays the system of
# record; the sheet is a convenience view plus somewhere to write verdicts.
# Set the Airflow Variable fds_gestun_sheet_id (or FDS_GESTUN_SHEET_ID) to the
# spreadsheet id and share the sheet with the Composer service account as Editor.
# Unset -> the task skips, so the pipeline runs before the sheet exists.
SHEET_TAB = "review_queue"

# Columns the DAG owns, in order. Everything to the right of these belongs to the
# reviewers: rows are only ever appended below, so their columns are never
# written to and never cleared.
SHEET_COLUMNS = [
    ("window_end", "Last transaction date of the scored week. Filter on this."),
    ("company_id", "Company."),
    ("gestun_pct", "Model score as a percentage. A ranking, not a likelihood."),
    ("decision", "GESTUN or clean, at the run's threshold."),
    ("risk_band", "very high / high / elevated / borderline / low."),
    ("rule_hits", "Rules that fired (R1|R2). Empty when the model alone queued it."),
    ("n_txn", "PAID transactions in the week."),
    ("tpv", "PAID rupiah in the week. Sort on this."),
    ("scored_date", "When the job ran."),
]
SHEET_REVIEWER_COLUMNS = ["verdict", "reviewer", "notes"]

# Explicit, not autodetect: autodetect infers types from whatever the first batch
# happens to contain, so an all-null column silently becomes the wrong type.
SCORE_SCHEMA = [
    ("company_id", "STRING", "Company scored."),
    ("gestun_probability", "FLOAT", "Model score 0-1. NOT calibrated to the "
     "population base rate -- treat as a ranking, not a likelihood."),
    ("gestun_pct", "FLOAT", "gestun_probability as a percentage."),
    ("decision", "STRING", "GESTUN or clean, at the threshold below."),
    ("risk_band", "STRING", "very high / high / elevated / borderline / low."),
    ("features_present", "INTEGER", "Non-null features out of features_total. "
     "A low count means a thin company and a less reliable score."),
    ("features_total", "INTEGER", "Features the model expects."),
    ("n_txn_in_window", "INTEGER", "PAID transactions in the scored window. "
     "Context, not a feature. The model over-flags low-volume companies -- "
     "observed flag rate runs 37% at 1-2 transactions a week against 15% at 20+ "
     "-- so read a high score on a thin company with that in mind."),
    ("tpv_in_window", "FLOAT", "PAID rupiah in the scored window. The review "
     "gate's floor, and the column to sort the queue by: value is concentrated, "
     "the top 300 companies by tpv carry 67% of the flagged rupiah."),
    ("scored_date", "DATE", "Date the scoring job ran."),
    ("window_start", "DATE", "First transaction date in the scored window."),
    ("window_end", "DATE", "Last transaction date, inclusive. Partition key."),
    ("threshold", "FLOAT", "Cutoff used for the decision column."),
    ("model_trained_on", "INTEGER", "Labelled companies the model was fit on."),
    ("model_positives", "INTEGER", "Gestun companies in that training set."),
    ("model_features", "INTEGER", "Feature count of the model."),
    ("rule_flag", "BOOLEAN", "A deterministic rule fired. Independent of the "
     "model score: three companies confirmed by review in September scored "
     "0.27-0.67 and would not have been queued on the model alone."),
    ("rule_hits", "STRING", "Which rules fired, pipe separated (R1|R3). Empty "
     "when none. Definitions live in fds_gestun/rules.py."),
    ("review", "BOOLEAN", "(gestun_probability >= 0.99 OR rule_flag) AND "
     "tpv_in_window >= 10000000. This is the review queue; work from this "
     "column, not from decision. Stricter than decision on purpose: decision "
     "is the model's opinion at its own threshold, review is a capacity "
     "decision. Sort what it returns by tpv_in_window."),
]

# Transaction detail for the companies that were scored. The model is
# company-grain, so company_gestun_probability is the COMPANY's score repeated on
# each of its rows -- it does not rank transactions against each other. The
# per-transaction columns are triage attributes, not predictions.
TXN_SCHEMA = [
    ("company_id", "STRING", "Company the transaction belongs to."),
    ("digital_payment_id", "STRING", "Transaction identifier."),
    ("order_id", "STRING", "Order identifier."),
    ("transaction_created_datetime", "DATETIME", "When the transaction was created."),
    ("transaction_date", "DATE", "Transaction date."),
    ("transaction_amount", "FLOAT", "Transaction amount."),
    ("partner_id", "STRING", "Payee identifier."),
    ("partner_name", "STRING", "Payee name as entered."),
    ("direction", "STRING", "In or Out. Gestun is an outbound pattern, so Out is the direction that matters."),
    ("payment_method_name", "STRING", "Payment method."),
    ("partner_is_ptcv", "INTEGER", "Payee name contains PT/CV/UD/Tbk etc. A "
     "registered payee leans CLEAN -- cleared companies pay them 3x more often."),
    ("partner_is_single_word", "INTEGER", "Payee is one word once legal forms are "
     "stripped. The strongest confirmed name signal: 31% of flagged companies' "
     "transactions against 10% of cleared."),
    ("partner_matches_company", "INTEGER", "Payee name equals the company, its "
     "owner, or its registered bank owner -- paying itself."),
    ("amount_is_round_1m", "INTEGER", "Amount is a whole million."),
    ("amount_is_round_100k", "INTEGER", "Amount is a whole hundred thousand."),
    ("hour_of_day", "INTEGER", "Hour the transaction was created."),
    ("is_offhours", "INTEGER", "Before 08:00 or from 20:00. Weak in practice -- "
     "near-identical between flagged and cleared companies."),
    ("amount_rank_in_company", "INTEGER", "1 = this company's largest transaction "
     "in the window. Open these first."),
    ("company_gestun_probability", "FLOAT", "The COMPANY's score, repeated on every "
     "row for that company. NOT a per-transaction prediction and NOT calibrated."),
    ("company_decision", "STRING", "GESTUN or clean, for the company."),
    ("company_risk_band", "STRING", "Risk band, for the company."),
    ("scored_date", "DATE", "Date the scoring job ran."),
    ("window_start", "DATE", "First transaction date in the scored window."),
    ("window_end", "DATE", "Last transaction date, inclusive. Partition key."),
]

# 0.98, not the 0.5 default and not the 0.7 this started on. The model is fit on
# 582 labelled companies of which 35.2% are gestun, and scale_pos_weight balances
# that to 50/50, so its probabilities carry the training prior rather than the
# population's. At 0.7 it called 33.2% of a week's companies gestun -- a number
# that reproduces the training prior instead of measuring anything. 0.99 puts the
# flag rate at 4.7%, next to the 5.0% the old pprrsk001 model flags on the same
# population, which is the only external reference point we have. The recall this
# costs is why the rule layer and the review queue exist. The number is tuned to
# this model's score distribution -- re-measure it after every retrain.
DEFAULT_THRESHOLD = 0.99


WINDOW_DAYS = 7

# A fully-loaded day spans all 24 hours. 22 leaves room for a genuinely quiet
# hour without accepting a half-loaded partition.
MIN_HOURS_FOR_COMPLETE_DAY = 22


def resolve_window(params: dict, data_interval_start, data_interval_end
                   ) -> tuple[str, str]:
    """The inclusive transaction-date window for a run: Thursday to Wednesday.

    The window ends the day BEFORE the run, because the source mart lands H-1 --
    Thursday's transactions are not in BigQuery when the Thursday job runs.
    A run on Thu 17 Sep scores 10 Sep (Thu) .. 16 Sep (Wed).

    Ending on the last complete day means no window contains partial data and
    consecutive windows leave no gap.

    Derived from the run day rather than the raw interval, so the window is the
    same 7 calendar days regardless of what time the cron fires.

    Explicit params win, so a one-off rescore of a named week needs no code change.
    """
    last_complete_day = data_interval_end.date().subtract(days=1)
    end = params.get("window_end") or last_complete_day.isoformat()
    start = (params.get("window_start")
             or last_complete_day.subtract(days=WINDOW_DAYS - 1).isoformat())
    if start > end:
        raise ValueError(f"window_start {start} is after window_end {end}")
    return start, end


@dag(
    dag_id="fds_gestun_scoring",
    description="Weekly gestun (credit-card cash-out) scoring",
    # Thursday 08:00 Jakarta.
    #
    # Measured from INFORMATION_SCHEMA.JOBS over 2026-09-03..16: the daily load
    # of rpt__raw_data_digital_payments_daily finishes around 05:15 WIB, and that
    # load is what completes the PREVIOUS day. Observed finish times ranged 04:25
    # to 06:38, so the spread matters more than the median -- 08:00 leaves ~1h20m
    # of headroom past the latest seen.
    #
    # Occasional extra runs appear later in the day (15:41 on the 16th, 16:52 on
    # the 14th). Those are ad-hoc, not the schedule; do not size against them.
    #
    # assert_source_is_fresh() enforces the property rather than trusting the
    # cadence: if the load slips past 08:00, the run fails loudly instead of
    # scoring a partial week.
    schedule="0 8 * * 4",
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
    def assert_source_is_fresh(params: dict, data_interval_start, data_interval_end) -> str:
        """Fail before doing any work if the mart has not caught up.

        The schedule assumes a daily rebuild lands the previous day in full. That
        assumption is worth one cheap query: a silently truncated window produces
        a plausible-looking queue built on a fraction of the week, which is far
        worse than a failed run.
        """
        from airflow.providers.google.cloud.hooks.bigquery import BigQueryHook
        from google.cloud import bigquery

        _, window_end = resolve_window(params, data_interval_start, data_interval_end)
        client = BigQueryHook(gcp_conn_id=GCP_CONN_ID, location=BQ_LOCATION,
                              use_legacy_sql=False).get_client()
        row = list(client.query(
            """
            SELECT MAX(TIME(transaction_created_datetime)) AS last_txn,
                   COUNT(DISTINCT EXTRACT(HOUR FROM transaction_created_datetime)) AS hours,
                   COUNT(*) AS n_txn
            FROM `paper-prod.data_mart_layer.rpt__raw_data_digital_payments_daily`
            WHERE DATE(transaction_created_datetime) = @we
            """,
            job_config=bigquery.QueryJobConfig(query_parameters=[
                bigquery.ScalarQueryParameter("we", "DATE", window_end)]),
        ).result())[0]

        log.info("%s in the mart: %s transactions, %s hours covered, last at %s",
                 window_end, row.n_txn, row.hours, row.last_txn)
        # A complete day spans essentially all 24 hours. Anything less means the
        # rebuild has not run yet, or ran early.
        if row.n_txn == 0 or row.hours < MIN_HOURS_FOR_COMPLETE_DAY:
            raise ValueError(
                f"{window_end} is incomplete in the mart: {row.n_txn} transactions "
                f"across {row.hours} hours (last at {row.last_txn}). The daily "
                f"rebuild has not landed it yet. Retry after it does, or move the "
                f"schedule later.")
        return window_end

    @task
    def select_candidates(params: dict, data_interval_start, data_interval_end) -> list[str]:
        """Distinct companies that transacted during the window, excluding
        anything already labelled.

        Unlabelled only: scoring a company the model trained on returns a fitted
        value, not a prediction.

        The window is the Thursday-to-Wednesday week ending the day before the
        run: a run on Thu 17 Sep scores companies that transacted 10-16 Sep.
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
          SELECT company_id, COUNT(*) AS n_txn,
                 SUM(transaction_amount) AS tpv
          FROM `paper-prod.data_mart_layer.rpt__raw_data_digital_payments_daily`
          WHERE payment_status_name = 'PAID'
            AND DATE(transaction_created_datetime)
                BETWEEN @window_start AND @window_end
          GROUP BY company_id
          HAVING n_txn >= @min_transactions
        )
        SELECT a.company_id, a.n_txn, a.tpv
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
        # carried to publish() so the score can be read next to the volume it
        # was computed from
        ti = get_current_context()["ti"]
        ti.xcom_push(key="n_txn", value=dict(zip(frame.company_id.astype(str),
                                                 frame.n_txn.astype(int))))
        # the review queue gates on rupiah, so the window's value travels with
        # the count rather than being re-derived from a feature column that is
        # anchored on the company's last transaction instead of the window
        ti.xcom_push(key="tpv", value=dict(zip(frame.company_id.astype(str),
                                               frame.tpv.astype(float))))
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
    def score(features_path: str, params: dict, ds: str,
              data_interval_start, data_interval_end) -> str:
        import pandas as pd
        from pathlib import Path
        from fds_gestun import GestunModel
        from fds_gestun import rules as rules_mod
        from fds_gestun.model import review_queue
        from fds_gestun import config

        model = GestunModel.load()
        frame = pd.read_csv(features_path)
        result = model.score(frame, threshold=params["threshold"])

        # Second opinion on the same feature matrix. The rules never change a
        # model score; they add companies the model scored clean.
        result = result.merge(rules_mod.apply_rules(frame), on="company_id",
                              how="left")
        result["rule_flag"] = result["rule_flag"].fillna(False).astype(bool)
        result["rule_hits"] = result["rule_hits"].fillna("")

        # Provenance: a score is not interpretable without the window it covers,
        # the threshold that produced the decision, and the model behind it.
        window_start, window_end = resolve_window(
            params, data_interval_start, data_interval_end)
        result["scored_date"] = pd.to_datetime(ds).date()
        result["window_start"] = pd.to_datetime(window_start).date()
        result["window_end"] = pd.to_datetime(window_end).date()
        result["threshold"] = float(params["threshold"])
        result["model_trained_on"] = model.trained_on
        result["model_positives"] = model.positives
        result["model_features"] = len(model.feature_names)
        ti = get_current_context()["ti"]
        n_txn = ti.xcom_pull(task_ids="select_candidates", key="n_txn") or {}
        tpv = ti.xcom_pull(task_ids="select_candidates", key="tpv") or {}
        result["n_txn_in_window"] = result.company_id.map(n_txn).astype("Int64")
        result["tpv_in_window"] = result.company_id.map(tpv).astype(float)

        # The queue gate. Stricter than `decision` on purpose -- decision is the
        # model's opinion, this is what a reviewer's hour is spent on.
        result["review"] = review_queue(
            result.gestun_probability, result.rule_flag, result.tpv_in_window)

        path = Path(features_path).with_name("scores.csv")
        result.to_csv(path, index=False)
        flagged = int((result.decision == "GESTUN").sum())
        rule_only = int((result.rule_flag & (result.decision != "GESTUN")).sum())
        log.info("scored %d companies, %d flagged at %.2f, %d added by rules; "
                 "%d in the review queue (p>=%.2f or rule, tpv>=%.0f)",
                 len(result), flagged, params["threshold"], rule_only,
                 int(result.review.sum()), config.REVIEW_THRESHOLD,
                 config.REVIEW_MIN_TPV)
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

        frame = pd.read_csv(scores_path, parse_dates=["scored_date", "window_start",
                                                      "window_end"])
        for col in ("scored_date", "window_start", "window_end"):
            frame[col] = frame[col].dt.date
        client = BigQueryHook(gcp_conn_id=GCP_CONN_ID, location=BQ_LOCATION).get_client()

        # Replace this window's rows rather than appending, so a re-run does not
        # duplicate. Partitioned on window_end, so this prunes to one partition.
        client.query(
            f"DELETE FROM `{RESULT_TABLE}` WHERE window_end = @we",
            job_config=bigquery.QueryJobConfig(query_parameters=[
                bigquery.ScalarQueryParameter(
                    "we", "DATE", frame.window_end.iloc[0].isoformat())]),
        ).result()

        # A load job, not streaming inserts: a batch of a few thousand rows loads
        # atomically, costs nothing, and is immediately queryable (streamed rows
        # sit in a buffer that DELETE cannot touch for up to 90 minutes).
        job = client.load_table_from_dataframe(
            frame, RESULT_TABLE,
            job_config=bigquery.LoadJobConfig(
                schema=[bigquery.SchemaField(n, t, description=d)
                        for n, t, d in SCORE_SCHEMA],
                write_disposition=bigquery.WriteDisposition.WRITE_APPEND,
            ),
        )
        job.result()
        summary = {
            "scored": len(frame),
            "flagged": int((frame.decision == "GESTUN").sum()),
            "very_high": int((frame.risk_band == "very high").sum()),
            "rule_only": int((frame.rule_flag & (frame.decision != "GESTUN")).sum()),
            "review_queue": int(frame.review.sum()),
            "review_tpv": float(frame.loc[frame.review, "tpv_in_window"].sum()),
        }
        log.info("published to %s: %s", RESULT_TABLE, summary)
        return summary

    @task
    def publish_transactions(scores_path: str, ds: str, params: dict,
                             data_interval_start, data_interval_end) -> dict:
        """Second output: one row per transaction for the scored companies.

        Reviewers work companies, but they open transactions. This gives them the
        amount, the payee and the triage flags so they start with the right ones.
        Independent of publish(), so a failure here does not lose the company
        scores.
        """
        import pandas as pd
        from airflow.providers.google.cloud.hooks.bigquery import BigQueryHook
        from google.cloud import bigquery
        from fds_gestun import build_transaction_detail

        scores = pd.read_csv(scores_path)
        scores = scores[scores.risk_band != "known label"]
        window_start, window_end = resolve_window(
            params, data_interval_start, data_interval_end)

        txn = build_transaction_detail(scores.company_id.tolist(),
                                       window_start, window_end)
        txn = txn.merge(
            scores[["company_id", "gestun_probability", "decision", "risk_band"]]
            .rename(columns={"gestun_probability": "company_gestun_probability",
                             "decision": "company_decision",
                             "risk_band": "company_risk_band"}),
            on="company_id", how="left")
        txn["scored_date"] = pd.to_datetime(ds).date()
        txn["window_start"] = pd.to_datetime(window_start).date()
        txn["window_end"] = pd.to_datetime(window_end).date()
        txn = txn[[n for n, _, _ in TXN_SCHEMA]]

        client = BigQueryHook(gcp_conn_id=GCP_CONN_ID, location=BQ_LOCATION).get_client()
        client.query(
            f"DELETE FROM `{TXN_TABLE}` WHERE window_end = @we",
            job_config=bigquery.QueryJobConfig(query_parameters=[
                bigquery.ScalarQueryParameter("we", "DATE", window_end)]),
        ).result()
        client.load_table_from_dataframe(
            txn, TXN_TABLE,
            job_config=bigquery.LoadJobConfig(
                schema=[bigquery.SchemaField(n, t, description=d)
                        for n, t, d in TXN_SCHEMA],
                write_disposition=bigquery.WriteDisposition.WRITE_APPEND),
        ).result()

        summary = {"transactions": len(txn),
                   "for_flagged_companies":
                       int((txn.company_decision == "GESTUN").sum())}
        log.info("published to %s: %s", TXN_TABLE, summary)
        return summary

    @task
    def ensure_model() -> dict:
        """Make sure the worker has a model to score with, before any BigQuery runs.

        artifacts/ is gitignored, so the deploy syncs code but not the model file.
        On a fresh Composer worker GestunModel.load() would raise -- after
        build_features has already paid for a full scan of the mart. Training is
        ~75s, needs no BigQuery, and is deterministic given the committed training
        set and config.SEED, so rebuilding here is cheaper than shipping a binary
        and safer than assuming one is present.

        Rebuilds when the artefact is missing or was fit on a different number of
        companies than the committed training set has. It does NOT rebuild on a
        feature-list change; that is deliberate, because a retrain moves the score
        distribution and the decision threshold is tuned to it (see
        config.DECISION_THRESHOLD). Change the features, then re-measure the flag
        rate and bump the threshold by hand.
        """
        import pandas as pd
        from fds_gestun import config, model as model_mod

        expected = len(pd.read_csv(config.TRAINING_SET_PATH, usecols=["company_id"]))
        try:
            existing = model_mod.GestunModel.load()
            if existing.trained_on == expected:
                log.info("model present, fit on %d companies: reusing it",
                         existing.trained_on)
                return {"action": "reused", "trained_on": existing.trained_on,
                        "features": len(existing.feature_names)}
            log.warning("model was fit on %d companies but the training set has "
                        "%d; retraining", existing.trained_on, expected)
        except Exception as exc:           # missing file, unreadable, schema drift
            log.warning("no usable model artefact (%s); training one", exc)

        config.MODEL_DIR.mkdir(parents=True, exist_ok=True)
        fresh_model = model_mod.train()
        fresh_model.save()
        log.info("trained on %d companies, %d features -> %s",
                 fresh_model.trained_on, len(fresh_model.feature_names),
                 config.MODEL_PATH)
        return {"action": "trained", "trained_on": fresh_model.trained_on,
                "features": len(fresh_model.feature_names)}

    @task
    def publish_to_sheet(scores_path: str) -> dict:
        """Append this week's review queue to the reviewers' Google Sheet.

        Append-only, and it never writes outside columns A..I. Reviewers keep
        verdicts in the columns to the right, on rows this task has already
        written; clearing or rewriting the tab would destroy that work, so the
        task does neither. The cost is that the tab grows -- about 360 rows a
        week, ~19k a year, which Sheets handles without complaint.

        Idempotent by window_end: a retry finds its own window already present
        and stops rather than writing the week twice. That is also why it cannot
        correct a week it has already published -- rescore into BigQuery, then
        fix the sheet by hand, because the alternative is a task that deletes
        rows reviewers may have annotated.

        Skips (does not fail) when no sheet is configured: the pipeline is useful
        before anyone has made the spreadsheet.
        """
        import pandas as pd
        from airflow.models import Variable
        from airflow.providers.google.suite.hooks.sheets import GSheetsHook

        sheet_id = Variable.get("fds_gestun_sheet_id",
                                default_var=os.getenv("FDS_GESTUN_SHEET_ID"))
        if not sheet_id:
            raise AirflowSkipException(
                "no fds_gestun_sheet_id Variable and no FDS_GESTUN_SHEET_ID: "
                "nothing to write to. Scores are in " + RESULT_TABLE)

        frame = pd.read_csv(scores_path)
        queue = (frame[frame.review]
                 .sort_values("tpv_in_window", ascending=False)
                 .reset_index(drop=True))
        window_end = str(frame.window_end.iloc[0])
        if queue.empty:
            log.info("review queue is empty for %s; nothing to append", window_end)
            return {"appended": 0, "window_end": window_end}

        hook = GSheetsHook(gcp_conn_id=GCP_CONN_ID)
        header = [c for c, _ in SHEET_COLUMNS] + SHEET_REVIEWER_COLUMNS

        if SHEET_TAB not in (hook.get_sheet_titles(spreadsheet_id=sheet_id) or []):
            hook.get_conn().spreadsheets().batchUpdate(
                spreadsheetId=sheet_id,
                body={"requests": [{"addSheet": {"properties": {"title": SHEET_TAB}}}]},
            ).execute(num_retries=hook.num_retries)
            log.info("created tab %s", SHEET_TAB)

        # Column A is window_end precisely so this check is one narrow read.
        col_a = [r[0] for r in
                 (hook.get_values(spreadsheet_id=sheet_id,
                                  range_=f"{SHEET_TAB}!A:A") or []) if r]
        if not col_a:
            hook.update_values(spreadsheet_id=sheet_id,
                               range_=f"{SHEET_TAB}!A1",
                               values=[header])
            col_a = [header[0]]
            log.info("wrote the header row")
        if window_end in col_a:
            log.info("window %s is already in the sheet (%d rows); leaving it alone",
                     window_end, col_a.count(window_end))
            return {"appended": 0, "window_end": window_end, "already_present": True}

        rows = [[window_end, r.company_id, round(float(r.gestun_pct), 1),
                 r.decision, r.risk_band, r.rule_hits if pd.notna(r.rule_hits) else "",
                 int(r.n_txn_in_window) if pd.notna(r.n_txn_in_window) else None,
                 float(r.tpv_in_window) if pd.notna(r.tpv_in_window) else None,
                 str(r.scored_date)]
                for r in queue.itertuples()]
        hook.update_values(spreadsheet_id=sheet_id,
                           range_=f"{SHEET_TAB}!A{len(col_a) + 1}",
                           values=rows)
        summary = {"appended": len(rows), "window_end": window_end,
                   "first_row": len(col_a) + 1,
                   "tpv": float(queue.tpv_in_window.sum())}
        log.info("appended to sheet %s: %s", sheet_id, summary)
        return summary

    fresh = assert_source_is_fresh()
    model_ready = ensure_model()
    candidates = select_candidates()
    fresh >> candidates          # no work until the source is known complete
    features = build_features(candidates)
    scores = score(features)
    # Fail on a missing model before the scan, not after it.
    model_ready >> features
    published = publish(scores)      # company grain
    publish_transactions(scores)     # transaction grain
    # The sheet is downstream of the table on purpose: BigQuery is the record,
    # and a Sheets API hiccup must not be able to lose a week of scores.
    published >> publish_to_sheet(scores)


fds_gestun_scoring()
