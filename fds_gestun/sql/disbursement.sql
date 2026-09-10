-- Extracted from FDS_Gestun_Combined_Features.ipynb.
-- @company_ids : ARRAY<STRING> of companies to build features for.
-- Edit this file, not the notebook: the notebook is exploration, this is the source of truth.

WITH base AS (
  SELECT company_id, lbl AS is_gestun FROM (
    SELECT company_id, MIN(is_gestun) AS lbl, COUNT(DISTINCT is_gestun) AS n_lab
    FROM (SELECT company_id, 0 AS is_gestun
   FROM UNNEST(@company_ids) AS company_id) GROUP BY company_id)
  WHERE n_lab = 1),

-- one row per company x bank x account number; the account NAME is deliberately not in the
-- grouping key, so an account re-registered under a slightly different name stays one account
acct AS (
  SELECT DISTINCT company_id,
    finance_account_bank_name           AS bank,
    finance_account_bank_account_number AS acct_no,
    finance_account_bank_account_name   AS acct_nm
  FROM `paper-prod.data_warehouse_layer.fact__paper__digpay_disbursement_transaction`),

flagged AS (
  SELECT company_id, bank, acct_no,
    MAX(CASE WHEN LOWER(acct_nm) LIKE '%pt %' OR LOWER(acct_nm) LIKE '%pt.%'
              OR LOWER(acct_nm) LIKE '%cv %' OR LOWER(acct_nm) LIKE '%cv.%'
             THEN 1 ELSE 0 END) AS is_ptcv
  FROM acct GROUP BY 1, 2, 3),

agg AS (
  SELECT company_id,
    COUNT(*)                  AS n_disb_accounts,
    COUNT(DISTINCT bank)      AS n_disb_banks,
    MAX(is_ptcv)              AS is_disb_ptcv,
    ROUND(AVG(is_ptcv), 4)    AS pct_disb_account_ptcv
  FROM flagged GROUP BY 1)

SELECT base.company_id, base.is_gestun, agg.* EXCEPT (company_id)
FROM base LEFT JOIN agg USING (company_id)
