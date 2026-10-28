# fds-gestun

Gestun (credit-card cash-out) detection for paper.id. Company-level scoring on
BigQuery data.

Batch, not real-time: building the feature matrix is ~10 minutes of BigQuery per
run, so this is a scheduled job, not a request/response service.

## Reviewing this for the first time

Read [HANDOVER.md](HANDOVER.md) first. It gives the task graph, the decisions
that look wrong without their reason, what this needs from infrastructure, and
the risks worth your attention. Then [DEPLOY.md](DEPLOY.md) for the steps.

Nothing here has run on a scheduler yet. Every week produced so far came from a
manual run, so the first supervised Composer run (DEPLOY.md step 6) is the one
that will find the environment problems.

```bash
pip install -e ".[dev]" && pytest -q      # 65 tests, no BigQuery needed
```

Passes from a clean checkout. If it fails, stop there and tell us rather than
working around it.

### Training data

`fds-gestun train` needs `fds_gestun_training_set.csv` in the repository root,
and this repository does not contain it. It is 582 paper.id companies with
investigation verdicts attached, 205 confirmed gestun and 377 cleared, so it is
data about identifiable customers rather than code and it is not published here.

Ask the data team for it, or rebuild it with `fds_training_set_gestun.sql`
against `datascience_public.fds_gestung_actual_label_130826`. Drop it in the
root and `train` works; it is gitignored, so it cannot be committed by accident.

Without it, the tests still pass in full and `train` fails with a message naming
the missing file.

Run outputs (`*_scores.csv`, `*_features.csv`, `*_review_queue.csv`) are
gitignored: they are reproducible from BigQuery, they carry customer and owner
names, and one week of features is about 6 MB. The published copy of each week
lives in `datascience_public.fds_gestun_scores`.

## Install

```bash
pip install -e ".[dev]"
```

Authentication uses application-default credentials. For local development only:

```bash
export FDS_GCP_CREDENTIALS=/path/to/service-account.json
```

## Use

```bash
# fit and persist the model (writes artifacts/gestun_model.json)
fds-gestun train --eval

# score a list of companies (CSV with a company_id column)
fds-gestun score --companies companies.csv --out scores.csv

# raise the bar when review capacity is the constraint
fds-gestun score --companies companies.csv --out scores.csv --threshold 0.99

# build features without scoring, e.g. to cache them
fds-gestun features --companies companies.csv --out features.csv
fds-gestun score --features features.csv --out scores.csv

# cross-validated metrics and the threshold table
fds-gestun evaluate --thresholds
```

As a library:

```python
from fds_gestun import build_features, GestunModel

model = GestunModel.load()
scores = model.score(build_features(["3f1bb6b4-...", "cf5d2b61-..."]))
```

## Output

| column | meaning |
|---|---|
| `gestun_probability` | model score, 0-1 |
| `decision` | `GESTUN` / `clean` at the threshold |
| `risk_band` | very high / high / elevated / borderline / low |
| `features_present` | non-null features out of 184; a low count means a thin company |

Companies already in the training set are **not scored** — the CLI returns their
known label and says so. Scoring a company the model trained on returns a fitted
value, not a prediction.

## Configuration

All via environment variables (see `fds_gestun/config.py`):

| variable | default | notes |
|---|---|---|
| `FDS_GCP_PROJECT` | `paper-prod` | |
| `FDS_BQ_LOCATION` | `asia-southeast1` | |
| `FDS_GCP_CREDENTIALS` | unset | unset = application-default credentials |
| `FDS_MODEL_DIR` | `./artifacts` | where the model artefact lives |
| `FDS_TRAINING_SET` | `./fds_gestun_training_set.csv` | |
| `FDS_THRESHOLD` | `0.5` | decision cutoff |
| `FDS_BQ_MAX_BYTES` | 2 TB | kills a runaway scan |
| `FDS_N_JOBS` | `4` | XGBoost threads |

## Performance

582 labelled companies (205 gestun), 184 features, 50-fit repeated CV:

| | mean | sd |
|---|---|---|
| precision | 0.898 | 0.047 |
| recall | 0.832 | 0.054 |
| ROC-AUC | 0.960 | |

Out-of-fold, by threshold, and the flag rate each one produced on the 17-23 Sep
week (5,643 companies). The flag rate is what the threshold is chosen on:
precision barely moves above 0.90 while recall falls away.

| threshold | precision | recall | flag rate |
|---|---|---|---|
| 0.50 | 0.869 | 0.857 | 45% |
| 0.90 | 0.918 | 0.707 | 25.0% |
| 0.95 | 0.940 | 0.649 | 18.3% |
| 0.98 | 0.963 | 0.512 | 9.6% |
| **0.99** | 0.946 | 0.259 | **4.7%** |

Measured on the 582 labelled companies, which are companies someone already
found worth reviewing -- roughly one in three of them is gestun, against a
population rate nobody has measured. Read the table as a ranking of the options,
not as a promise about precision in production.

## Known limitations — read before acting on a score

**The probabilities are not calibrated.** Treat them as a ranking. On a held-out
batch of 35 labelled companies the model reported individual scores above 99%
while achieving ROC-AUC 0.65. Rank the queue; do not read 99% as 99%.

**The model partly learned "small company = gestun."** `n_out_partners` is its
highest-gain feature, and among labelled companies the median is 45 for clean
against 4 for gestun. Within the small-company stratum, where a reviewer actually
needs help, ROC-AUC falls from 0.96 to ~0.87. It will over-flag small legitimate
businesses.

**The training base rate is ~35%, which is not the population rate.** The labelled
set came from investigations. Scoring a general population with it over-flags
heavily — on a recent 1,198-company batch it flagged 80%.

**Missingness is predictive and that is partly an artifact.** A company absent from
the upstream FDS table is 46% gestun in the training data versus 25% for one
present; with no `Out` transactions, 75%. Some of that is "was this company ever
investigated", not behaviour. `features_present` in the output flags thin rows.

**Four features run opposite to intuition** and must never be phrased as fraud
signals in a rule: `pct_partner_abbrev`, `pct_partner_allcaps_name`,
`is_disb_ptcv`, `pct_out_partner_eq_payout_acct`. See the `notes` column of
`fds_gestun_features_179.csv`.

## Layout

```
fds_gestun/
  config.py     env-driven settings, model params, thresholds
  bq.py         BigQuery client, parameterised queries
  features.py   build_features() -- the feature matrix for any company list
  model.py      train / save / load / score
  evaluate.py   cross-validation and the threshold table
  cli.py        fds-gestun entry point
  sql/          one .sql per feature source, all @company_ids parameterised
dags/         Airflow DAG (weekly scoring)
tests/          25 tests, no BigQuery needed
```

`sql/` is the source of truth for feature definitions. The notebooks
(`FDS_Gestun_Combined_Features.ipynb`, `FDS_Gestun_Scoring.ipynb`) are exploration
and analysis; they are not on the deployment path.

## Scheduling (Airflow)

`dags/fds_gestun_scoring.py` runs weekly, Thursdays 03:00 Jakarta. Four tasks:

```
select_candidates -> build_features -> score -> publish
```

- **select_candidates** — every company that transacted during the run's
  Thursday-to-Wednesday week, excluding anything already labelled. A run on Thu
  17 Sep scores companies active 10–16 Sep inclusive.

  The window ends the day **before** the run because the source mart lands H-1:
  Thursday's transactions are not in BigQuery when the Thursday job fires. That
  means no window ever contains a partial day, and consecutive windows leave no
  gap — both are asserted in the tests.

  The window is derived from the run day, not `CURRENT_DATE()`, so a re-run or a
  backfill scores the week it was meant to.

- **build_features** — the slow step, one BigQuery job per source (~10 min per
  1k companies). Cached to `/tmp`, so a scoring failure does not force a rebuild.
- **score** — XGBoost forward pass on the worker. Logs a warning if the flag rate
  exceeds 50%, which means the batch does not resemble the training population.
- **publish** — load job into `datascience_public.fds_gestun_scores`, partitioned
  on `window_end` and clustered on `decision` / `risk_band` / `company_id`.

  The task deletes the window's existing rows before loading, so a re-run
  replaces rather than duplicates. Every row carries its provenance:
  `window_start` / `window_end`, the `threshold` that produced the decision, and
  `model_trained_on` / `model_positives` / `model_features`. A score is not
  interpretable without them.

Overridable at trigger time: `window_start`, `window_end`, `min_transactions`,
`min_rescore_days`, `threshold`, `max_companies`. To score a specific week by
hand:

```bash
airflow dags trigger fds_gestun_scoring \
  --conf '{"window_start": "2026-09-10", "window_end": "2026-09-16"}'
```

`min_rescore_days` defaults to 0, so a company active in consecutive weeks is
scored each week — that is the point of a weekly assessment. Raise it if
reviewers start seeing repeats.

### Worker requirements

The workers import `fds_gestun`, so install it there:

```bash
pip install git+ssh://git@github.com/paper-id/fds-gestun.git@main
```

Auth uses the `google_cloud_default` connection — do not set `FDS_GCP_CREDENTIALS`
on the workers.

The model artefact does not need to be shipped. `artifacts/` is gitignored, so
the `ensure_model` task rebuilds it on the worker when it is missing or was fit
on a different number of companies than `fds_gestun_training_set.csv` holds --
~75s, no BigQuery, deterministic given the committed training set and
`config.SEED`. It runs before `build_features`, so a missing model fails the run
before it pays for a scan of the mart. Set `FDS_MODEL_DIR` to a writable path if
the default is read-only.

### The reviewers' Google Sheet

`publish_to_sheet` appends each week's review queue to one tab, `review_queue`,
in a spreadsheet you own. Two things to set up:

1. Create the spreadsheet, then set the Airflow Variable `fds_gestun_sheet_id`
   to its id (the part of the URL between `/d/` and `/edit`). The environment
   variable `FDS_GESTUN_SHEET_ID` works too. Unset, the task skips rather than
   fails, so the pipeline runs before the sheet exists.
2. Share the sheet with the Composer service account as **Editor**. Without it
   the API returns 403 and only this task fails -- BigQuery is already written by
   then.

The task is append-only and writes columns A..I. `verdict`, `reviewer` and
`notes` sit to the right and belong to the reviewers: nothing the DAG does
touches them, and it never clears or rewrites a row. It is idempotent by
`window_end`, so a retry finds its own week already present and stops.

The consequence worth knowing: it cannot correct a week it has already
published. Rescore into BigQuery and fix the sheet by hand -- the alternative is
a task that deletes rows people may have annotated. The tab grows by about 360
rows a week.

### Deploying the DAG

`.github/workflows/deploy.yml` runs the tests, then syncs `dags/` to the Composer
bucket. For self-hosted Airflow, swap the `gsutil rsync` step for an rsync to your
DAG folder. Required secrets: `GCP_WIF_PROVIDER`, `GCP_DEPLOY_SA`,
`COMPOSER_DAG_BUCKET`, `COMPOSER_ENV`, `COMPOSER_REGION`.

The scheduled run uses threshold **0.99**, set from the flag rate rather than
from a precision table: at 0.70 the model called 33% of a week's companies
gestun, which is the training prior (35.2%) played back. 0.99 flags 4.7%, next
to the 5.0% the old pprrsk001 model flags on the same population.

The threshold is tuned to one model's score distribution and does not survive a
retrain -- dropping two identifier features moved the median score 0.276 -> 0.404
and turned 0.98 from a 5.3% flag rate into 9.6% on the same week. Re-measure the
flag rate after every retrain.

## Retraining

1. Append newly labelled companies to `fds_gestun_training_set.csv`
   (`company_id`, `is_gestun`, plus all 184 features — build them with
   `fds-gestun features`).
2. `fds-gestun train --eval` and check the metrics did not regress.
3. Commit the training set; the model artefact is rebuilt by CI.

Adding hard clean examples usually *lowers* headline precision. That is the
estimate becoming honest, not a regression.
