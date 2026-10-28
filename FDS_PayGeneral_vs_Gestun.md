# FDS Pay General vs the new gestun model

Comparison window 17–23 September 2026. Latest production run 1–7 October 2026. Prepared 13 October 2026.

## Summary

The new gestun model should go live, and it should run alongside FDS Pay General rather than replace it. The two systems answer different questions and agree on only 7.4% of the companies they flag, so retiring either one would leave a gap.

Two decisions are needed. The first is the operating threshold: the measured curve does not support the 0.99 currently configured, because 0.98 gives both higher precision and nearly double the recall. The choice between them is about how many companies the review team can absorb each week, not about model quality, and it should be made on that basis. The second is validation: every accuracy figure in this document rests on 582 companies that were already under suspicion, and a review of roughly 100 randomly chosen companies is what would turn those figures into measurements.

Separately, FDS Pay General has scored no transactions for three weeks. That is a production incident independent of this comparison, and it needs the owner of its weekly load.

## What each model was built for

FDS Pay General scores one transaction at a time and asks whether that payment looks fraudulent. Its targets are stolen cards, links to blacklisted parties and unusual timing. It was never trained on a gestun label. Its output is the column shown as fraud by ML in the Looker fraud report.

The gestun model scores one company per week and asks whether that business is structured to cash out credit cards. Its targets are payout concentration, self-dealing between related parties and mismatches between card holder and payer. It was trained on 582 companies with confirmed outcomes.

The distinction matters for reading everything below. A single gestun company can run a hundred ordinary-looking payments; each one passes a transaction-level check, and the pattern appears only when the company is viewed as a whole. Adding gestun features to Pay General would not close that gap, because a company-level pattern has to be aggregated before a transaction-level model can see it, and that aggregation is most of the second model.

## Specifications

|  | FDS Pay General | Gestun model (new) |
|---|---|---|
| Algorithm | Random Forest and CatBoost, combined with OR | XGBoost with native categorical support |
| Features used | 25 and 20 | 182 |
| Prediction grain | Transaction | Company |
| Target | General payment fraud | Company runs gestun |
| Gestun labels in training | None | 582 companies, 205 gestun |
| Published validation | None found in the repository | 50-fit repeated stratified cross-validation |
| Decision threshold | 0.90, either model | 0.99, plus a five-rule layer |
| Orchestration | Jupyter notebook, run by hand | Airflow DAG, Thursday 08:00 WIB |
| Automated tests | None | 65 passing |
| Output typing | All columns STRING, cast on read | Typed BigQuery schema, partitioned |

The feature counts are the least useful row. The two models count different things at different grains, and more features is not automatically better. The rows that carry operational risk are the lower ones: no validation we could find, no tests, run by hand, untyped output.

One caveat on published validation. It means no metrics were found in the repository or the inference notebook, not that none were ever produced. If the original author holds them, they would change this row.

## Ranking ability on gestun

To compare the two on one yardstick, both were evaluated on the same 326 labelled companies: those that transacted during 17–23 September and were scored by both systems. Of these, 115 are confirmed gestun, a prevalence of 35.3%. Pay General's company score is the highest probability across its transactions, which is the same aggregation the Looker report uses.

Neither model had an unfair view of the answers. Pay General never saw gestun labels at all. The gestun model's figures are out-of-fold, so each company was scored by a model trained without it.

| Metric | FDS Pay General | Gestun model |
|---|---|---|
| ROC-AUC on gestun | 0.750 | 0.977 |
| PR-AUC on gestun | 0.586 | 0.949 |
| PR-AUC baseline | 0.353 | 0.353 |
| Exposure to gestun labels | None, fully out-of-sample | Out-of-fold |

Pay General's 0.750 is well above chance, and that is worth stating plainly. Gestun businesses do generate individual transactions that look fraudulent on their own, so the incumbent picks up part of the problem without being asked to. The gap appears in PR-AUC, which is the figure that matters for a review queue because it answers what fraction of an opened case list is real. There the two are 0.586 and 0.949.

This measures Pay General on a job it was not given. That is the operationally relevant question, since it is what runs today, but it is not a judgement on the model against its own purpose.

## Results at the thresholds in use

A ranking only matters at the point where it is cut. The figures below are on the same 326 companies, each system at its configured threshold, with 0.98 shown for the gestun model as the proposed alternative.

| System and threshold | Precision | Recall | Companies flagged |
|---|---|---|---|
| FDS Pay General, 0.90 | 66.7% | 17.4% | 30 |
| Gestun model, 0.99 (live) | 97.4% | 32.2% | 38 |
| Gestun model, 0.98 (proposed) | 98.5% | 58.3% | 68 |

Precision is the stronger argument here. At its configured threshold Pay General is right about two times in three when it flags a company for gestun, against about 39 times in 40 for the gestun model. For a team with fixed review hours, most of what the incumbent sends them on this particular problem is a clean company.

Recall of 32.2% at the live threshold is low, and that is a consequence of the threshold rather than a limit of the model. The 0.98 row shows the same model reaching 58.3% at higher precision.

## Choosing the threshold

The threshold was originally set at 0.99 and documented as a precision choice. The measured curve does not support that reading. Precision and recall below are out-of-fold on the 582 labelled companies; the flagged counts are from the 6,447 companies scored in the 1–7 October run.

| Threshold | Precision | Recall | Companies flagged | Share of population |
|---|---|---|---|---|
| 0.90 | 0.923 | 0.702 | 1,668 | 25.9% |
| 0.95 | 0.957 | 0.654 | 1,206 | 18.7% |
| 0.98 | 0.981 | 0.502 | 659 | 10.2% |
| 0.99 (live) | 0.969 | 0.302 | 346 | 5.4% |
| 0.995 | 0.941 | 0.156 | 132 | 2.1% |

False positives sit at two companies at both 0.98 and 0.99. Moving up to 0.99 therefore discards 41 true positives and buys no precision; it loses a little. The real cost of 0.98 is queue length, which grows from 346 companies a week to 659. That is a question about reviewer capacity, and it should be decided as one.

## Overlap on the same week

Restricting to the 3,586 companies that both systems scored during 17–23 September, so that neither is penalised for coverage:

| Flagged by | Companies |
|---|---|
| Both systems | 31 |
| Gestun model only | 210 |
| FDS Pay General only | 180 |
| Neither | 3,165 |
| Agreement between the two flag sets | 7.4% |

Low agreement is the expected result for two models targeting different behaviour, and it is the main argument for running both. In this single week Pay General raised 180 companies the gestun model did not. Those have not been reviewed, and some will be payment fraud that the gestun model is not designed to detect.

## Condition of the FDS Pay General pipeline

These measurements were taken from the live output table on 13 October 2026, during an investigation into why the Looker fraud report showed no ML-flagged transactions.

| Finding | Measurement |
|---|---|
| Weeks with no scores | 28 September, 5 October and 12 October are all at 0% coverage |
| Silent failure mode | The weekly load reported success while writing 2 rows |
| Duplicate rows | 9,548,094 rows for 3,221,606 transactions, a ratio of 2.96 |
| Conflicting scores | 361,212 transactions carry disagreeing probabilities; one appears 1,592 times |
| Coverage when healthy | 3,886 of 6,030 companies scored in its last working week, or 64% |
| Column typing | Every column is STRING, probabilities included |
| Column naming | A CatBoost probability is stored in a column named xgb_pred_proba |

Two consequences follow. A load that succeeds while writing almost nothing raises no alert, which is why this went unnoticed for three weeks. Downstream, the report treats a missing score as a zero, so 1,973 transactions in one week appeared as checked and not fraud when nothing had examined them. A one-line patch making that read as null instead is written and ready to apply.

The duplicate rows matter because the report aggregates with MAX, so any one of up to 1,592 scores above the threshold will flag a transaction.

The gestun pipeline was built with this failure in mind. It gates each run on source freshness and fails rather than scoring a partial week, and it carries 65 tests.

## Limits of this evidence

The pipeline is sound. The evidence behind the accuracy figures is thinner than the figures suggest, and the limits are worth stating before anyone asks.

All 582 labelled companies were already under suspicion, and 35% of them are gestun. Nobody has measured the rate in the general population, so precision measured on this set is optimistic for the population it will be applied to.

The threshold does not survive a retrain. Dropping two features on one occasion moved the median score from 0.276 to 0.404, which turned 0.98 from a 5.3% flag rate into 9.6% on the same week with no change in what the model was asked to do. The flag rate has to be re-measured after every retrain.

No week has yet been produced by the scheduler. Every result in this document came from a manual run. The DAG, its tests and its deployment path are written and reviewed but have never executed in Composer.

Reviewing a random sample of about 100 companies scoring between 0.90 and 0.99 would convert every precision figure here from an estimate into a measurement. It needs no deployment and can begin immediately.

## Decisions required

| Decision | Basis |
|---|---|
| 1. Set the threshold on review capacity | 0.98 beats 0.99 on precision and raises recall from 32% to 58%. The cost is 659 companies a week instead of 346. |
| 2. Run both models; do not retire Pay General | The two flag sets agree on 7.4%. Pay General raised 180 companies in one week that the gestun model did not, and it covers fraud the gestun model cannot see. |
| 3. Fix the stalled Pay General load | Three weeks unscored, with the report reading no score as not fraud. The downstream patch is written; the load itself needs its owner. |
| 4. Approve the 100-company review sample | The only item that changes what is known rather than what is shipped. A few days of reviewer time. |

For reference, the most recent run covered 1–7 October 2026: 6,821 companies scored, 479 flagged at 7.0%, and 464 placed in the review queue representing Rp 39.2 billion in payments for the week.
