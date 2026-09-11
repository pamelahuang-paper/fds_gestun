# fds-gestun

Gestun (credit-card cash-out) detection for paper.id. Company-level scoring on
BigQuery data.

Batch, not real-time: building the feature matrix is ~10 minutes of BigQuery per
run, so this is a scheduled job, not a request/response service.

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
fds-gestun score --companies companies.csv --out scores.csv --threshold 0.7

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

Out-of-fold, by threshold:

| threshold | precision | recall |
|---|---|---|
| 0.5 | 0.866 | 0.790 |
| 0.7 | 0.932 | 0.737 |
| 0.8 | 0.948 | 0.712 |

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

`dags/fds_gestun_scoring.py` runs weekly, Tuesdays 03:00 Jakarta. Four tasks:

```
select_candidates -> build_features -> score -> publish
```

- **select_candidates** — every company that transacted during the run's week,
  excluding anything already labelled. The window is Airflow's data interval, so
  the run on Tue 11 Aug scores companies active 4–10 Aug inclusive.

  It is deliberately *not* `CURRENT_DATE()`. A re-run or backfill has to score the
  week it was meant to — re-running August in October must still score August.
  Change the cron weekday to move the boundary: `0 3 * * 2` gives Tue–Mon weeks,
  `0 3 * * 1` gives Mon–Sun.

- **build_features** — the slow step, one BigQuery job per source (~10 min per
  1k companies). Cached to `/tmp`, so a scoring failure does not force a rebuild.
- **score** — XGBoost forward pass on the worker. Logs a warning if the flag rate
  exceeds 50%, which means the batch does not resemble the training population.
- **publish** — load job into `datascience_public.fds_gestun_scores`.

Overridable at trigger time: `window_start`, `window_end`, `min_transactions`,
`min_rescore_days`, `threshold`, `max_companies`. To score a specific week by
hand:

```bash
airflow dags trigger fds_gestun_scoring \
  --conf '{"window_start": "2026-08-04", "window_end": "2026-08-10"}'
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

The model artefact must exist on the worker (`FDS_MODEL_DIR`, default
`./artifacts`). Either bake it in at image build time or add a `fds-gestun train`
step ahead of `score`; training takes ~75s and needs no BigQuery.

### Deploying the DAG

`.github/workflows/deploy.yml` runs the tests, then syncs `dags/` to the Composer
bucket. For self-hosted Airflow, swap the `gsutil rsync` step for an rsync to your
DAG folder. Required secrets: `GCP_WIF_PROVIDER`, `GCP_DEPLOY_SA`,
`COMPOSER_DAG_BUCKET`, `COMPOSER_ENV`, `COMPOSER_REGION`.

The scheduled run uses threshold **0.7**, not the 0.5 library default: out-of-fold
that is precision 0.932 against 0.866, which is what matters for a queue people
actually work.

## Retraining

1. Append newly labelled companies to `fds_gestun_training_set.csv`
   (`company_id`, `is_gestun`, plus all 184 features — build them with
   `fds-gestun features`).
2. `fds-gestun train --eval` and check the metrics did not regress.
3. Commit the training set; the model artefact is rebuilt by CI.

Adding hard clean examples usually *lowers* headline precision. That is the
estimate becoming honest, not a regression.
