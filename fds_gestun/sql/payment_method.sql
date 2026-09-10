-- Extracted from FDS_Gestun_Combined_Features.ipynb.
-- @company_ids : ARRAY<STRING> of companies to build features for.
-- Edit this file, not the notebook: the notebook is exploration, this is the source of truth.

WITH labels AS (SELECT company_id FROM UNNEST(@company_ids) AS company_id),
tx AS (
  SELECT t.company_id, UPPER(IFNULL(t.payment_method_name, 'NA')) AS pm,
         t.transaction_grand_total_amount AS amt
  FROM `paper-prod.data_warehouse_layer.fact__paper__digital_payment_transaction` t
  JOIN labels USING (company_id)
)
SELECT company_id, COUNT(*) AS n_txns,
  ROUND(AVG(CAST(pm = 'CREDIT_CARD' AS INT64)), 4)                          AS cc_txn_share,
  ROUND(SAFE_DIVIDE(SUM(IF(pm = 'CREDIT_CARD', amt, 0)), SUM(amt)), 4)      AS cc_amount_share,
  ROUND(AVG(CAST(pm = 'MITRA_PEMBAYARAN_DIGITAL' AS INT64)), 4)             AS mitra_txn_share,
  ROUND(AVG(CAST(pm = 'BANK_TRANSFER' AS INT64)), 4)                        AS bank_txn_share,
  ROUND(AVG(CAST(pm = 'QRIS' AS INT64)), 4)                                 AS qris_txn_share,
  ROUND(AVG(CAST(pm = 'EWALLET' AS INT64)), 4)                              AS ewallet_txn_share,
  COUNT(DISTINCT pm)                                                        AS n_payment_methods,
  ROUND(SAFE_DIVIDE(SUM(amt), COUNT(*)), 0)                                 AS avg_txn_amount
FROM tx GROUP BY 1
