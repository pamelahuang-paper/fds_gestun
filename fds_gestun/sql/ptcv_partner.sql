-- Extracted from FDS_Gestun_Combined_Features.ipynb.
-- @company_ids : ARRAY<STRING> of companies to build features for.
-- Edit this file, not the notebook: the notebook is exploration, this is the source of truth.

WITH t AS (
  SELECT company_id, partner_id, partner_name, transaction_amount AS amt
  FROM `paper-prod.data_mart_layer.rpt__raw_data_digital_payments_daily`
  WHERE payment_status_name = 'PAID'
    AND company_id IN UNNEST(@company_ids)
    AND partner_name IS NOT NULL AND TRIM(partner_name) != ''),
f AS (
  SELECT company_id, partner_id, amt,
    -- word-boundary anchored: a plain LIKE '%pt %' also fires on "concePT " and "APT."
    CAST(REGEXP_CONTAINS(LOWER(partner_name),
      r'(^|[^a-z])(pt|cv|ud|pd|tbk|persero|firma|koperasi|yayasan)([^a-z]|$)') AS INT64) AS is_ptcv
  FROM t),
per_partner AS (
  SELECT company_id, partner_id, MAX(is_ptcv) AS is_ptcv,
         COUNT(*) AS n_txn, SUM(amt) AS amt
  FROM f GROUP BY 1, 2)
SELECT company_id,
  ROUND(AVG(is_ptcv), 4)                                  AS pct_partner_is_ptcv,
  ROUND(SAFE_DIVIDE(SUM(n_txn * is_ptcv), SUM(n_txn)), 4) AS pct_txn_to_ptcv_partner,
  ROUND(SAFE_DIVIDE(SUM(amt  * is_ptcv), SUM(amt)), 4)    AS pct_amount_to_ptcv_partner,
  SUM(is_ptcv)                                            AS n_ptcv_partners,
  CAST(MAX(is_ptcv) AS INT64)                             AS has_ptcv_partner
FROM per_partner GROUP BY 1
