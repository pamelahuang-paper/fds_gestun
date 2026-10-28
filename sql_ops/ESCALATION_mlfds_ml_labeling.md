Written for: the owner of the Composer DAG that loads `mlfds_ml_labeling`.
Paste the section below the line into Slack or email. Replace the bracketed bits.

---

Hi — raising something on `datawarehouse_dwd.mlfds_ml_labeling`. The weekly load
is succeeding while loading an almost empty file, and because it reports success
nothing alerts on it.

**Twice now, both on the first Thursday of the month:**

| store_date | load size | rows loaded | job state |
|---|---|---|---|
| **2026-10-01** | **0.2 KB** | **2** | DONE, no error |
| 2026-09-24 | 17.9 MB | 139,784 | DONE |
| 2026-09-17 | 13.1 MB | 102,248 | DONE |
| 2026-09-10 | 7.9 MB | 61,872 | DONE |
| **2026-09-03** | **0.3 KB** | **4** | DONE, no error |
| 2026-09-03 *(rerun)* | 0.3 KB | — | DONE |
| 2026-08-27 | 20.0 MB | 158,669 | DONE |
| 2026-08-20 | 15.7 MB | 122,377 | DONE |

Jobs run as `bigquery-composer@paper-prod.iam.gserviceaccount.com`, LOAD type,
`WRITE_APPEND`, Thursdays around 02:46–03:16 UTC. Today's job id is
`54f2085a-79ac-44f6-8e1f-ec46f2891c11` — `output_rows = 2`.

Two things stand out:

1. **The prediction step upstream of the load produced nothing**, on the first
   Thursday of September and again of October. Two months running on the same day
   of the cycle does not look like chance.
2. **The 3 Sep job was rerun the same day at 04:36 and still loaded 0.3 KB**, so a
   retry alone does not recover it.

**Three questions:**

- What does the task before the load read from? If it filters on a month boundary,
  the first run of a month may be selecting an empty range.
- Can the DAG assert a minimum row count before loading? A 0.2 KB load passing as
  success is what made this invisible both times.
- Was 3 September ever backfilled properly, or did it only get picked up by the
  10 September run? Asking because the 10 Sep load was 61,872 rows where the
  pattern suggests it should have been larger, so some of that week may still be
  missing.

**Why this matters downstream:** `mlfds_ml_labeling` feeds
`datawarehouse_rpt.ppr0002reprisid_1_list_of_fraudulent_transaction`, which feeds
the fraud monitoring report in Looker. When the probabilities are NULL the
report's `is_ml_predict_fraud` reads **0**, so unscored transactions appear as
"checked, not fraud". For the week of 28 Sep that is 1,973 transactions currently
shown as clean that nothing has looked at.

We are patching our side so unscored rows show as NULL instead of 0 — that makes a
stalled load visible rather than silently wrong. But the gap itself needs fixing
at the source.

No rush on today's specifically if the next run backfills, which is what
10 September suggests. The repeat is the part worth a look.

Thanks — [your name]
