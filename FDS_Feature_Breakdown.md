# FDS — Feature Breakdown

Companion to `FDS_Model_and_Feature_Report.md`.
**Source:** `FDS - Daily Inference - Pay General.ipynb` · run window `2026-07-01` → `2026-07-30` · 213,002 transactions

> **Caveat on semantics.** The upstream mart `paper-prod.data_mart_project.mlfds_ft1_final_consolidated`
> and the helper module `base.py` are not available on this machine. Column *names, dtypes, encodings,
> transformations and null counts* below are read directly from the notebook code and its stored outputs
> and are factual. Column *business meaning* is inferred from naming convention where the mart SQL would
> be needed to confirm; those are marked **[inferred]**.

---

## 1. Where features actually come from

This is the single most important structural fact about the feature set: **the notebook computes
almost nothing.** ~95% of features arrive pre-computed from the mart. Only these are built here:

| Feature | Built where | How |
|---|---|---|
| `similarity_category` | Notebook SQL, cell 6 | `CASE WHEN LOWER(similarity_category) IN ('similar','suspicious') THEN 1 ELSE 0` — collapses a multi-class name-similarity verdict into a binary flag |
| `user_owner_phone` | Notebook, cell 17 | `clean_phone_number()` maps raw phone → telco, then ordinal-encoded |
| `delta_created_firstkyc_cat` | Notebook, cell 17 | `categorize_delta_created_firstKyc()` buckets `delta_created_firstkyc`; the raw column is then dropped |
| `comp_kyc_status_phone_email_verified` | Notebook, cell 17 | `np.select`, 9 levels |
| `comp_kyc_status_user_owner_name` | Notebook, cell 17 | `np.select`, 12 levels |
| `amount` bin | Predict-time, `transform_data` | `AMOUNT_CAT_FUNC` → 0–4 via cutoffs from `amount_func_aug_2025.xlsx` |
| `payment_channel_name` bins | Predict-time, `transform_data` | Two pickled mapping functions; raw column dropped before scoring |
| 7 categorical columns | Notebook, cell 17 | Ordinal recoding via `final_transform_map` |

**Implication:** feature logic is owned by the data-mart team, not by this notebook. A change to
`mlfds_ft1_final_consolidated` silently changes model inputs with no signal here.

**Naming trap:** `delta_created_firstkyc_cat` (created in the notebook) and
`delta_registered_firstkyc_cat` (already in the mart) are **different columns** measuring different
gaps — creation→first-KYC vs. registration→first-KYC. They differ by one word and coexist in the
same frame.

---

## 2. Encoding design — two distinct schemes

The 7 mapped categoricals split into two groups with very different modelling properties.

### 2a. Genuinely ordinal (risk-ranked) — the deliberate design

These are ordered so that **higher = more trustworthy**, letting a tree cut the space with a single
threshold split:

| Feature | Scale | Ordering logic |
|---|---|---|
| `kyc_status_transformed` | −1 → 6 | `kyc_tidak_berhasil`(0) < `belum_validasi`(1) < `kyc_on_hold`(2) < `dokumen_kurang_lengkap`(3) < `draft`(4) < `kyc_berhasil_dengancatatankhusus`(5) < `validasi_berhasil`(6) |
| `is_cc_match_tokenized_def` | 0 → 5 | Non-CC(0) → untokenized + user mismatch(1) → … → user = tokenized user(5) |
| `company_size` | 0 → 5 | Unknown(0) → 1-15 → 16-50 → 51-200 → 201-500 → >500 |
| `comp_kyc_status_phone_email_verified` | −1 → 8 | KYC tier × verified-channel count |
| `comp_kyc_status_user_owner_name` | −1 → 10 | KYC tier × owner-name present |

A single split at `kyc_status_transformed >= 5` cleanly isolates "KYC passed" — that's the payoff of
the ordering.

### 2b. Nominal categories given arbitrary integer codes

| Feature | Codes |
|---|---|
| `method_clf` | −1→0, credit_card→1, ecommerce→2, paper_paylater→3, transfer_manual→4 |
| `trx_source_digpay_type` | biller→0, Open-api→1, bulk-payment→2, Pyor→3, In→4, Out→5 |
| `kyc_date_time_clf` | −1→0, Morning→1, Noon→2, Afternoon→3, Night→4, Late-Night→5 |
| `user_owner_phone` | N/A/Unknown/Byru→0, Axis→1, … Telkomsel→9 |

There is no meaningful order here — "ecommerce"(2) is not between "credit_card"(1) and
"paper_paylater"(3) on any risk axis. Trees can still isolate a single category, but it costs
multiple splits instead of one. `kyc_date_time_clf` is a partial exception: it is roughly
chronological, so "Night or later" is expressible as one threshold.

Note `user_owner_phone` collapses three distinct states (`N/A`, `Unknown`, `Byru`) into code 0 —
missing and known-but-unmapped become indistinguishable.

### 2c. CatBoost is not being used as CatBoost

Both CatBoost models receive `.astype(float)` input with no `cat_features` argument. The library's
main advantage — native categorical handling with ordered target statistics — is unused. It is
operating as a plain gradient-boosting model over pre-encoded integers, which makes the
XGB/CatBoost pair far less diverse than the two names suggest.

---

## 3. The families, and what each is meant to catch

### 3.1 Velocity / burst — "is this a machine or a rush?"

| Feature | Window | Fraud pattern targeted **[inferred]** |
|---|---|---|
| `num_trx_last_300_minutes` | 5 h | Bulk cash-out after account takeover |
| `num_trx_same_partner_last_30_minutes` | 30 min | Repeated draining to one beneficiary |
| `num_trx_same_amount_last_24_hour` | 24 h | **Structuring** — splitting one large transfer into identical sub-threshold amounts |
| `sequence_of_mitra_transaction` | lifetime | Position in the partner relationship; value 1 = never transacted before |

These are the highest-signal features in any payment FDS and the most sensitive to windowing bugs
(see §5). `num_trx_same_amount_last_24_hour` is the classic structuring detector and appears in the
confirmed 10-feature CatBoost subset.

### 3.2 Timing deltas — "how fast did this account go from new to moving money?"

Eight measures of the same underlying idea: the compression between account milestones. A
fraudulent account typically registers, skips or rushes KYC, adds a partner, and pays out — all
within minutes. A legitimate business does this over days or weeks.

| Feature | Gap measured | Unit |
|---|---|---|
| `delta_created_registered_in_minutes` | creation → registration | min |
| `delta_payment_created_in_hours` | creation → this payment | h |
| `delta_payment_registered_in_hours` | registration → this payment | h |
| `delta_payment_firsttrx_in_minutes` | first transaction → this payment | min |
| `delta_register_firsttrx_minute` | registration → first transaction | min |
| `delta_created_mitra_to_payment_in_minutes` | partner added → payment | min |
| `delta_registered_firstkyc_cat` | registration → first KYC (**bucketed**, from mart) | ordinal |
| `delta_created_firstkyc_cat` | creation → first KYC (**bucketed**, in notebook) | ordinal |

Note the mixed units (minutes vs. hours) — harmless for trees, but it means coefficients are not
comparable if anyone fits a linear model on these. Also note two of the eight are bucketed and six
are raw; the raw `delta_created_firstkyc` and `delta_register_firstkyc_day` are **dropped** after
bucketing, so their granularity is discarded.

These features are heavily collinear by construction (creation ≤ registration ≤ first trx ≤
payment), which matters for feature-importance interpretation — importance will be split
arbitrarily among near-duplicates.

### 3.3 KYC & identity — "is this who they claim to be?"

| Feature | Type | Signal |
|---|---|---|
| `kyc_status_transformed` | ordinal −1→6 | Core trust anchor; appears in the confirmed 10 |
| `comp_email_phone_verified` | 0/1/2 | Count of verified contact channels |
| `user_owner_name` | present / −1 | Owner name filled |
| `user_owner_phone` | ordinal 0–9 | Telco. **[inferred]** value: prepaid-heavy operators are cheaper to acquire anonymously than postpaid, so operator is a weak proxy for identity cost |
| `similarity_category` | binary | 1 when the payer/beneficiary name-similarity check returned *similar* or *suspicious* |
| `comp_kyc_status_phone_email_verified` | ordinal −1→8 | KYC × contact verification |
| `comp_kyc_status_user_owner_name` | ordinal −1→10 | KYC × name completeness |

`similarity_category` is worth calling out: the upstream `dim_digitalpayment_transaction_namesim_di`
table produces a graded verdict, and this notebook **collapses it to binary**, merging *similar* and
*suspicious* into one class. Whatever separation existed between those two is discarded at ingestion.
It is also a `LEFT JOIN`, so transactions with no name-similarity record score 0 — indistinguishable
from "checked and found clean."

### 3.4 Amount behaviour — "is this transaction normal *for them*?"

| Feature | Type | Role |
|---|---|---|
| `amount` | continuous → binned 0–4 | Raw size, discretised by frozen cutoffs |
| `invoice_amount` | continuous | Invoice face value |
| `amount_to_invoice_amount` | ratio | **Over/underpayment vs. invoice** — a mismatch is the core invoice-fraud signal |
| `median_ticket_size_l30d` | 30 d | Robust baseline; in the confirmed 10 |
| `avg_ticket_size_l30d` | 30 d | Mean baseline (outlier-sensitive) |
| `invoice_amount_l30d` | 30 d | Total invoiced value |
| `invoice_cnt_l30d` | 30 d | Invoice volume |
| `std_invoice_count_l30d` | 30 d | Volatility of invoicing rhythm |
| `success_rate_transaction_l30d` | 30 d | Failure rate — card-testing proxy |

The design intent is clear: absolute amount alone is weak, so the model gets *personalised
baselines* (`median`/`avg_ticket_size_l30d`) to judge deviation against. What is **missing** is the
explicit deviation feature itself — there is no `amount / median_ticket_size_l30d` column. The trees
must learn that interaction from the two raw columns, which is possible but far less efficient than
handing it the ratio directly. Given `amount_to_invoice_amount` was built as an explicit ratio, the
omission looks like an oversight rather than a decision.

`amount` binning uses cutoffs frozen in `amount_func_aug_2025.xlsx`. In an inflationary or
growth environment those thresholds drift out of calibration over time with no alert.

### 3.5 Credit-card signals — card-testing and card-sharing

The densest cluster, and the most specific:

| Feature | Reads as |
|---|---|
| `payment_attempt_using_cc` | Gate — is this even a card payment |
| `ttl_uniquecc_uses_in_1trx` | **Distinct cards tried within one transaction** — near-conclusive card testing when > 2 |
| `cnt_uniquecc_at` / `_l7d` / `_l30d` | Distinct cards per company at now / 7 d / 30 d — the trio gives an acceleration signal, not just a level |
| `cnt_comp_at_ccnum` | **Distinct companies sharing one card number** — one card across many merchants |
| `cnt_comp_l7d_ccnum` | Same, 7 d |
| `is_cc_match_tokenized_def` | 6-level ordinal: does the paying user match the user the card was tokenized under |

The `cnt_comp_*_ccnum` pair inverts the usual perspective — instead of asking "how many cards does
this company use," it asks "how many companies use this card." That catches ring behaviour a
per-company view misses entirely, and is the strongest structural feature in the set.

`is_cc_match_tokenized_def` deserves its 6 levels: it distinguishes *untokenized* from *tokenized
but mismatched*, and further splits on whether the user had >1 transaction in the last 3 — encoding
"new mismatch" vs. "established mismatch."

### 3.6 Counterparty & company profile — static risk context

| Feature | Signal |
|---|---|
| `is_related_to_blacklisted` | Hard blacklist linkage — in the confirmed 10 |
| `number_of_mitra` | Registered partner count |
| `is_new_trx_mitra` | First transaction with this partner |
| `is_local_partner` | Domestic vs. foreign |
| `partner_completeness_detail` | Completeness of partner master data — a proxy for effort invested **[inferred]** |
| `business_child_cat` | Business sub-category; in the confirmed 10 |
| `company_size` | Employee band |
| `is_company_state_filled` | Address populated |
| `comp_is_use_invoice_and_itemdesc` | Does the company fill invoice + item description; in the confirmed 10 |

The completeness-style features (`partner_completeness_detail`, `is_company_state_filled`,
`comp_is_use_invoice_and_itemdesc`) all encode the same latent idea: **fraudsters fill in the
minimum**. Cheap to compute, and legitimately predictive — but also the easiest features in the set
for an adversary to defeat once they know they exist.

`company_size` is dropped before scoring in **both** pipelines
(`.drop(columns='company_size')`), and the last run showed only `NaN` and `0` in it — the column is
effectively dead. Note it is nonetheless still listed in `final_transform_map` and re-encoded every
run.

### 3.7 Channel

| Feature | Note |
|---|---|
| `method_clf` | Payment method class; in the confirmed 10 |
| `payment_ecosystem_cat` | Ecosystem grouping; in the confirmed 10 |
| `trx_source_digpay_type` | Origin: biller / Open-api / bulk-payment / Pyor / In / Out |
| `payment_channel_name` | Binned by two pickled functions, then **dropped** before scoring |

`trx_source_digpay_type` showed `NaN` in the last run's unique values despite being in the mapped
set — the map has no `NaN` key, so unmapped sources become null and then flow into the imputation
layer.

---

## 4. Feature coverage — a material finding

From the post-fill null report (cell 17), every listed feature had **zero** nulls after imputation.
One column did not: **`invoice_id`, with 30,625 nulls out of 213,002 (14.4%)** — transactions with
no backing invoice.

Follow the arithmetic through the pipeline:

```
213,002   rows pulled and feature-engineered
 30,625   rows with null invoice_id  (14.4%)
─────────
182,377   rows with an invoice
182,169   rows actually written to mlfds_ml_labeling
```

The gap between "has an invoice" and "was scored" is 208 rows — **0.1%**. Two filters explain this:
`data_to_predict[data_to_predict.amount_to_invoice_amount != np.inf]` removes rows where
`invoice_amount` is zero or missing (division → `inf`), and `RESULT.dropna()` then removes anything
still carrying a null.

**The strong implication is that invoice-less transactions are being silently excluded from fraud
scoring altogether.** Not scored low — not scored at all. They never enter `RESULT`, so they never
reach the labelling table and never surface for review.

This should be verified by rerunning with row counts logged at each filter (the numbers above are
circumstantial — they line up almost exactly, but `dropna()` drops on *any* null column, so the
populations are not proven identical). If it holds, it is a meaningful blind spot: a payment with no
invoice attached is, on its face, a *more* suspicious object than one with a matching invoice, and
14% of volume is a large surface to leave unscored.

---

## 5. Cross-cutting risks in the feature set

**Trailing-window leakage.** All `*_l7d` / `*_l30d` / `num_trx_last_*` features are trailing
aggregates. This run pulls one query covering 2026-07-01 → 07-30 and scores the whole month at once.
If the mart computes those windows relative to *query time* rather than *transaction time*, then a
July 1 transaction is scored using information from up to 29 days in its future. That would inflate
apparent performance and degrade silently in true daily operation. **Cannot be confirmed without the
mart SQL — this is the first thing to check.**

**Frozen artifacts, drifting data.** `amount_func_aug_2025.xlsx` and the two
`payment_channel_*_func_aug_2025.f` mappings are dated August 2025 and are being applied to
mid-2026 data. Amount cutoffs and channel groupings both drift; nothing in the notebook detects it.
The PSI baseline that would have caught this (`current_psi_temp_roji`, cell 22) is commented out.

**Only 10 of ~45 features are retained.** The BigQuery write whitelists 15 columns, of which 10 are
features. Every velocity feature, every credit-card feature, and both engineered composites are
discarded after scoring — so no retrospective drift analysis or feature-importance validation is
possible on the columns most likely to be doing the work.

**Imputation differs between the two pipelines.** The production path's numeric cleanup targets the
wrong variable inside a bare `try/except: pass` and silently no-ops; the experimental path cleans
all model features and fills with 0. Any comparison of production vs. experimental output is
confounded by this.

**Numeric columns are filled with the string `'None'`.** The null-fill in `get_data()` is inverted —
categorical/date get `-1`, numeric get `'None'` — which forces numeric features to object dtype and
necessitates the entire downstream repair layer. Where that repair fails to reach a column, the
`.astype(float)` at predict time is what surfaces it.

---

## 6. Suggested next steps on the features specifically

| Priority | Action |
|---|---|
| High | Confirm or refute the invoice-less exclusion (§4) — log row counts at each filter |
| High | Verify trailing-window features are computed as-of transaction time, not query time |
| Medium | Add the missing deviation ratio `amount / median_ticket_size_l30d` |
| Medium | Recalibrate the Aug-2025 amount cutoffs and channel maps against 2026 volume |
| Medium | Preserve the graded name-similarity verdict instead of collapsing to binary; distinguish "no similarity record" from "clean" |
| Medium | Pass `cat_features` to CatBoost so the two ensemble members are genuinely diverse |
| Low | Drop `company_size` from `final_transform_map` — it is dead and re-encoded every run |
| Low | Rename `delta_created_firstkyc_cat` / `delta_registered_firstkyc_cat` to be distinguishable |
| Low | Persist the full input vector (or restore the PSI baseline table) to enable drift monitoring |
