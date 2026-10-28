# Handover — gestun scoring pipeline

For the data engineer reviewing this before it goes on a schedule.

Weekly batch job. Scores every company that transacted in the last seven days for
gestun (credit-card cash-out), writes a partition to BigQuery, and produces a
review queue for the risk team. Runs Thursday 08:00 WIB.

`pytest -q` → **65 passed**. `fds-gestun train` works from a clean checkout; the
model is not in the repo and is not meant to be.

---

## Read in this order

| # | file | what to look for |
|---|---|---|
| 1 | `DEPLOY.md` | the seven steps, and the four things only Pamela/infra can supply |
| 2 | `dags/fds_gestun_scoring.py` | the whole job. Eight tasks, ~560 lines, comments explain the *why* |
| 3 | `fds_gestun/config.py` | every tunable, each with the measurement behind it |
| 4 | `fds_gestun/rules.py` | the deterministic layer that runs beside the model |
| 5 | `.github/workflows/deploy.yml` | how code reaches Composer |
| 6 | `tests/test_dag.py` | the contract the DAG is held to |

The rest (`features.py`, `model.py`, `bq.py`, `sql/*.sql`) is the feature and
model machinery. Worth a skim; it has not changed in shape for weeks.

---

## Task graph

```
assert_source_is_fresh ─┐
                        ├─> select_candidates ─> build_features ─> score ─┬─> publish ──> publish_to_sheet
ensure_model ───────────┘                                                 └─> publish_transactions
```

Four things here are deliberate and easy to "fix" wrongly:

**`assert_source_is_fresh` gates everything.** The source mart rebuilds daily and
a given day is only complete after the *next* day's rebuild. Scoring early
silently uses a fraction of the week and produces a plausible-looking queue built
on partial data. Failing is the better outcome.

**`ensure_model` runs before `build_features`, not before `score`.** `artifacts/`
is gitignored, so a fresh worker has no model. Training takes ~75s and needs no
BigQuery. Putting it early means a missing model fails the run *before* it pays
for a full scan of the mart.

**`publish_to_sheet` is downstream of `publish` and has no downstream of its
own.** BigQuery is the system of record. A Sheets API hiccup must not be able to
fail a run that already published, and must not be able to lose a week of scores.

**`build_features` is the expensive task.** 10–20 minutes, a full scan per feature
query. Measured cost per run: 0.011 TiB, about $0.07 on-demand. Cheap, but it is
why both gates close in front of it.

---

## Decisions that will look odd without the reason

### The decision threshold is 0.99

Not chosen from a precision/recall table. Precision barely moves above 0.90 while
recall falls away, so that table cannot pick a threshold.

It is chosen from the **flag rate**. The model is fit on 582 labelled companies of
which 35.2% are gestun, and `scale_pos_weight` balances that to 50/50 — so the
probabilities carry the *training* prior, not the population's. At threshold 0.70
the job called 33% of a week's companies gestun, which is the training prior
played back rather than a finding. 0.99 flags 4.7%, next to the 5.0% the old
`pprrsk001` model flags on the same population.

**This number does not survive a retrain.** Dropping two features moved the median
score 0.276 → 0.404 and turned 0.98 from a 5.3% flag rate into 9.6% on the same
week, with no change in what the model was asked to do. Re-measure the flag rate
after every retrain. The durable fix is to flag a quantile of the batch instead of
a fixed probability; it is not built.

### `decision` and `review` are different columns

`decision` is the model's call at the threshold. `review` is a capacity decision
layered on top:

```
review = (gestun_probability >= REVIEW_THRESHOLD OR rule_flag) AND tpv_in_window >= 10_000_000
```

Consumers work from `review`, not `decision`. The rule branch is `OR` because
rules exist to catch what the model misses — two confirmed gestun companies in
the 17–23 Sep window scored 0.62 and 0.64 and reach the queue on rules alone. The
rupiah floor applies to rules too; a rule firing on a Rp 15,000 week is not worth
an hour.

The floor is rupiah rather than transaction count on purpose. Ticket size does not
separate the classes — clean companies have the *higher* median ticket, 18.1jt
against 11.1jt — but total value does.

### Known-label companies are excluded, not scored

`select_candidates` left-joins `fds_gestung_actual_label_130826` and drops
matches. Scoring a company the model was trained on returns a fitted value, not a
prediction. `cli.py` has the same guard and reports the stored label instead.

### The package ships inside the DAG folder

`deploy.yml` copies `fds_gestun/` to `dags/fds_gestun/` and the two data files to
`dags/`. Composer puts `/home/airflow/gcs/dags` on `sys.path`, so it imports as
`fds_gestun` with no pip install and no deploy key.

The previous version ran
`gcloud composer environments update --update-pypi-package "fds-gestun==1.0.0"`,
which resolves against public PyPI. This is a private package; that step would
have failed, or installed a stranger's package of the same name.

`config.REPO_DIR` is the package's parent, which on the worker is the dags folder
— that is why `fds_gestun_training_set.csv` and `fds_gestun_features_179.csv` have
to sit beside it. The staging step asserts all four paths exist before the sync.

---

## What this needs from you

| | |
|---|---|
| Composer environment, `asia-southeast1` | same region as the BigQuery datasets, or every query pays cross-region |
| Environment variable `FDS_MODEL_DIR=/home/airflow/gcs/data/fds_gestun` | the default `./artifacts` is not writable on a worker |
| Workload Identity provider + a deploy service account | five GitHub secrets, listed in `DEPLOY.md` step 4 |
| IAM on the Composer service account | BigQuery Job User; Data Editor on `datascience_public`; Data Viewer on `data_mart_layer`, `data_warehouse_layer`, `datawarehouse_dwd`, `datawarehouse_rpt` |
| One DDL statement | `ALTER TABLE … ADD COLUMN tpv_in_window FLOAT64`. `DEPLOY.md` step 2 has it verbatim. Without it the publish step is rejected. |

Leave `FDS_GCP_CREDENTIALS` unset on the workers — auth goes through the
`google_cloud_default` connection.

---

## Risks worth your eyes

**The published table already holds three windows at old settings.** Thresholds
0.5 / 0.5 / 0.7, the previous 184-feature model, `review` and `rule_flag` all
NULL. Not comparable to what this produces. Leave them; filter
`window_end >= '2026-09-30'` for the new regime.

**Nothing has run end to end on Composer.** The three existing windows came from
manual local runs. `DEPLOY.md` step 6 is a supervised first run with a per-task
table of what to expect — please do that rather than unpausing straight away.

**`publish_to_sheet` is append-only and cannot correct a week it already
published.** Deliberate: reviewers keep verdicts in the columns to its right, and
a task that rewrote rows would destroy their work. Rescore into BigQuery and fix
the sheet by hand.

**`fds_gestun_scores_txn` has one window in it and no delete-then-insert
protection worth trusting yet.** `publish_transactions` does
`DELETE … WHERE window_end = @we` then loads. It has run once. Worth your review.

---

## The part that is not an engineering problem

This pipeline will run, publish and queue correctly. That is not the same as the
queue being trustworthy.

Every precision figure behind the 0.99 threshold is measured on 582 companies
that somebody already suspected — roughly one in three of them is gestun, against
a population rate nobody has measured. The threshold was then set to match
another model's flag rate, and that model is not ground truth either.

Reviewing a random sample of ~100 companies scoring 0.90–0.99 turns that guess
into a measurement. It needs no deploy and can run in parallel. If anyone asks
"how good is this model", that sample is the honest answer and it does not exist
yet.

---

## Added since this was written (28 Oct 2026)

Three modules landed after the sections above were drafted. They are additive:
nothing in the scoring path changed.

| file | what it does |
|---|---|
| `fds_gestun/rules.py` | the five deterministic rules (R1–R5) that run beside the model |
| `fds_gestun/invoice_match.py` | compares a company's invoice line items against the business type it declared at onboarding, and returns match / adjacent / MISMATCH / unreadable |
| `fds_gestun/weekly_sheet.py` | appends one scored week to a Google Sheet, `run_date` first and one block per run |

### The threshold should probably be 0.98, not 0.99

Measured out-of-fold on the 582 labelled companies, 0.98 gives **higher precision
and higher recall** than 0.99 (0.981/0.502 against 0.969/0.302). False positives
sit at 2 either way, so 0.99 discards 41 true positives and buys nothing. The
only cost of 0.98 is queue length, 346 companies a week becoming 659.

`DECISION_THRESHOLD` in `config.py` is still 0.99, because that is a capacity
decision for the risk team rather than an engineering one. It has not been
changed pending that call. The comment in `config.py` justifying 0.99 on
precision grounds is wrong and is corrected in `FDS_PayGeneral_vs_Gestun.md`.

### Two things are broken outside this repo

**The service-account key is revoked.** `bigquery-composer@paper-prod` returns
`invalid_grant: Invalid JWT Signature` as of 28 Oct; it worked on 13 Oct. Local
runs now use application-default credentials, which works for BigQuery but
**not** for Sheets: user credentials need a quota project, and that needs
`serviceusage.services.use`, which `pamela.huang@paper.id` does not hold on
`paper-prod`. On Composer this does not arise, because the DAG authenticates as
the environment's service account. A replacement key is needed regardless.

**`mlfds_ml_labeling` has not scored anything since 21 September.** Three weeks
at 0% coverage. It feeds the Looker fraud report, where a missing score reads as
"not fraud". `sql_ops/ppr0002_ml_null_patch.sql` fixes the downstream reading;
the load itself belongs to its own owner, and
`sql_ops/ESCALATION_mlfds_ml_labeling.md` is the draft to send.

### Weekly runs so far

All produced by hand, none by the scheduler.

| window | companies | GESTUN | queue |
|---|---|---|---|
| 24–30 Sep | 6,559 | 6.8% | 434 |
| 1–7 Oct | 6,821 | 7.0% | 464 |
| 8–14 Oct | 6,004 | 6.2% | 340 |
| 15–21 Oct | 5,906 | 5.8% | 340 |

The flag rate drifting down while the model has not been retrained since
28 September points at the population, not the model. Worth re-checking after a
retrain, since the threshold does not survive one.
