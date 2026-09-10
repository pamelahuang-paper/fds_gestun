# FDS Daily Inference — Model & Feature Report
**Source:** `FDS - Daily Inference - Pay General.ipynb`
**Scope:** Digital payment ("Pay General") fraud scoring, paper.id
**Last executed run in notebook:** data window `2026-07-01` → `2026-07-30`, 213,002 transactions
**Report date:** 2026-08-03

---

## 1. Summary

The notebook is a **batch inference job only** — no training occurs. It rebuilds engineered
features from BigQuery, loads pre-trained pickled classifiers from `./artifacts-final/model/`,
scores every transaction, and appends flags to `paper-prod.datawarehouse_dwd.mlfds_ml_labeling`.

Two independent pipelines exist in the same notebook:

| Pipeline | Cells | Models | Threshold | Writes to |
|---|---|---|---|---|
| **Production** | 0–32 | XGBoost + CatBoost | 0.92 | `mlfds_ml_labeling` |
| **Experimental** (`CORAT CORET`) | 33–45 | Random Forest + CatBoost | 0.88 | `mlfds_ml_labeling_roji_temp` |

---

## 2. Models

### 2.1 Inventory

| # | Artifact file | Algorithm | Feature count | Pipeline | Threshold |
|---|---|---|---|---|---|
| 1 | `XGB-TUNED-v1-15Features.p` | `XGBClassifier` (sklearn API) | 15 | Production | 0.92 |
| 2 | `CAT-TUNED-v1-20features.p` | `CatBoostClassifier` | per `feature_names_` (filename says 20; variable named `CAT_10_FEATURE`) | Production | 0.92 |
| 3 | `RF-AUG20082025-v1-2025-fs-rf-25features.p` | `RandomForestClassifier` | 25 | Experimental | 0.88 |
| 4 | `CAT-TUNED-v1-20features.v20082025.p` | `CatBoostClassifier` | 20 | Experimental | 0.88 |

All four are pickles loaded via `load_from_pickle()`. The notebook calls only `predict_proba()`
— no `fit()`, no hyperparameter search, no calibration.

### 2.2 How feature lists are resolved

Feature lists are **not hard-coded in the notebook**. They are read off the pickles at load time:

```python
XGB_15_FEATURE = XGB_MODEL_LATEST_15.feature_names_in_   # sklearn convention
CAT_10_FEATURE = CAT_MODEL_LATEST_10.feature_names_      # CatBoost convention
RF_25_FEATURE  = RF_MODEL_LATEST_25.feature_names_in_
CAT_20_FEATURE = CAT_MODEL_LATEST_20.feature_names_
```

**Consequence:** the authoritative feature contract lives in the artifact files, not in version
control. Reproducing this report exactly requires access to `./artifacts-final/model/`.

### 2.3 Ensemble decision rule

Fraud and non-fraud sets are formed with an **AND** rule across both models:

```python
DATA_FRAUD     = RESULT[(RESULT.xgb_pred == 1) & (RESULT.rf_pred == 1)]
DATA_NON_FRAUD = RESULT[(RESULT.xgb_pred == 0) & (RESULT.rf_pred == 0)]
```

Notes:
- A code comment on the experimental branch reads *"it should be or in the next run"* — an OR
  rule is planned but not active.
- Rows where the two models **disagree** fall into neither set and are dropped from
  `FINAL_RESULT` entirely.
- The BigQuery write actually pushes `RESULT` (all scored rows), not `FINAL_RESULT`, so the
  on-screen table and the stored table are built from different populations.

### 2.4 Naming vs. reality

The BigQuery target schema only has two prediction slots, `rf_pred` and `xgb_pred`, so whichever
model is running gets renamed into a free slot:

| Pipeline | `rf_pred*` column actually holds | `xgb_pred*` column actually holds |
|---|---|---|
| Production | XGBoost | CatBoost |
| Experimental | Random Forest | CatBoost |

In the production path this is compounded by a **tuple-unpacking swap**: `get_result2` returns
`(data, (cat_proba, cat_pred), (xgb_proba, xgb_pred))` but the caller unpacks it as
`data, xgb_, cat_ = ...`. Because both models share the same 0.92 threshold the *counts* are
unaffected, but per-model attribution stored in BigQuery is reversed.

### 2.5 Last recorded run

| Model | Flagged fraud | Non-fraud |
|---|---|---|
| XGBoost | 1,843 | 211,158 |
| CatBoost | 2,958 | 210,043 |

Rows written to `mlfds_ml_labeling`: 182,169 (after `dropna()` from 213,001 scored).

---

## 3. Non-model artifacts used at inference

| Artifact | Type | Role |
|---|---|---|
| `amount_func_aug_2025.xlsx` | 3 interval cutoffs | Bins `amount` into ordinal 0–4 (`AMOUNT_CAT_FUNC`); NaN → 0 |
| `payment_channel_1_func_aug_2025.f` | pickled mapping | Payment channel grouping, level 1 |
| `payment_channel_2_func_aug_2025.f` | pickled mapping | Payment channel grouping, level 2 |
| `final_transform_map` (from `base.py`) | dict of dicts | Ordinal encoding of 7 categorical columns (§5) |

These are frozen alongside the models — changing them without retraining silently shifts the
input distribution.

---

## 4. Feature inventory

Features observed in the notebook, grouped by the fraud signal they encode. Not every feature
here is necessarily consumed by every model — each model selects its own subset via
`feature_names_`.

### 4.1 Velocity / burst behaviour
| Feature | Meaning |
|---|---|
| `num_trx_last_300_minutes` | Transaction count in the trailing 5 hours |
| `num_trx_same_partner_last_30_minutes` | Repeat hits on the same counterparty, 30 min |
| `num_trx_same_amount_last_24_hour` | Identical-amount repeats in 24 h (structuring signal) |
| `sequence_of_mitra_transaction` | Ordinal position of this transaction for the partner |

### 4.2 Timing deltas (account age / rush signals)
| Feature | Meaning |
|---|---|
| `delta_created_registered_in_minutes` | Account creation → registration gap |
| `delta_payment_created_in_hours` | Account creation → this payment |
| `delta_payment_registered_in_hours` | Registration → this payment |
| `delta_payment_firsttrx_in_minutes` | First transaction → this payment |
| `delta_register_firsttrx_minute` | Registration → first transaction |
| `delta_created_mitra_to_payment_in_minutes` | Partner added → payment made |
| `delta_registered_firstkyc_cat` | Bucketed registration → first KYC gap (`categorize_delta_created_firstKyc`) |
| `kyc_date_time_clf` | Time-of-day band when KYC was submitted |

Raw `delta_created_firstkyc` and `delta_register_firstkyc_day` are **dropped** after the bucketed
version is derived.

### 4.3 KYC / identity
| Feature | Meaning |
|---|---|
| `kyc_status_transformed` | Ordinal KYC outcome, −1 → 6 (see §5) |
| `comp_email_phone_verified` | Count of verified channels (0/1/2) |
| `user_owner_name` | Owner name present or `-1` |
| `user_owner_phone` | Phone prefix mapped to telco (`clean_phone_number`) |
| `similarity_category` | 1 if name-similarity check returned *similar* or *suspicious* |
| `comp_kyc_status_phone_email_verified` | Engineered composite (§6) |
| `comp_kyc_status_user_owner_name` | Engineered composite (§6) |

### 4.4 Amount & transaction-history behaviour
| Feature | Meaning |
|---|---|
| `amount` | Payment amount (also binned via `AMOUNT_CAT_FUNC`) |
| `invoice_amount` | Invoice face value |
| `amount_to_invoice_amount` | Ratio; `inf` rows are filtered out before scoring |
| `median_ticket_size_l30d` | Median ticket, 30 d |
| `avg_ticket_size_l30d` | Mean ticket, 30 d |
| `invoice_amount_l30d` | Invoiced value, 30 d |
| `invoice_cnt_l30d` | Invoice count, 30 d |
| `std_invoice_count_l30d` | Std-dev of invoice count, 30 d |
| `success_rate_transaction_l30d` | Payment success rate, 30 d |

### 4.5 Credit-card signals
| Feature | Meaning |
|---|---|
| `payment_attempt_using_cc` | CC used on this attempt |
| `ttl_uniquecc_uses_in_1trx` | Distinct cards tried within one transaction |
| `cnt_uniquecc_at` / `cnt_uniquecc_l7d` / `cnt_uniquecc_l30d` | Distinct cards at time / 7 d / 30 d |
| `cnt_comp_at_ccnum` / `cnt_comp_l7d_ccnum` | Distinct companies sharing a card number |
| `is_cc_match_tokenized_def` | 6-level ordinal: tokenized card vs. current user match (§5) |

### 4.6 Counterparty & company profile
| Feature | Meaning |
|---|---|
| `number_of_mitra` | Registered partner count |
| `is_new_trx_mitra` | First transaction with this partner |
| `is_local_partner` | Domestic vs. foreign counterparty |
| `partner_completeness_detail` | Completeness of partner master data |
| `business_child_cat` | Business sub-category |
| `company_size` | Employee band, ordinal 0–5 (§5) |
| `is_company_state_filled` | Company address/state populated |
| `comp_is_use_invoice_and_itemdesc` | Company fills invoice + item description |
| `is_related_to_blacklisted` | Linked to a blacklisted entity |

### 4.7 Channel
| Feature | Meaning |
|---|---|
| `method_clf` | Payment method class (§5) |
| `payment_ecosystem_cat` | Ecosystem grouping |
| `trx_source_digpay_type` | Transaction origin (§5) |
| `payment_channel_name` | Binned by the two pickled channel functions, then dropped pre-scoring |

### 4.8 Confirmed 10-feature subset

The commented-out PSI-baseline block (cell 22) names an explicit ten — most likely the CatBoost
production feature set:

1. `comp_is_use_invoice_and_itemdesc`
2. `kyc_status_transformed`
3. `method_clf`
4. `delta_created_registered_in_minutes`
5. `payment_ecosystem_cat`
6. `median_ticket_size_l30d`
7. `is_related_to_blacklisted`
8. `num_trx_last_300_minutes`
9. `business_child_cat`
10. `num_trx_same_amount_last_24_hour`

---

## 5. Categorical encoding maps

Captured verbatim from the last run's stdout.

**`method_clf`** — `{-1: 0, credit_card: 1, ecommerce: 2, paper_paylater: 3, transfer_manual: 4}`

**`trx_source_digpay_type`** — `{biller: 0, Open-api: 1, bulk-payment: 2, Pyor: 3, In: 4, Out: 5}`

**`kyc_date_time_clf`** — `{-1: 0, Morning: 1, Noon: 2, Afternoon: 3, Night: 4, Late-Night: 5}`

**`company_size`** — `{-1: 0, 1-15: 1, 16-50: 2, 51-200: 3, 201-500: 4, >500: 5}`
*(observed values in the last run were only `NaN` and `0` — this column is dropped before
scoring in both pipelines.)*

**`user_owner_phone`** — `{N/A/Unknown/Byru: 0, Axis: 1, Flexi: 2, Indosat: 3, Rumah: 4,
Smartfren: 5, Telkom Split Charging: 6, Tri: 7, XL: 8, Telkomsel: 9}`

**`kyc_status_transformed`** — ordered by trust:
`{-1: -1, kyc_tidak_berhasil: 0, belum_validasi: 1, kyc_on_hold: 2, dokumen_kurang_lengkap: 3,
draft: 4, kyc_berhasil_dengancatatankhusus: 5, validasi_berhasil: 6}`

**`is_cc_match_tokenized_def`** — 0 = non-CC payment, ascending to 5 = user equals tokenized user.

---

## 6. Engineered composite features

Both are built with `np.select` and encode an **interaction** the tree models would otherwise
have to learn from scratch.

**`comp_kyc_status_phone_email_verified`** — 9 levels (8 → 0, default −1). Crosses KYC status
(`validasi_berhasil` > `kyc_berhasil_dengancatatankhusus` > other) with the number of verified
contact channels (2 / 1 / 0). Highest = fully verified KYC with both email and phone verified.

**`comp_kyc_status_user_owner_name`** — 12 levels (10 → 0, plus −1). Crosses each KYC status
tier with whether the owner name is populated. `kyc_tidak_berhasil` maps to −1;
`belum_validasi` and missing map to 0.

---

## 7. Features persisted to BigQuery

Only 15 columns pass the whitelist into `mlfds_ml_labeling` — **all cast to string**:

| Group | Columns |
|---|---|
| Key | `external_id` |
| Timing | `delta_created_registered_in_minutes`, `delta_payment_firsttrx_in_minutes`, `delta_payment_created_in_hours`, `delta_payment_registered_in_hours` |
| Risk | `is_related_to_blacklisted`, `kyc_status_transformed`, `similarity_category` |
| Amount | `invoice_amount_l30d` |
| Channel | `payment_ecosystem_cat` |
| Predictions | `rf_pred_proba`, `xgb_pred_proba`, `rf_pred`, `xgb_pred` |
| Audit | `store_date` (today + 7 h, i.e. WIB) |

Most model inputs are therefore **not retained** — limiting post-hoc drift analysis to these ten
features. A separate `current_psi_temp_roji` table (commented out in cell 22) was the intended
PSI monitoring baseline.

Reporting joins add company context from `master_segment_table` and a risk tier derived from
`pprrsk001_2_weeklypoints_1w`: the sum of 11 daily/weekly point columns, bucketed
**Low ≤ 15 / Medium ≤ 30 / High > 30**.

---

## 8. Data-quality caveats affecting the features

1. **Inverted null-fill.** In `get_data()`, categorical/date columns are filled with `-1` while
   *numeric* columns are filled with the string `'None'`. This forces numeric features to object
   dtype and is the reason for the downstream repair layer (`clean_float_column`,
   `_clean_numeric_for_model`, and several bare `try/except … astype(float)` blocks).

2. **Divergent imputation between pipelines.** The production path patches only two columns
   (`success_rate_transaction_l30d`, `amount_to_invoice_amount`) — and does so inside a
   `try/except: pass` that mutates the wrong variable (`data_to_predict` instead of `data`), so it
   silently no-ops. The experimental path's `_clean_numeric_for_model` cleans *all* model features
   and imputes with 0. **The two pipelines therefore feed the models different values for the same
   transaction.**

3. **`inf` handling.** Rows with `amount_to_invoice_amount == inf` are dropped before scoring;
   remaining `±inf` values are mapped to NaN post-prediction only.

4. **Date filter is inert.** `TODAY = '2025-01-01'` against July-2026 data means the
   "score today's transactions" filter scores the entire pulled window. The summary table filters
   `payment_dt.year == 2025` and consequently renders empty.

5. **Duplicate append risk.** Cells 43 and 44 are identical and both call
   `translate_and_push_table(if_save_table=True)`.

---

## 9. Recommendations

| Priority | Item |
|---|---|
| High | Fix the tuple-unpacking swap in the production `get_result2` caller so `xgb_pred` and `rf_pred` reflect the correct models |
| High | Version-control `feature_names_` alongside each pickle — the feature contract currently exists only inside binary artifacts |
| High | Correct the numeric/categorical null-fill inversion at source, then delete the downstream repair layer |
| Medium | Align the two pipelines on one imputation strategy before comparing their outputs |
| Medium | Decide AND vs. OR for the ensemble; currently disagreement rows are silently dropped |
| Medium | Drive `TODAY` from the run date instead of a hard-coded literal |
| Low | Persist the full model input vector (or the PSI baseline table) to enable drift monitoring |
| Low | Remove the duplicated push cells (43/44) |
