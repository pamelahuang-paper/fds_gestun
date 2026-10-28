# Deploy checklist

Seven steps, in order. Each one says what to do, why, and how to know it worked.
Nothing here needs `gcloud`, `gh` or `bq` installed locally — the browser console
is enough, and the one BigQuery change can be run from Python.

Stop at any step that fails. Later steps assume the earlier ones are done.

---

## 0. Where things stand

| | |
|---|---|
| Code | complete, 65 tests passing |
| Model | 182 features, trained on 582 labelled companies |
| Threshold | 0.99 → flags ~4.7% of a week's companies |
| Committed | **nothing** — this is step 1 |
| Deployed | **never** — three manual runs exist in BigQuery, at old settings |

The three windows already in `fds_gestun_scores` were produced by the old model
at thresholds 0.5 and 0.7, with `review` and `rule_flag` unpopulated. They are
not comparable to what this deploy produces. Leave them; filter on
`window_end >= '2026-09-30'` when you want only the new regime.

---

## 1. Put the code on GitHub

**Why:** the deploy is driven by a push to `main`. No remote, no deploy.

1. Create an empty **private** repo at `github.com/paper-id/fds-gestun`.
   Do not add a README or .gitignore — the repo already has both.
2. Back in the terminal:

```bash
cd ~/Desktop/paper.id/fds
git remote add origin git@github.com:paper-id/fds-gestun.git
```

3. Commit the work. Ask Claude to do this — it will split it into reviewable
   commits rather than one lump. Then:

```bash
git push -u origin main
```

**Check it worked:** the repo shows the files, and the **Actions** tab shows a
`CI` run. It will pass. `Deploy DAG` will fail at the auth step — expected, the
secrets come in step 4.

> `.gitignore` excludes `artifacts/` and `utils/`. That is deliberate: the model
> is rebuilt on the worker, and `utils/` holds credentials that must never be
> committed. See step 7.

---

## 2. Add the missing column to the results table

**Why:** the publish step writes `tpv_in_window`. The table does not have it yet,
so BigQuery would reject the load and the run would fail after doing all the work.

Open the BigQuery console, pick the `paper-prod` project, and run:

```sql
ALTER TABLE `paper-prod.datascience_public.fds_gestun_scores`
  ADD COLUMN IF NOT EXISTS tpv_in_window FLOAT64
  OPTIONS(description="PAID rupiah in the scored window. The review gate's floor.");
```

**Check it worked:** the table's Schema tab lists 19 columns, last one
`tpv_in_window`.

Existing rows get `NULL` there. That is correct — those weeks were scored before
the column existed.

---

## 3. Create the Composer environment (skip if one exists)

**Why:** something has to run the DAG on a schedule.

In the Cloud Console → **Composer** → Create environment (Composer 3, Airflow 3).

Region must be `asia-southeast1`, the same region as the BigQuery datasets —
otherwise every query pays cross-region transfer and some fail outright.

Then, in the environment's **Environment variables** tab, add:

| name | value | why |
|---|---|---|
| `FDS_MODEL_DIR` | `/home/airflow/gcs/data/fds_gestun` | where the worker writes the model it trains. The default (`./artifacts`) is not writable on a worker. |

Leave `FDS_GCP_CREDENTIALS` unset. The workers authenticate through the
`google_cloud_default` Airflow connection, which Composer wires up for you.

**Check it worked:** the environment is green, and the **DAGs** tab opens (empty
for now).

Note the environment's **service account** email and its **DAGs bucket** path —
both are on the environment details page. You need them in steps 4 and 6.

---

## 4. Give GitHub permission to deploy

**Why:** the workflow authenticates to Google with Workload Identity — no
service-account key file anywhere.

### 4a. Grant the service account access

The Composer service account from step 3 needs, on `paper-prod`:

- **BigQuery Job User** — to run queries
- **BigQuery Data Editor** on `datascience_public` — to write the results table
- **BigQuery Data Viewer** on the source datasets it reads
  (`data_mart_layer`, `data_warehouse_layer`, `datawarehouse_dwd`,
  `datawarehouse_rpt`, `datascience_public`)
- **Storage Object Admin** on the DAGs bucket — so the workflow can sync files

### 4b. Add the five repo secrets

GitHub repo → Settings → Secrets and variables → Actions → New repository secret:

| secret | where to find it |
|---|---|
| `GCP_WIF_PROVIDER` | the Workload Identity provider resource name, `projects/…/locations/global/workloadIdentityPools/…/providers/…`. Ask platform/infra — they likely have a pool already. |
| `GCP_DEPLOY_SA` | the service account email the workflow impersonates |
| `COMPOSER_DAG_BUCKET` | `gs://…` from the environment page (no `/dags` suffix) |
| `COMPOSER_ENV` | the environment name |
| `COMPOSER_REGION` | `asia-southeast1` |

**Check it worked:** GitHub → Actions → `Deploy DAG` → Run workflow. It should
finish green, with the last step reporting files copied.

---

## 5. Confirm the DAG arrived

**Why:** a DAG that fails to import is invisible rather than red.

Composer → your environment → **Airflow UI** → DAGs. `fds_gestun_scoring` should
be listed, **paused**. Leave it paused.

If it is missing, check Airflow UI → Browse → **Import Errors**. The usual cause
is `fds_gestun` not importing, which means step 4's sync did not copy
`dags/fds_gestun/`.

**Check it worked:** clicking the DAG shows eight tasks:

```
assert_source_is_fresh ─┐
                        ├─> select_candidates ─> build_features ─> score ─┬─> publish ─> publish_to_sheet
ensure_model ───────────┘                                                └─> publish_transactions
```

---

## 6. Run it once by hand

**Why:** the first run is the one that finds the environment problems. Do it
while watching, not at 08:00 on a Thursday.

In the Airflow UI, **Trigger DAG w/ config** and paste:

```json
{"window_start": "2026-09-24", "window_end": "2026-09-30"}
```

Then watch, in order:

| task | expect | if it fails |
|---|---|---|
| `assert_source_is_fresh` | passes in seconds | the source mart has not loaded 30 Sep yet. Wait, or pick an earlier window. |
| `ensure_model` | logs `trained on 582 companies, 182 features` | `FDS_MODEL_DIR` is unset or not writable — step 3. |
| `select_candidates` | logs a candidate count in the low thousands | BigQuery permissions — step 4a. |
| `build_features` | 10–20 minutes, the slow one | a missing dataset grant — step 4a. |
| `score` | logs `N in the review queue` | — |
| `publish` | logs `published to …fds_gestun_scores` | schema mismatch means step 2 was skipped. |
| `publish_to_sheet` | **skips** | expected. No sheet configured yet — see step 8. |

**Check it worked:**

```sql
SELECT window_end, COUNT(*) AS scored,
       COUNTIF(decision = 'GESTUN') AS flagged,
       COUNTIF(review) AS queue,
       ROUND(COUNTIF(decision='GESTUN') / COUNT(*) * 100, 1) AS flag_rate_pct
FROM `paper-prod.datascience_public.fds_gestun_scores`
WHERE window_end = '2026-09-30'
GROUP BY window_end;
```

`flag_rate_pct` should be roughly **4–6%**. If it is 30%+, the threshold did not
take effect — check the run's `threshold` param.

---

## 7. Turn on the schedule

Unpause `fds_gestun_scoring` in the Airflow UI. It runs **Thursday 08:00 WIB**,
scoring the seven days ending the previous day.

`catchup=False`, so unpausing does not replay the weeks it missed.

Two things to set up around it:

- **Failure email.** `default_args` already sets `email_on_failure=True`; put a
  real address in the Airflow `smtp` config or the alert goes nowhere.
- **Rotate the credentials in `utils/risk_creds.py`.** Unrelated to this deploy,
  but that file holds live plaintext ArangoDB and MySQL production passwords.
  It is gitignored, so it will not reach GitHub — the exposure is the file
  itself. Rotate both, then delete it.

---

## 8. Optional: the reviewers' sheet

Two designs. Pick one; do not run both.

### A. BigQuery pushes into the sheet — already built

Works on any Workspace tier.

1. Create a spreadsheet.
2. Share it with the Composer service account as **Editor**.
3. Airflow UI → Admin → Variables → add `fds_gestun_sheet_id` = the id from the
   URL (between `/d/` and `/edit`).

`publish_to_sheet` then appends each week to a `review_queue` tab, writing only
columns A–I. `verdict`, `reviewer` and `notes` to the right are yours and are
never touched. Append-only, idempotent per week.

### B. The sheet pulls from BigQuery — needs Workspace Business Standard or above

1. Run [sql_ops/review_queue_view.sql](sql_ops/review_queue_view.sql) in the
   BigQuery console to create the view.
2. In a new spreadsheet: Data → Data connectors → Connect to BigQuery → pick
   `fds_gestun_review_queue` → Extract → set a weekly refresh.
3. Put verdicts in a **separate tab**, keyed by `company_id` + `window_end`, and
   join with a formula.

Step 3 is not optional. A Connected Sheets refresh rewrites its whole data
block, so a verdict column sitting beside the extract ends up against the wrong
company next week.

Design B is the better long game: verdicts in their own tab are straightforward
to load back into BigQuery as training labels, which is the thing that actually
improves this model. Design A is the safer one if the Workspace tier is unclear.

If you pick B, ask Claude to delete the `publish_to_sheet` task and its tests —
leaving a dead task in the graph is how a pipeline rots.

---

## Rolling back

| situation | what to do |
|---|---|
| DAG misbehaving | pause it in the Airflow UI. Nothing else runs. |
| A bad week published | `DELETE FROM …fds_gestun_scores WHERE window_end = 'YYYY-MM-DD'`. The table is partitioned on `window_end`, so this is cheap and touches nothing else. |
| Bad code shipped | revert the commit and push. The workflow redeploys on `main`. |
| Too many companies flagged | Airflow → Admin → Variables is not the lever; set the environment variable `FDS_THRESHOLD` on the Composer environment, or pass `{"threshold": 0.995}` on a manual run. No code change, no redeploy. |

---

## What this deploy does not give you

The pipeline will run, publish and queue. It does not make the queue *trusted*.

Every precision number behind the 0.99 threshold comes from 582 companies that
someone already suspected — about one in three of them is gestun, against a
population rate nobody has measured. The threshold itself was chosen because its
flag rate (4.7%) sits next to the old pprrsk001 model's (5.0%), and that model is
not ground truth either.

Reviewing a random sample of ~100 companies scoring 0.90–0.99 would turn that
number from a guess into a measurement. It needs no deploy and can run in
parallel with all of the above.
