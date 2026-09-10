-- =============================================================================
-- PPC / PHC Billing Schedule — Before vs After Write-Off
-- Converted from Metabase to native BigQuery. Snapshot: 2026-08-01
--
-- Changes from the Metabase original:
--   1. [[AND x = {{param}}]] optional filters  ->  DECLARE variables + IS NULL guards
--   2. Nested WITH inside each CTE             ->  one flat CTE chain (shared lookups
--                                                  defined once instead of twice)
--   3. Date filter                             ->  DECLARE snapshot_date + date_mode
--      (the original's `-- where full_date = current_date()` does NOT work here:
--       fact__financial_service_pioneer_horizon_billing_schedule has no full_date
--       column. That comment was left over from the older ppc_billing_schedule
--       table. See NOTE 1 — confirm which date column you actually want.)
--   4. Dead CTE `raw_final` in the after-WO block removed (defined, never referenced)
--   5. Unqualified `max_current_dpd` / `adjust_marcel_primary` / `model_rank`
--      explicitly qualified to their source alias
--
-- Set the variables below; nothing else needs editing.
-- =============================================================================

DECLARE snapshot_date         DATE   DEFAULT DATE '2026-08-01';
-- NOTE 1: how snapshot_date is applied. The table has no snapshot/full_date column,
--   so the only date to filter on is due_date (the installment date).
--     'due_date_exact' -> only installments due ON 2026-08-01
--     'due_date_upto'  -> all installments due ON OR BEFORE 2026-08-01  (portfolio position)
--     'none'           -> no date filter at all (matches the original Metabase behaviour)
DECLARE date_mode             STRING DEFAULT 'due_date_exact';
DECLARE filter_product_type   STRING DEFAULT 'PPC';  -- 'PPC' | 'PHC' | NULL = both
DECLARE filter_write_off_type STRING DEFAULT NULL;   -- 'Before Write Off' | 'After Write Off' | NULL = both
DECLARE filter_loan_id        STRING DEFAULT NULL;   -- NULL = no filter
DECLARE filter_company_id     STRING DEFAULT NULL;   -- NULL = no filter


WITH
-- ---------- shared lookups (were duplicated across both WO blocks) ----------
attribution_team AS (
  SELECT
    company_id,
    current_attribution_team_group,
    current_attribution_name
  FROM `paper-prod.data_mart_layer.rpt__companies_attribution_daily`
  -- NOTE 3: if this table is one row per company PER DAY, uncomment to take the
  -- latest attribution only and avoid a row fan-out on every join below:
  -- QUALIFY ROW_NUMBER() OVER (PARTITION BY company_id ORDER BY <date_col> DESC) = 1
),

vlookup_risk_model AS (
  SELECT
    company_id,
    is_generated_by,
    model_rank
  FROM `paper-prod.datawarehouse_ingestion.ing_user_financing_all_testing_conso_di_rev1`
  -- NOTE 3: same fan-out risk if company_id is not unique here:
  -- QUALIFY ROW_NUMBER() OVER (PARTITION BY company_id ORDER BY <date_col> DESC) = 1
),

vlookup_others AS (
  SELECT DISTINCT
    t0.company_id,
    COALESCE(
      t0.adjust_marcel_primary,
      CASE
        WHEN t0.company_id = '272ca006-a34e-4ff9-b4f4-380fb926a9fd' THEN 'testing'
        WHEN t0.company_id = 'f976334f-f71f-407c-b4b9-12940891935f' THEN 'multiple company'
      END
    ) AS adjust_marcel_primary
  FROM `paper-prod.data_warehouse_static_layer.dim__financial_service__tracker_vcc_3` t0
  WHERE t0.company_id NOT IN (
    SELECT company_id
    FROM vlookup_risk_model
    WHERE company_id IS NOT NULL   -- CHANGED: guards NOT IN against a NULL in the
                                   -- subquery, which would silently return zero rows
  )
  QUALIFY ROW_NUMBER() OVER (PARTITION BY t0.company_id ORDER BY t0.flag_date ASC) = 1
),

-- ---------- billing schedule: ALL installments (no date filter) ----------
-- max_current_dpd must be computed across every installment of a loan, exactly as
-- the original did. If it were computed from the date-filtered set below, then with
-- date_mode='due_date_exact' it would collapse to that single installment's DPD.
billing_ppc_all AS (
  SELECT *
  FROM `paper-prod.datascience_public.fact__financial_service_pioneer_horizon_billing_schedule`
  WHERE type_vcc = 'PVC'
    AND company_id != 'aadba827-aa04-435c-86c3-a4a32957aeb5'
    AND (filter_loan_id    IS NULL OR loan_id    = filter_loan_id)
    AND (filter_company_id IS NULL OR company_id = filter_company_id)
),

billing_phc_all AS (
  SELECT *
  FROM `paper-prod.datascience_public.fact__financial_service_pioneer_horizon_billing_schedule`
  WHERE type_vcc IN ('PVCC Credit', 'PVCC Prepaid')
    AND company_id != 'aadba827-aa04-435c-86c3-a4a32957aeb5'
    AND (filter_loan_id    IS NULL OR loan_id    = filter_loan_id)
    AND (filter_company_id IS NULL OR company_id = filter_company_id)
),

-- ---------- worst DPD per loan, across ALL installments ----------
max_dpd_ppc_before AS (
  SELECT loan_id, company_id, MAX(current_dpd) AS max_current_dpd
  FROM billing_ppc_all GROUP BY 1, 2
),
max_dpd_ppc_after AS (
  SELECT loan_id, company_id, MAX(current_dpd_after_wo) AS max_current_dpd
  FROM billing_ppc_all GROUP BY 1, 2
),
max_dpd_phc_before AS (
  SELECT loan_id, company_id, MAX(current_dpd) AS max_current_dpd
  FROM billing_phc_all GROUP BY 1, 2
),
max_dpd_phc_after AS (
  SELECT loan_id, company_id, MAX(current_dpd_after_wo) AS max_current_dpd
  FROM billing_phc_all GROUP BY 1, 2
),

-- ---------- rows actually reported: restricted to the requested date ----------
billing_ppc AS (
  SELECT * FROM billing_ppc_all
  WHERE (   (date_mode = 'due_date_exact' AND CAST(due_date AS DATE) =  snapshot_date)
         OR (date_mode = 'due_date_upto'  AND CAST(due_date AS DATE) <= snapshot_date)
         OR (date_mode = 'none') )
),

billing_phc AS (
  SELECT * FROM billing_phc_all
  WHERE (   (date_mode = 'due_date_exact' AND CAST(due_date AS DATE) =  snapshot_date)
         OR (date_mode = 'due_date_upto'  AND CAST(due_date AS DATE) <= snapshot_date)
         OR (date_mode = 'none') )
),

-- =============================================================================
-- BEFORE WRITE OFF
-- =============================================================================
ppc_before AS (
  SELECT DISTINCT
    due_date,
    'PPC' AS product_type_name,
    company_id,
    loan_id,
    customer_name,
    loan_amount,
    cnt_transaction,
    disbursement_amount,
    repayment_amount,
    expected_penalty_amount,
    due_penalty_amount,
    paid_penalty_amount,
    expected_custom_fee_amount,
    due_custom_fee_amount,
    paid_custom_fee_amount,
    expected_interest_amount,
    due_interest_amount,
    paid_interest_amount,
    outstanding_principal_amount AS total_outstanding_principal_amount,
    status,
    history_dpd,
    history_dpd_cat,
    current_dpd,
    current_dpd_cat,
    total_outstanding_amount,
    max_current_dpd,
    max_current_dpd_cat,
    CASE
      WHEN COALESCE(max_current_dpd, 0) = 0                                          THEN "DPD 0"
      WHEN COALESCE(max_current_dpd, 0) BETWEEN 1   AND 8                            THEN "DPD 1-8"
      WHEN COALESCE(max_current_dpd, 0) > 8   AND COALESCE(max_current_dpd, 0) <= 30 THEN "DPD 9-30"
      WHEN COALESCE(max_current_dpd, 0) > 30  AND COALESCE(max_current_dpd, 0) <= 60 THEN "DPD 31-60"
      WHEN COALESCE(max_current_dpd, 0) > 60  AND COALESCE(max_current_dpd, 0) <= 90 THEN "DPD 61-90"
      WHEN COALESCE(max_current_dpd, 0) > 90  AND COALESCE(max_current_dpd, 0) <= 120 THEN "DPD 91-120"
      WHEN COALESCE(max_current_dpd, 0) > 120 AND COALESCE(max_current_dpd, 0) <= 150 THEN "DPD 121-150"
      WHEN COALESCE(max_current_dpd, 0) > 150 AND COALESCE(max_current_dpd, 0) <= 180 THEN "DPD 151-180"
      WHEN COALESCE(max_current_dpd, 0) > 180                                        THEN "DPD 180+"
    END AS max_current_dpd_cat_okr,
    attribution,
    `model`,
    `rank`,
    other_attribution,
    current_attribution_team_group,
    current_attribution_name
  FROM (
    SELECT DISTINCT
      t0.*,
      t0.outstanding_amount + t0.due_penalty_amount + t0.due_custom_fee_amount + t0.due_interest_amount
        AS total_outstanding_amount,   -- NOTE 4: PPC uses outstanding_amount, PHC uses outstanding_principal_amount
      t1.max_current_dpd,
      CASE
        WHEN COALESCE(t1.max_current_dpd, 0) = 0                                             THEN "DPD 0"
        WHEN COALESCE(t1.max_current_dpd, 0) BETWEEN 1  AND 30                               THEN "DPD 1-30"
        WHEN COALESCE(t1.max_current_dpd, 0) > 30  AND COALESCE(t1.max_current_dpd, 0) <= 60 THEN "DPD 31-60"
        WHEN COALESCE(t1.max_current_dpd, 0) > 60  AND COALESCE(t1.max_current_dpd, 0) <= 90 THEN "DPD 61-90"
        WHEN COALESCE(t1.max_current_dpd, 0) > 90  AND COALESCE(t1.max_current_dpd, 0) <= 120 THEN "DPD 91-120"
        WHEN COALESCE(t1.max_current_dpd, 0) > 120 AND COALESCE(t1.max_current_dpd, 0) <= 150 THEN "DPD 121-150"
        WHEN COALESCE(t1.max_current_dpd, 0) > 150 AND COALESCE(t1.max_current_dpd, 0) <= 180 THEN "DPD 151-180"
        WHEN COALESCE(t1.max_current_dpd, 0) > 180                                           THEN "DPD 180+"
      END AS max_current_dpd_cat,
      CASE
        WHEN t0.company_id IN (SELECT company_id FROM vlookup_risk_model) THEN 'Model'
        ELSE 'Others'
      END AS attribution,
      CASE
        WHEN t0.company_id IN (SELECT company_id FROM vlookup_risk_model)
             AND LOWER(t2.is_generated_by)  = 'marcel' THEN '2L'
        WHEN t0.company_id IN (SELECT company_id FROM vlookup_risk_model)
             AND LOWER(t2.is_generated_by) != 'marcel' THEN 'MPT'
        ELSE 'Others'
      END AS `model`,
      COALESCE(t2.model_rank, 'Others') AS `rank`,
      CASE
        WHEN t0.company_id IN (SELECT company_id FROM vlookup_others) THEN t4.adjust_marcel_primary
        ELSE 'Model'
      END AS other_attribution,
      t3.current_attribution_team_group,
      t3.current_attribution_name
    FROM billing_ppc t0
    LEFT JOIN max_dpd_ppc_before t1 ON t0.loan_id = t1.loan_id AND t0.company_id = t1.company_id
    LEFT JOIN vlookup_risk_model t2 ON t0.company_id = t2.company_id
    LEFT JOIN attribution_team   t3 ON t0.company_id = t3.company_id
    LEFT JOIN vlookup_others     t4 ON t0.company_id = t4.company_id
  )
),

phc_before AS (
  SELECT DISTINCT
    due_date,
    CASE
      WHEN type_vcc = 'PVCC Prepaid' THEN 'PHC Prepaid'
      WHEN type_vcc = 'PVCC Credit'  THEN 'PHC Credit'
    END AS product_type_name,
    company_id,
    loan_id,
    customer_name,
    loan_amount,
    cnt_transaction,
    disbursement_amount,
    repayment_amount,
    expected_penalty_amount,
    due_penalty_amount,
    paid_penalty_amount,
    expected_custom_fee_amount,
    due_custom_fee_amount,
    paid_custom_fee_amount,
    expected_interest_amount,
    due_interest_amount,
    paid_interest_amount,
    outstanding_principal_amount AS total_outstanding_principal_amount,
    status,
    history_dpd,
    history_dpd_cat,
    current_dpd,
    current_dpd_cat,
    total_outstanding_amount,
    max_current_dpd,
    max_current_dpd_cat,
    CASE
      WHEN COALESCE(max_current_dpd, 0) = 0                                          THEN "DPD 0"
      WHEN COALESCE(max_current_dpd, 0) BETWEEN 1   AND 8                            THEN "DPD 1-8"
      WHEN COALESCE(max_current_dpd, 0) > 8   AND COALESCE(max_current_dpd, 0) <= 30 THEN "DPD 9-30"
      WHEN COALESCE(max_current_dpd, 0) > 30  AND COALESCE(max_current_dpd, 0) <= 60 THEN "DPD 31-60"
      WHEN COALESCE(max_current_dpd, 0) > 60  AND COALESCE(max_current_dpd, 0) <= 90 THEN "DPD 61-90"
      WHEN COALESCE(max_current_dpd, 0) > 90  AND COALESCE(max_current_dpd, 0) <= 120 THEN "DPD 91-120"
      WHEN COALESCE(max_current_dpd, 0) > 120 AND COALESCE(max_current_dpd, 0) <= 150 THEN "DPD 121-150"
      WHEN COALESCE(max_current_dpd, 0) > 150 AND COALESCE(max_current_dpd, 0) <= 180 THEN "DPD 151-180"
      WHEN COALESCE(max_current_dpd, 0) > 180                                        THEN "DPD 180+"
    END AS max_current_dpd_cat_okr,
    CAST(NULL AS STRING) AS attribution,
    CAST(NULL AS STRING) AS `model`,
    CAST(NULL AS STRING) AS `rank`,
    CAST(NULL AS STRING) AS other_attribution,
    current_attribution_team_group,
    current_attribution_name
  FROM (
    SELECT DISTINCT
      t0.*,
      t0.outstanding_principal_amount + t0.due_custom_fee_amount + t0.due_interest_amount + t0.due_penalty_amount
        AS total_outstanding_amount,
      t1.max_current_dpd,
      CASE
        WHEN COALESCE(t1.max_current_dpd, 0) = 0                                             THEN "DPD 0"
        WHEN COALESCE(t1.max_current_dpd, 0) BETWEEN 1  AND 30                               THEN "DPD 1-30"
        WHEN COALESCE(t1.max_current_dpd, 0) > 30  AND COALESCE(t1.max_current_dpd, 0) <= 60 THEN "DPD 31-60"
        WHEN COALESCE(t1.max_current_dpd, 0) > 60  AND COALESCE(t1.max_current_dpd, 0) <= 90 THEN "DPD 61-90"
        WHEN COALESCE(t1.max_current_dpd, 0) > 90  AND COALESCE(t1.max_current_dpd, 0) <= 120 THEN "DPD 91-120"
        WHEN COALESCE(t1.max_current_dpd, 0) > 120 AND COALESCE(t1.max_current_dpd, 0) <= 150 THEN "DPD 121-150"
        WHEN COALESCE(t1.max_current_dpd, 0) > 150 AND COALESCE(t1.max_current_dpd, 0) <= 180 THEN "DPD 151-180"
        WHEN COALESCE(t1.max_current_dpd, 0) > 180                                           THEN "DPD 180+"
      END AS max_current_dpd_cat,
      t3.current_attribution_team_group,
      t3.current_attribution_name
    FROM billing_phc t0
    LEFT JOIN max_dpd_phc_before t1 ON t0.loan_id = t1.loan_id AND t0.company_id = t1.company_id
    LEFT JOIN attribution_team   t3 ON t0.company_id = t3.company_id
  )
),

-- =============================================================================
-- AFTER WRITE OFF
-- =============================================================================
ppc_after AS (
  SELECT DISTINCT
    due_date,
    'PPC' AS product_type_name,
    company_id,
    loan_id,
    customer_name,
    loan_amount,
    cnt_transaction,
    disbursement_amount,
    repayment_amount,
    expected_penalty_amount,
    current_due_penalty_amount_after_wo AS due_penalty_amount,
    paid_penalty_amount,
    expected_custom_fee_amount,
    due_custom_fee_amount,
    paid_custom_fee_amount,
    expected_interest_amount,
    current_due_interest_amount_after_wo AS due_interest_amount,
    paid_interest_amount,
    current_total_outstanding_principal_amount_after_wo AS total_outstanding_principal_amount,
    COALESCE(status_after_wo, status) AS status,
    IFNULL(latest_dpd_wo, history_dpd) AS history_dpd,
    CASE
      WHEN COALESCE(latest_dpd_wo, history_dpd, 0) = 0                                                   THEN "DPD 0"
      WHEN COALESCE(latest_dpd_wo, history_dpd, 0) BETWEEN 1  AND 8                                      THEN "DPD 1-8"
      WHEN COALESCE(latest_dpd_wo, history_dpd, 0) > 8   AND COALESCE(latest_dpd_wo, history_dpd, 0) <= 30  THEN "DPD 9-30"
      WHEN COALESCE(latest_dpd_wo, history_dpd, 0) > 30  AND COALESCE(latest_dpd_wo, history_dpd, 0) <= 60  THEN "DPD 31-60"
      WHEN COALESCE(latest_dpd_wo, history_dpd, 0) > 60  AND COALESCE(latest_dpd_wo, history_dpd, 0) <= 90  THEN "DPD 61-90"
      WHEN COALESCE(latest_dpd_wo, history_dpd, 0) > 90  AND COALESCE(latest_dpd_wo, history_dpd, 0) <= 120 THEN "DPD 91-120"
      WHEN COALESCE(latest_dpd_wo, history_dpd, 0) > 120 AND COALESCE(latest_dpd_wo, history_dpd, 0) <= 150 THEN "DPD 121-150"
      WHEN COALESCE(latest_dpd_wo, history_dpd, 0) > 150 AND COALESCE(latest_dpd_wo, history_dpd, 0) <= 180 THEN "DPD 151-180"
      WHEN COALESCE(latest_dpd_wo, history_dpd, 0) > 180                                                 THEN "DPD 180+"
    END AS history_dpd_cat,
    current_dpd_after_wo AS current_dpd,
    CASE
      WHEN COALESCE(current_dpd_after_wo, 0) = 0                                              THEN "DPD 0"
      WHEN COALESCE(current_dpd_after_wo, 0) BETWEEN 1   AND 8                                THEN "DPD 1-8"
      WHEN COALESCE(current_dpd_after_wo, 0) > 8   AND COALESCE(current_dpd_after_wo, 0) <= 30 THEN "DPD 9-30"
      WHEN COALESCE(current_dpd_after_wo, 0) > 30  AND COALESCE(current_dpd_after_wo, 0) <= 60 THEN "DPD 31-60"
      WHEN COALESCE(current_dpd_after_wo, 0) > 60  AND COALESCE(current_dpd_after_wo, 0) <= 90 THEN "DPD 61-90"
      WHEN COALESCE(current_dpd_after_wo, 0) > 90  AND COALESCE(current_dpd_after_wo, 0) <= 120 THEN "DPD 91-120"
      WHEN COALESCE(current_dpd_after_wo, 0) > 120 AND COALESCE(current_dpd_after_wo, 0) <= 150 THEN "DPD 121-150"
      WHEN COALESCE(current_dpd_after_wo, 0) > 150 AND COALESCE(current_dpd_after_wo, 0) <= 180 THEN "DPD 151-180"
      WHEN COALESCE(current_dpd_after_wo, 0) > 180                                            THEN "DPD 180+"
    END AS current_dpd_cat,
    total_outstanding_amount,
    max_current_dpd,
    max_current_dpd_cat,
    CASE
      WHEN COALESCE(max_current_dpd, 0) = 0                                          THEN "DPD 0"
      WHEN COALESCE(max_current_dpd, 0) BETWEEN 1   AND 8                            THEN "DPD 1-8"
      WHEN COALESCE(max_current_dpd, 0) > 8   AND COALESCE(max_current_dpd, 0) <= 30 THEN "DPD 9-30"
      WHEN COALESCE(max_current_dpd, 0) > 30  AND COALESCE(max_current_dpd, 0) <= 60 THEN "DPD 31-60"
      WHEN COALESCE(max_current_dpd, 0) > 60  AND COALESCE(max_current_dpd, 0) <= 90 THEN "DPD 61-90"
      WHEN COALESCE(max_current_dpd, 0) > 90  AND COALESCE(max_current_dpd, 0) <= 120 THEN "DPD 91-120"
      WHEN COALESCE(max_current_dpd, 0) > 120 AND COALESCE(max_current_dpd, 0) <= 150 THEN "DPD 121-150"
      WHEN COALESCE(max_current_dpd, 0) > 150 AND COALESCE(max_current_dpd, 0) <= 180 THEN "DPD 151-180"
      WHEN COALESCE(max_current_dpd, 0) > 180                                        THEN "DPD 180+"
    END AS max_current_dpd_cat_okr,
    attribution,
    `model`,
    `rank`,
    other_attribution,
    current_attribution_team_group,
    current_attribution_name
  FROM (
    SELECT DISTINCT
      t0.*,
      t0.current_total_outstanding_principal_amount_after_wo
        + t0.current_due_penalty_amount_after_wo
        + t0.due_custom_fee_amount
        + t0.current_due_interest_amount_after_wo AS total_outstanding_amount,
      t1.max_current_dpd,
      CASE
        WHEN COALESCE(t1.max_current_dpd, 0) = 0                                             THEN "DPD 0"
        WHEN COALESCE(t1.max_current_dpd, 0) BETWEEN 1  AND 30                               THEN "DPD 1-30"
        WHEN COALESCE(t1.max_current_dpd, 0) > 30  AND COALESCE(t1.max_current_dpd, 0) <= 60 THEN "DPD 31-60"
        WHEN COALESCE(t1.max_current_dpd, 0) > 60  AND COALESCE(t1.max_current_dpd, 0) <= 90 THEN "DPD 61-90"
        WHEN COALESCE(t1.max_current_dpd, 0) > 90  AND COALESCE(t1.max_current_dpd, 0) <= 120 THEN "DPD 91-120"
        WHEN COALESCE(t1.max_current_dpd, 0) > 120 AND COALESCE(t1.max_current_dpd, 0) <= 150 THEN "DPD 121-150"
        WHEN COALESCE(t1.max_current_dpd, 0) > 150 AND COALESCE(t1.max_current_dpd, 0) <= 180 THEN "DPD 151-180"
        WHEN COALESCE(t1.max_current_dpd, 0) > 180                                           THEN "DPD 180+"
      END AS max_current_dpd_cat,
      CASE
        WHEN t0.company_id IN (SELECT company_id FROM vlookup_risk_model) THEN 'Model'
        ELSE 'Others'
      END AS attribution,
      CASE
        WHEN t0.company_id IN (SELECT company_id FROM vlookup_risk_model)
             AND LOWER(t2.is_generated_by)  = 'marcel' THEN '2L'
        WHEN t0.company_id IN (SELECT company_id FROM vlookup_risk_model)
             AND LOWER(t2.is_generated_by) != 'marcel' THEN 'MPT'
        ELSE 'Others'
      END AS `model`,
      COALESCE(t2.model_rank, 'Others') AS `rank`,
      CASE
        WHEN t0.company_id IN (SELECT company_id FROM vlookup_others) THEN t4.adjust_marcel_primary
        ELSE 'Model'
      END AS other_attribution,
      t3.current_attribution_team_group,
      t3.current_attribution_name
    FROM billing_ppc t0
    LEFT JOIN max_dpd_ppc_after  t1 ON t0.loan_id = t1.loan_id AND t0.company_id = t1.company_id
    LEFT JOIN vlookup_risk_model t2 ON t0.company_id = t2.company_id
    LEFT JOIN attribution_team   t3 ON t0.company_id = t3.company_id
    LEFT JOIN vlookup_others     t4 ON t0.company_id = t4.company_id
  )
),

phc_after AS (
  SELECT DISTINCT
    due_date,
    CASE
      WHEN type_vcc = 'PVCC Prepaid' THEN 'PHC Prepaid'
      WHEN type_vcc = 'PVCC Credit'  THEN 'PHC Credit'
    END AS product_type_name,
    company_id,
    loan_id,
    customer_name,
    loan_amount,
    cnt_transaction,
    disbursement_amount,
    repayment_amount,
    expected_penalty_amount,
    current_due_penalty_amount_after_wo AS due_penalty_amount,
    paid_penalty_amount,
    expected_custom_fee_amount,
    due_custom_fee_amount,
    paid_custom_fee_amount,
    expected_interest_amount,
    current_due_interest_amount_after_wo AS due_interest_amount,
    paid_interest_amount,
    current_total_outstanding_principal_amount_after_wo AS total_outstanding_principal_amount,
    COALESCE(status_after_wo, status) AS status,
    IFNULL(latest_dpd_wo, history_dpd) AS history_dpd,
    CASE
      WHEN COALESCE(latest_dpd_wo, history_dpd, 0) = 0                                                   THEN "DPD 0"
      WHEN COALESCE(latest_dpd_wo, history_dpd, 0) BETWEEN 1  AND 8                                      THEN "DPD 1-8"
      WHEN COALESCE(latest_dpd_wo, history_dpd, 0) > 8   AND COALESCE(latest_dpd_wo, history_dpd, 0) <= 30  THEN "DPD 9-30"
      WHEN COALESCE(latest_dpd_wo, history_dpd, 0) > 30  AND COALESCE(latest_dpd_wo, history_dpd, 0) <= 60  THEN "DPD 31-60"
      WHEN COALESCE(latest_dpd_wo, history_dpd, 0) > 60  AND COALESCE(latest_dpd_wo, history_dpd, 0) <= 90  THEN "DPD 61-90"
      WHEN COALESCE(latest_dpd_wo, history_dpd, 0) > 90  AND COALESCE(latest_dpd_wo, history_dpd, 0) <= 120 THEN "DPD 91-120"
      WHEN COALESCE(latest_dpd_wo, history_dpd, 0) > 120 AND COALESCE(latest_dpd_wo, history_dpd, 0) <= 150 THEN "DPD 121-150"
      WHEN COALESCE(latest_dpd_wo, history_dpd, 0) > 150 AND COALESCE(latest_dpd_wo, history_dpd, 0) <= 180 THEN "DPD 151-180"
      WHEN COALESCE(latest_dpd_wo, history_dpd, 0) > 180                                                 THEN "DPD 180+"
    END AS history_dpd_cat,
    current_dpd_after_wo AS current_dpd,
    CASE
      WHEN COALESCE(current_dpd_after_wo, 0) = 0                                              THEN "DPD 0"
      WHEN COALESCE(current_dpd_after_wo, 0) BETWEEN 1   AND 8                                THEN "DPD 1-8"
      WHEN COALESCE(current_dpd_after_wo, 0) > 8   AND COALESCE(current_dpd_after_wo, 0) <= 30 THEN "DPD 9-30"
      WHEN COALESCE(current_dpd_after_wo, 0) > 30  AND COALESCE(current_dpd_after_wo, 0) <= 60 THEN "DPD 31-60"
      WHEN COALESCE(current_dpd_after_wo, 0) > 60  AND COALESCE(current_dpd_after_wo, 0) <= 90 THEN "DPD 61-90"
      WHEN COALESCE(current_dpd_after_wo, 0) > 90  AND COALESCE(current_dpd_after_wo, 0) <= 120 THEN "DPD 91-120"
      WHEN COALESCE(current_dpd_after_wo, 0) > 120 AND COALESCE(current_dpd_after_wo, 0) <= 150 THEN "DPD 121-150"
      WHEN COALESCE(current_dpd_after_wo, 0) > 150 AND COALESCE(current_dpd_after_wo, 0) <= 180 THEN "DPD 151-180"
      WHEN COALESCE(current_dpd_after_wo, 0) > 180                                            THEN "DPD 180+"
    END AS current_dpd_cat,
    total_outstanding_amount,
    max_current_dpd,
    max_current_dpd_cat,
    CASE
      WHEN COALESCE(max_current_dpd, 0) = 0                                          THEN "DPD 0"
      WHEN COALESCE(max_current_dpd, 0) BETWEEN 1   AND 8                            THEN "DPD 1-8"
      WHEN COALESCE(max_current_dpd, 0) > 8   AND COALESCE(max_current_dpd, 0) <= 30 THEN "DPD 9-30"
      WHEN COALESCE(max_current_dpd, 0) > 30  AND COALESCE(max_current_dpd, 0) <= 60 THEN "DPD 31-60"
      WHEN COALESCE(max_current_dpd, 0) > 60  AND COALESCE(max_current_dpd, 0) <= 90 THEN "DPD 61-90"
      WHEN COALESCE(max_current_dpd, 0) > 90  AND COALESCE(max_current_dpd, 0) <= 120 THEN "DPD 91-120"
      WHEN COALESCE(max_current_dpd, 0) > 120 AND COALESCE(max_current_dpd, 0) <= 150 THEN "DPD 121-150"
      WHEN COALESCE(max_current_dpd, 0) > 150 AND COALESCE(max_current_dpd, 0) <= 180 THEN "DPD 151-180"
      WHEN COALESCE(max_current_dpd, 0) > 180                                        THEN "DPD 180+"
    END AS max_current_dpd_cat_okr,
    CAST(NULL AS STRING) AS attribution,
    CAST(NULL AS STRING) AS `model`,
    CAST(NULL AS STRING) AS `rank`,
    CAST(NULL AS STRING) AS other_attribution,
    current_attribution_team_group,
    current_attribution_name
  FROM (
    SELECT DISTINCT
      t0.* EXCEPT(latest_dpd_wo),
      COALESCE(t0.latest_dpd_wo, t0.current_dpd) AS latest_dpd_wo,
      t0.current_total_outstanding_principal_amount_after_wo
        + t0.current_due_penalty_amount_after_wo
        + t0.due_custom_fee_amount
        + t0.current_due_interest_amount_after_wo AS total_outstanding_amount,
      t1.max_current_dpd,
      CASE
        WHEN COALESCE(t1.max_current_dpd, 0) = 0                                             THEN "DPD 0"
        WHEN COALESCE(t1.max_current_dpd, 0) BETWEEN 1  AND 30                               THEN "DPD 1-30"
        WHEN COALESCE(t1.max_current_dpd, 0) > 30  AND COALESCE(t1.max_current_dpd, 0) <= 60 THEN "DPD 31-60"
        WHEN COALESCE(t1.max_current_dpd, 0) > 60  AND COALESCE(t1.max_current_dpd, 0) <= 90 THEN "DPD 61-90"
        WHEN COALESCE(t1.max_current_dpd, 0) > 90  AND COALESCE(t1.max_current_dpd, 0) <= 120 THEN "DPD 91-120"
        WHEN COALESCE(t1.max_current_dpd, 0) > 120 AND COALESCE(t1.max_current_dpd, 0) <= 150 THEN "DPD 121-150"
        WHEN COALESCE(t1.max_current_dpd, 0) > 150 AND COALESCE(t1.max_current_dpd, 0) <= 180 THEN "DPD 151-180"
        WHEN COALESCE(t1.max_current_dpd, 0) > 180                                           THEN "DPD 180+"
      END AS max_current_dpd_cat,
      t3.current_attribution_team_group,
      t3.current_attribution_name
    FROM billing_phc t0
    LEFT JOIN max_dpd_phc_after t1 ON t0.loan_id = t1.loan_id AND t0.company_id = t1.company_id
    LEFT JOIN attribution_team  t3 ON t0.company_id = t3.company_id
  )
),

-- =============================================================================
-- UNION + product roll-up (PHC Credit / PHC Prepaid -> PHC)
-- =============================================================================
final_wo AS (
  SELECT DISTINCT
    'Before Write Off' AS type,
    u.* EXCEPT(product_type_name),
    CASE WHEN u.product_type_name LIKE 'PHC%' THEN 'PHC' ELSE u.product_type_name END AS product_type_name
  FROM (SELECT * FROM ppc_before UNION ALL SELECT * FROM phc_before) u

  UNION ALL

  SELECT DISTINCT
    'After Write Off' AS type,
    u.* EXCEPT(product_type_name),
    CASE WHEN u.product_type_name LIKE 'PHC%' THEN 'PHC' ELSE u.product_type_name END AS product_type_name
  FROM (SELECT * FROM ppc_after UNION ALL SELECT * FROM phc_after) u
)

SELECT *
FROM final_wo
WHERE (filter_product_type   IS NULL OR product_type_name = filter_product_type)
  AND (filter_write_off_type IS NULL OR type              = filter_write_off_type)
ORDER BY product_type_name, company_id, loan_id, due_date, type;
