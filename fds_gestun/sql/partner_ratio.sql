-- Extracted from FDS_Gestun_Combined_Features.ipynb.
-- @company_ids : ARRAY<STRING> of companies to build features for.
-- Edit this file, not the notebook: the notebook is exploration, this is the source of truth.

WITH base AS (
  SELECT company_id, lbl AS is_gestun FROM (
    SELECT company_id, MIN(is_gestun) AS lbl, COUNT(DISTINCT is_gestun) AS n_lab
    FROM (SELECT company_id, 0 AS is_gestun
   FROM UNNEST(@company_ids) AS company_id) GROUP BY company_id)
  WHERE n_lab = 1),

rddp AS (
  SELECT company_id,
    COUNT(DISTINCT partner_id) AS cnt_dist_partner,
    COUNT(*)                   AS cnt_all_trx
  FROM `paper-prod.data_mart_layer.rpt__raw_data_digital_payments_daily`
  WHERE payment_status_name = 'PAID'
    AND DATE(transaction_created_datetime) BETWEEN DATE('2026-06-01') AND DATE('2026-07-31')
  GROUP BY company_id)

SELECT b.company_id, b.is_gestun,
  r.cnt_dist_partner, r.cnt_all_trx,
  IEEE_DIVIDE(r.cnt_dist_partner, r.cnt_all_trx) AS pct_dist_partner_of_all_trx
FROM base b LEFT JOIN rddp r USING (company_id)
