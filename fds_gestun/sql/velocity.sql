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
trx_stats_last_24h AS (
  SELECT l.company_id, COUNT(*) AS num_trx_last_24h, SUM(r.transaction_amount) AS total_amount_last_24h,
    AVG(r.transaction_amount) AS avg_amount_last_24h,
    APPROX_QUANTILES(r.transaction_amount,2)[OFFSET(1)] AS median_amount_last_24h,
    MIN(r.transaction_amount) AS min_amount_last_24h, MAX(r.transaction_amount) AS max_amount_last_24h
  FROM last_trx l JOIN rddp r ON l.company_id=r.company_id
   AND r.transaction_created_datetime BETWEEN DATETIME_SUB(l.last_trx_datetime, INTERVAL 24 HOUR) AND l.last_trx_datetime
  GROUP BY l.company_id),
trx_stats_last_7d AS (
  SELECT l.company_id, COUNT(*) AS num_trx_last_7d, SUM(r.transaction_amount) AS total_amount_last_7d,
    AVG(r.transaction_amount) AS avg_amount_last_7d,
    APPROX_QUANTILES(r.transaction_amount,2)[OFFSET(1)] AS median_amount_last_7d,
    MIN(r.transaction_amount) AS min_amount_last_7d, MAX(r.transaction_amount) AS max_amount_last_7d
  FROM last_trx l JOIN rddp r ON l.company_id=r.company_id
   AND r.transaction_created_datetime BETWEEN DATETIME_SUB(l.last_trx_datetime, INTERVAL 7 DAY) AND l.last_trx_datetime
  GROUP BY l.company_id),
trx_stats_last_30d AS (
  SELECT l.company_id, COUNT(*) AS num_trx_last_30d, SUM(r.transaction_amount) AS total_amount_last_30d,
    AVG(r.transaction_amount) AS avg_amount_last_30d,
    APPROX_QUANTILES(r.transaction_amount,2)[OFFSET(1)] AS median_amount_last_30d,
    MIN(r.transaction_amount) AS min_amount_last_30d, MAX(r.transaction_amount) AS max_amount_last_30d
  FROM last_trx l JOIN rddp r ON l.company_id=r.company_id
   AND r.transaction_created_datetime BETWEEN DATETIME_SUB(l.last_trx_datetime, INTERVAL 30 DAY) AND l.last_trx_datetime
  GROUP BY l.company_id),
trx_stats_prev_7d AS (
  SELECT l.company_id, COUNT(*) AS num_trx_prev_7d, SUM(r.transaction_amount) AS total_amount_prev_7d,
    AVG(r.transaction_amount) AS avg_amount_prev_7d,
    APPROX_QUANTILES(r.transaction_amount,2)[OFFSET(1)] AS median_amount_prev_7d,
    MIN(r.transaction_amount) AS min_amount_prev_7d, MAX(r.transaction_amount) AS max_amount_prev_7d
  FROM last_trx l JOIN rddp r ON l.company_id=r.company_id
   AND r.transaction_created_datetime >= DATETIME_SUB(l.last_trx_datetime, INTERVAL 8 DAY)
   AND r.transaction_created_datetime <  DATETIME_SUB(l.last_trx_datetime, INTERVAL 24 HOUR)
  GROUP BY l.company_id),
trx_stats_prev_30d AS (
  SELECT l.company_id, COUNT(*) AS num_trx_prev_30d, SUM(r.transaction_amount) AS total_amount_prev_30d,
    AVG(r.transaction_amount) AS avg_amount_prev_30d,
    APPROX_QUANTILES(r.transaction_amount,2)[OFFSET(1)] AS median_amount_prev_30d,
    MIN(r.transaction_amount) AS min_amount_prev_30d, MAX(r.transaction_amount) AS max_amount_prev_30d
  FROM last_trx l JOIN rddp r ON l.company_id=r.company_id
   AND r.transaction_created_datetime >= DATETIME_SUB(l.last_trx_datetime, INTERVAL 31 DAY)
   AND r.transaction_created_datetime <  DATETIME_SUB(l.last_trx_datetime, INTERVAL 24 HOUR)
  GROUP BY l.company_id)
SELECT base.company_id, base.is_gestun,
  l24.* EXCEPT (company_id), l7.* EXCEPT (company_id), l30.* EXCEPT (company_id),
  p7.* EXCEPT (company_id), p30.* EXCEPT (company_id),
  SAFE_DIVIDE(l24.num_trx_last_24h, p7.num_trx_prev_7d/7.0)            AS trx_ratio_24h_vs_prev7d,
  SAFE_DIVIDE(l24.total_amount_last_24h, p7.total_amount_prev_7d/7.0)  AS amount_ratio_24h_vs_prev7d,
  SAFE_DIVIDE(l24.avg_amount_last_24h, p7.avg_amount_prev_7d)          AS avg_amount_ratio_24h_vs_prev7d,
  SAFE_DIVIDE(l24.median_amount_last_24h, p7.median_amount_prev_7d)    AS median_amount_ratio_24h_vs_prev7d,
  SAFE_DIVIDE(l24.max_amount_last_24h, p7.max_amount_prev_7d)          AS max_amount_ratio_24h_vs_prev7d,
  SAFE_DIVIDE(l24.num_trx_last_24h, p30.num_trx_prev_30d/30.0)         AS trx_ratio_24h_vs_prev30d,
  SAFE_DIVIDE(l24.total_amount_last_24h, p30.total_amount_prev_30d/30.0) AS amount_ratio_24h_vs_prev30d,
  SAFE_DIVIDE(l24.avg_amount_last_24h, p30.avg_amount_prev_30d)        AS avg_amount_ratio_24h_vs_prev30d,
  SAFE_DIVIDE(l24.median_amount_last_24h, p30.median_amount_prev_30d)  AS median_amount_ratio_24h_vs_prev30d,
  SAFE_DIVIDE(l24.max_amount_last_24h, p30.max_amount_prev_30d)        AS max_amount_ratio_24h_vs_prev30d
FROM base
LEFT JOIN trx_stats_last_24h l24 USING (company_id)
LEFT JOIN trx_stats_last_7d   l7  USING (company_id)
LEFT JOIN trx_stats_last_30d  l30 USING (company_id)
LEFT JOIN trx_stats_prev_7d   p7  USING (company_id)
LEFT JOIN trx_stats_prev_30d  p30 USING (company_id)
