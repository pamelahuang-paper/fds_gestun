-- Extracted from FDS_Gestun_Combined_Features.ipynb.
-- @company_ids : ARRAY<STRING> of companies to build features for.
-- Edit this file, not the notebook: the notebook is exploration, this is the source of truth.

WITH base AS (SELECT company_id, lbl AS is_gestun FROM (
      SELECT company_id, MIN(is_gestun) AS lbl, COUNT(DISTINCT is_gestun) AS n_lab
      FROM (SELECT company_id, 0 AS is_gestun
   FROM UNNEST(@company_ids) AS company_id) GROUP BY company_id) WHERE n_lab = 1),
rddp AS (SELECT * FROM `paper-prod.data_mart_layer.rpt__raw_data_digital_payments_daily`
         WHERE payment_status_name = 'PAID'),
last_trx AS (SELECT company_id, MAX(transaction_created_datetime) AS last_trx_datetime FROM rddp GROUP BY company_id),
partner_stats_last_24h AS (
  SELECT l.company_id, COUNT(DISTINCT r.partner_id) AS num_partner_last_24h,
    COUNT(*) AS num_trx_last_24h_partner, SUM(r.transaction_amount) AS total_amount_last_24h_partner
  FROM last_trx l JOIN rddp r ON l.company_id=r.company_id
   AND r.transaction_created_datetime BETWEEN DATETIME_SUB(l.last_trx_datetime, INTERVAL 24 HOUR) AND l.last_trx_datetime
  GROUP BY l.company_id),
partner_stats_last_7d AS (
  SELECT l.company_id, COUNT(DISTINCT r.partner_id) AS num_partner_last_7d,
    COUNT(*) AS num_trx_last_7d_partner, SUM(r.transaction_amount) AS total_amount_last_7d_partner
  FROM last_trx l JOIN rddp r ON l.company_id=r.company_id
   AND r.transaction_created_datetime BETWEEN DATETIME_SUB(l.last_trx_datetime, INTERVAL 7 DAY) AND l.last_trx_datetime
  GROUP BY l.company_id),
partner_stats_last_30d AS (
  SELECT l.company_id, COUNT(DISTINCT r.partner_id) AS num_partner_last_30d,
    COUNT(*) AS num_trx_last_30d_partner, SUM(r.transaction_amount) AS total_amount_last_30d_partner
  FROM last_trx l JOIN rddp r ON l.company_id=r.company_id
   AND r.transaction_created_datetime BETWEEN DATETIME_SUB(l.last_trx_datetime, INTERVAL 30 DAY) AND l.last_trx_datetime
  GROUP BY l.company_id),
partner_stats_prev_7d AS (
  SELECT l.company_id, COUNT(DISTINCT r.partner_id) AS num_partner_prev_7d,
    COUNT(*) AS num_trx_prev_7d_partner, SUM(r.transaction_amount) AS total_amount_prev_7d_partner
  FROM last_trx l JOIN rddp r ON l.company_id=r.company_id
   AND r.transaction_created_datetime >= DATETIME_SUB(l.last_trx_datetime, INTERVAL 8 DAY)
   AND r.transaction_created_datetime <  DATETIME_SUB(l.last_trx_datetime, INTERVAL 24 HOUR)
  GROUP BY l.company_id),
partner_stats_prev_30d AS (
  SELECT l.company_id, COUNT(DISTINCT r.partner_id) AS num_partner_prev_30d,
    COUNT(*) AS num_trx_prev_30d_partner, SUM(r.transaction_amount) AS total_amount_prev_30d_partner
  FROM last_trx l JOIN rddp r ON l.company_id=r.company_id
   AND r.transaction_created_datetime >= DATETIME_SUB(l.last_trx_datetime, INTERVAL 31 DAY)
   AND r.transaction_created_datetime <  DATETIME_SUB(l.last_trx_datetime, INTERVAL 24 HOUR)
  GROUP BY l.company_id)
SELECT b.company_id, b.is_gestun,
  COALESCE(p24.num_partner_last_24h,0)  AS num_partner_last_24h,
  COALESCE(p7.num_partner_last_7d,0)    AS num_partner_last_7d,
  COALESCE(p30.num_partner_last_30d,0)  AS num_partner_last_30d,
  COALESCE(pp7.num_partner_prev_7d,0)   AS num_partner_prev_7d,
  COALESCE(pp30.num_partner_prev_30d,0) AS num_partner_prev_30d,
  SAFE_DIVIDE(p24.num_partner_last_24h, pp7.num_partner_prev_7d/7.0)   AS partner_ratio_24h_vs_prev7d,
  SAFE_DIVIDE(p24.num_partner_last_24h, pp30.num_partner_prev_30d/30.0) AS partner_ratio_24h_vs_prev30d,
  SAFE_DIVIDE(p24.num_trx_last_24h_partner, p24.num_partner_last_24h)   AS trx_per_partner_last_24h,
  SAFE_DIVIDE(p24.total_amount_last_24h_partner, p24.num_partner_last_24h) AS amount_per_partner_last_24h,
  SAFE_DIVIDE(p30.num_trx_last_30d_partner, p30.num_partner_last_30d)   AS trx_per_partner_last_30d,
  SAFE_DIVIDE(p30.total_amount_last_30d_partner, p30.num_partner_last_30d) AS amount_per_partner_last_30d,
  SAFE_DIVIDE(p24.num_partner_last_24h, p30.num_partner_last_30d)       AS partner_novelty_ratio_24h_vs_30d,
  SAFE_DIVIDE(p24.num_partner_last_24h, p7.num_partner_last_7d)         AS partner_novelty_ratio_24h_vs_7d
FROM base b
LEFT JOIN partner_stats_last_24h p24  USING (company_id)
LEFT JOIN partner_stats_last_7d   p7  USING (company_id)
LEFT JOIN partner_stats_last_30d  p30 USING (company_id)
LEFT JOIN partner_stats_prev_7d   pp7 USING (company_id)
LEFT JOIN partner_stats_prev_30d  pp30 USING (company_id)
