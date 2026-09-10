-- =============================================================================
-- FDS company-level feature table
-- Source: paper-prod.data_mart_layer.rpt__raw_data_digital_payments_daily
-- Grain:  ONE ROW PER company_id, as of snapshot_date
--
-- All windows are anchored to snapshot_date and look strictly backward.
--
-- Per-transaction features that have no company-level meaning are rolled up as
-- MAX (peak burst) or AVG/share (typical behaviour) — the aggregation choice is
-- noted on each. For velocity, MAX is the fraud-relevant statistic: one burst in
-- 90 days is what matters, and an average would wash it out.
--
-- NOT DERIVABLE FROM THIS TABLE (see fds_features_from_raw_payments.sql header):
--   card graph (no card/token column), invoice_amount features,
--   success rate / decline behaviour (no failed rows), KYC, company profile.
-- =============================================================================

DECLARE snapshot_date DATE DEFAULT DATE '2026-07-31';
DECLARE lookback_days INT64 DEFAULT 90;


WITH
-- =============================================================================
-- 0. LABELS — gestun ground truth, rolled up to company level.
--    This CTE also drives the population: only companies present here are output.
-- =============================================================================
label_raw AS (
  SELECT
    company_id,
    external_id,
    -- `flag` type is unconfirmed; this handles INT64 / BOOL / common strings.
    -- Check with: SELECT DISTINCT flag FROM <label table>
    CASE
      WHEN SAFE_CAST(flag AS INT64) IS NOT NULL THEN SAFE_CAST(flag AS INT64)
      WHEN LOWER(CAST(flag AS STRING)) IN ('true','y','yes','fraud','gestun','not legit') THEN 1
      ELSE 0
    END AS flag_int
  FROM `paper-prod.datascience_public.fds_gestung_actual_label_050826`
),
labels AS (
  SELECT
    company_id,
    MAX(flag_int)                                        AS is_gestun_company,
    COUNT(DISTINCT external_id)                          AS n_labeled_trx,
    COUNT(DISTINCT IF(flag_int = 1, external_id, NULL))  AS n_flagged_trx,
    SAFE_DIVIDE(
      COUNT(DISTINCT IF(flag_int = 1, external_id, NULL)),
      COUNT(DISTINCT external_id)
    )                                                    AS share_flagged_trx
  FROM label_raw
  GROUP BY company_id
),

base AS (
  SELECT
    company_id,
    order_id                                   AS external_id,
    digital_payment_id,
    TIMESTAMP(digpay_datetime)                 AS ts,
    UNIX_SECONDS(TIMESTAMP(digpay_datetime))   AS ts_sec,
    TIMESTAMP(transaction_created_datetime)    AS trx_created_ts,
    invoice_id,
    CAST(transaction_amount AS FLOAT64)        AS amount,
    CAST(transaction_amount AS NUMERIC)        AS amount_key,   -- exact; FLOAT64 can't GROUP BY
    CAST(total_fee_amount   AS FLOAT64)        AS fee_amount,
    partner_id,
    payment_method_type_name,
    payment_method_name                        AS payment_channel_name,
    digital_payment_source_name                AS trx_source_digpay_type,
    LOWER(digital_payment_type_name)           AS digpay_type,  -- 'in' / 'out'
    reference_note,
    device_type_name,
    is_xb_transaction_flag,
    is_user_to_user_flag,
    is_transaction_bulk_flag,
    is_multiple_transaction_flag
  FROM `paper-prod.data_mart_layer.rpt__raw_data_digital_payments_daily`
  WHERE DATE(digpay_datetime)
          BETWEEN DATE_SUB(snapshot_date, INTERVAL lookback_days DAY) AND snapshot_date
    AND company_id NOT IN (
      SELECT DISTINCT company_id
      FROM `paper-prod.datascience_public.master_segment_table`
      WHERE testing_account IS NOT NULL
    )
    -- restrict to labelled companies early: cuts the scan before any window
    -- function or self-join runs
    AND company_id IN (SELECT company_id FROM labels)
),

inbound  AS (SELECT * FROM base WHERE digpay_type = 'in'),
outbound AS (SELECT * FROM base WHERE digpay_type = 'out'),

-- =============================================================================
-- 1. VELOCITY — computed per transaction, then rolled up as the company's PEAK
-- =============================================================================
tx_velocity AS (
  SELECT
    company_id,
    COUNT(*) OVER (
      PARTITION BY company_id ORDER BY ts_sec
      RANGE BETWEEN 18000 PRECEDING AND CURRENT ROW
    ) - 1 AS n_trx_300m,
    COUNT(*) OVER (
      PARTITION BY company_id, partner_id ORDER BY ts_sec
      RANGE BETWEEN 1800 PRECEDING AND CURRENT ROW
    ) - 1 AS n_trx_same_partner_30m,
    COUNT(*) OVER (
      PARTITION BY company_id, amount_key ORDER BY ts_sec
      RANGE BETWEEN 86400 PRECEDING AND CURRENT ROW
    ) - 1 AS n_trx_same_amount_24h,
    ts_sec - LAG(ts_sec) OVER (PARTITION BY company_id ORDER BY ts_sec)
      AS gap_since_prev_sec
  FROM inbound
),
company_velocity AS (
  SELECT
    company_id,
    MAX(n_trx_300m)             AS max_num_trx_last_300_minutes,
    MAX(n_trx_same_partner_30m) AS max_num_trx_same_partner_last_30_minutes,
    MAX(n_trx_same_amount_24h)  AS max_num_trx_same_amount_last_24_hour,
    MIN(gap_since_prev_sec)     AS min_gap_between_trx_seconds,
    AVG(gap_since_prev_sec)     AS avg_gap_between_trx_seconds,
    -- low CV = machine-like regularity; high CV = bursty. Both are informative.
    SAFE_DIVIDE(STDDEV_SAMP(gap_since_prev_sec), AVG(gap_since_prev_sec))
                                AS gap_cv
  FROM tx_velocity
  GROUP BY company_id
),

-- =============================================================================
-- 2. VOLUME & TICKET SIZE
-- =============================================================================
company_volume AS (
  SELECT
    company_id,
    COUNT(*)                                                       AS n_trx_l90d,
    COUNTIF(ts >= TIMESTAMP_SUB(TIMESTAMP(snapshot_date), INTERVAL 30 DAY))
                                                                   AS n_trx_l30d,
    SUM(amount)                                                    AS total_inbound_l90d,
    SUM(IF(ts >= TIMESTAMP_SUB(TIMESTAMP(snapshot_date), INTERVAL 30 DAY), amount, 0))
                                                                   AS total_inbound_l30d,
    APPROX_QUANTILES(amount, 2)[OFFSET(1)]                         AS median_ticket_size_l90d,
    AVG(amount)                                                    AS avg_ticket_size_l90d,
    MAX(amount)                                                    AS max_ticket_size_l90d,
    COUNT(DISTINCT invoice_id)                                     AS invoice_cnt_l90d,
    -- gestun §2B: card-limit conversion means near-total CC funding
    SAFE_DIVIDE(
      SUM(IF(LOWER(payment_method_type_name) LIKE '%credit%', amount, 0)),
      NULLIF(SUM(amount), 0)
    )                                                              AS cc_funded_share_of_inbound_l90d
  FROM inbound
  GROUP BY company_id
),

daily_counts AS (
  SELECT company_id, DATE(ts) AS d, COUNT(*) AS n
  FROM inbound GROUP BY company_id, d
),
company_daily AS (
  SELECT
    company_id,
    STDDEV_SAMP(n)          AS std_daily_trx_count_l90d,
    AVG(n)                  AS avg_daily_trx_count_l90d,
    COUNT(*)                AS n_active_days_l90d
  FROM daily_counts
  GROUP BY company_id
),

-- =============================================================================
-- 3. PARTNER CONCENTRATION  (gestun §2C)
-- =============================================================================
partner_value AS (
  SELECT company_id, partner_id, SUM(amount) AS v, COUNT(*) AS n
  FROM inbound
  WHERE partner_id IS NOT NULL
  GROUP BY company_id, partner_id
),
company_concentration AS (
  SELECT
    company_id,
    COUNT(*)                                        AS number_of_mitra_l90d,
    SAFE_DIVIDE(MAX(v), NULLIF(SUM(v), 0))          AS top1_partner_value_share_l90d,
    -- HHI = sum(share^2), computed without a window function
    SAFE_DIVIDE(SUM(v * v), NULLIF(POW(SUM(v), 2), 0))
                                                    AS partner_hhi_l90d
  FROM partner_value
  GROUP BY company_id
),

-- How exclusive are this company's partners? A partner whose ONLY payer is this
-- company is the cleanest gestun signal available from this table.
partner_reach AS (
  SELECT partner_id, COUNT(DISTINCT company_id) AS n_distinct_payers_l90d
  FROM inbound
  WHERE partner_id IS NOT NULL
  GROUP BY partner_id
),
company_partner_exclusivity AS (
  SELECT
    pv.company_id,
    COUNTIF(pr.n_distinct_payers_l90d = 1)                       AS n_exclusive_partners,
    SAFE_DIVIDE(COUNTIF(pr.n_distinct_payers_l90d = 1), COUNT(*)) AS share_exclusive_partners,
    AVG(pr.n_distinct_payers_l90d)                               AS avg_payers_per_partner,
    -- value-weighted: what share of spend goes to single-customer "merchants"
    SAFE_DIVIDE(
      SUM(IF(pr.n_distinct_payers_l90d = 1, pv.v, 0)),
      NULLIF(SUM(pv.v), 0)
    )                                                            AS value_share_to_exclusive_partners
  FROM partner_value pv
  JOIN partner_reach pr USING (partner_id)
  GROUP BY pv.company_id
),

-- =============================================================================
-- 4. CASH CONVERSION — money in by card, straight out  (gestun §2B)
-- =============================================================================
tx_cash_conv AS (
  SELECT
    i.company_id,
    i.external_id,
    MIN(TIMESTAMP_DIFF(o.ts, i.ts, MINUTE))                AS minutes_to_first_payout,
    MAX(SAFE_DIVIDE(o.amount, NULLIF(i.amount, 0)))        AS payout_ratio,
    MAX(CASE WHEN SAFE_DIVIDE(o.amount, NULLIF(i.amount, 0))
                  BETWEEN 0.95 AND 0.98 THEN 1 ELSE 0 END) AS in_fee_band
  FROM inbound i
  LEFT JOIN outbound o
    ON  o.company_id = i.company_id
    AND o.ts >  i.ts
    AND o.ts <= TIMESTAMP_ADD(i.ts, INTERVAL 24 HOUR)
  GROUP BY i.company_id, i.external_id
),
company_cash_conv AS (
  SELECT
    company_id,
    MIN(minutes_to_first_payout)                                   AS min_minutes_in_to_payout,
    APPROX_QUANTILES(minutes_to_first_payout, 2)[OFFSET(1)]        AS median_minutes_in_to_payout,
    SAFE_DIVIDE(COUNTIF(in_fee_band = 1), COUNT(*))                AS share_trx_in_fee_band,
    COUNTIF(in_fee_band = 1)                                       AS n_trx_in_fee_band,
    -- stability of the haircut: a CONSISTENT 2-5% cut is a priced service
    STDDEV_SAMP(payout_ratio)                                      AS payout_ratio_stddev,
    AVG(payout_ratio)                                              AS avg_payout_ratio
  FROM tx_cash_conv
  GROUP BY company_id
),
company_flow AS (
  SELECT
    i.company_id,
    SAFE_DIVIDE(o.total_out, NULLIF(i.total_in, 0)) AS out_to_in_value_ratio_l90d
  FROM (SELECT company_id, SUM(amount) AS total_in  FROM inbound  GROUP BY company_id) i
  LEFT JOIN (SELECT company_id, SUM(amount) AS total_out FROM outbound GROUP BY company_id) o
    USING (company_id)
),

-- =============================================================================
-- 5. INVOICE AUTHENTICITY  (gestun §2D)
-- =============================================================================
company_invoice AS (
  SELECT
    company_id,
    APPROX_QUANTILES(TIMESTAMP_DIFF(ts, trx_created_ts, SECOND), 2)[OFFSET(1)]
                                                                    AS median_seconds_created_to_paid,
    SAFE_DIVIDE(
      COUNTIF(TIMESTAMP_DIFF(ts, trx_created_ts, MINUTE) <= 5), COUNT(*)
    )                                                               AS share_paid_within_5min_of_creation,
    SAFE_DIVIDE(COUNTIF(invoice_id IS NULL), COUNT(*))              AS share_no_invoice_backing,
    SAFE_DIVIDE(
      COUNTIF(REGEXP_CONTAINS(
        LOWER(TRIM(COALESCE(reference_note, ''))),
        r'^(jasa|barang|pembayaran|payment|invoice|transfer|top ?up|-|\.|)$')),
      COUNT(*)
    )                                                               AS share_generic_reference_note,
    AVG(LENGTH(TRIM(COALESCE(reference_note, ''))))                 AS avg_reference_note_len
  FROM inbound
  GROUP BY company_id
),

-- =============================================================================
-- 6. AMOUNT FINGERPRINTS  (gestun §2E)
-- =============================================================================
company_amount_fp AS (
  SELECT
    company_id,
    SAFE_DIVIDE(COUNTIF(MOD(CAST(amount AS INT64),  100000) = 0), COUNT(*)) AS share_round_100k,
    SAFE_DIVIDE(COUNTIF(MOD(CAST(amount AS INT64), 1000000) = 0), COUNT(*)) AS share_round_1m,
    -- low ratio = the same few amounts repeated over and over
    SAFE_DIVIDE(COUNT(DISTINCT amount_key), COUNT(*))                       AS distinct_amount_ratio,
    SAFE_DIVIDE(AVG(fee_amount), NULLIF(AVG(amount), 0))                    AS avg_fee_to_amount_ratio
  FROM inbound
  GROUP BY company_id
),

-- most-repeated (partner, amount) pair
repeat_pairs AS (
  SELECT company_id, partner_id, amount_key, COUNT(DISTINCT DATE(ts)) AS n_days
  FROM inbound
  WHERE partner_id IS NOT NULL
  GROUP BY company_id, partner_id, amount_key
),
company_repeat AS (
  SELECT company_id, MAX(n_days) AS max_days_identical_amount_same_partner
  FROM repeat_pairs GROUP BY company_id
),

-- =============================================================================
-- 7. CHANNEL & FLAG MIX
-- =============================================================================
company_mix AS (
  SELECT
    company_id,
    -- these flags are INT64 (0/1), not BOOL, so COUNTIF needs an explicit predicate
    SAFE_DIVIDE(COUNTIF(is_user_to_user_flag        = 1), COUNT(*)) AS share_user_to_user,
    SAFE_DIVIDE(COUNTIF(is_transaction_bulk_flag    = 1), COUNT(*)) AS share_bulk_trx,
    SAFE_DIVIDE(COUNTIF(is_multiple_transaction_flag= 1), COUNT(*)) AS share_multiple_trx,
    SAFE_DIVIDE(COUNTIF(is_xb_transaction_flag      = 1), COUNT(*)) AS share_cross_border,
    COUNT(DISTINCT device_type_name)                            AS n_distinct_device_types,
    COUNT(DISTINCT payment_channel_name)                        AS n_distinct_payment_channels,
    COUNT(DISTINCT trx_source_digpay_type)                      AS n_distinct_trx_sources,
    APPROX_TOP_COUNT(payment_channel_name, 1)[OFFSET(0)].value  AS dominant_payment_channel,
    APPROX_TOP_COUNT(payment_method_type_name, 1)[OFFSET(0)].value AS dominant_payment_method_type
  FROM inbound
  GROUP BY company_id
)

-- =============================================================================
-- FINAL — one row per company
-- =============================================================================
SELECT
  l.company_id,
  snapshot_date                                          AS as_of_date,
  lookback_days,

  ---- LABEL ----
  l.is_gestun_company,
  l.n_labeled_trx,
  l.n_flagged_trx,
  l.share_flagged_trx,
  -- companies present in the label table with no inbound activity in the window
  IF(cv.company_id IS NULL, 1, 0)                        AS has_no_features_in_window,

  ---- volume ----
  vol.n_trx_l30d,
  vol.n_trx_l90d,
  vol.total_inbound_l30d,
  vol.total_inbound_l90d,
  vol.median_ticket_size_l90d,
  vol.avg_ticket_size_l90d,
  vol.max_ticket_size_l90d,
  vol.invoice_cnt_l90d,
  vol.cc_funded_share_of_inbound_l90d,
  d.avg_daily_trx_count_l90d,
  d.std_daily_trx_count_l90d,
  d.n_active_days_l90d,

  ---- velocity (peaks) ----
  cv.max_num_trx_last_300_minutes,
  cv.max_num_trx_same_partner_last_30_minutes,
  cv.max_num_trx_same_amount_last_24_hour,
  cv.min_gap_between_trx_seconds,
  cv.avg_gap_between_trx_seconds,
  cv.gap_cv,

  ---- partner concentration (gestun) ----
  con.number_of_mitra_l90d,
  con.top1_partner_value_share_l90d,
  con.partner_hhi_l90d,
  ex.n_exclusive_partners,
  ex.share_exclusive_partners,
  ex.value_share_to_exclusive_partners,
  ex.avg_payers_per_partner,

  ---- cash conversion (gestun) ----
  cc.min_minutes_in_to_payout,
  cc.median_minutes_in_to_payout,
  cc.n_trx_in_fee_band,
  cc.share_trx_in_fee_band,
  cc.avg_payout_ratio,
  cc.payout_ratio_stddev,
  fl.out_to_in_value_ratio_l90d,

  ---- invoice authenticity (gestun) ----
  inv.median_seconds_created_to_paid,
  inv.share_paid_within_5min_of_creation,
  inv.share_no_invoice_backing,
  inv.share_generic_reference_note,
  inv.avg_reference_note_len,

  ---- amount fingerprints (gestun) ----
  fp.share_round_100k,
  fp.share_round_1m,
  fp.distinct_amount_ratio,
  fp.avg_fee_to_amount_ratio,
  rp.max_days_identical_amount_same_partner,

  ---- channel & flag mix ----
  mix.share_user_to_user,
  mix.share_bulk_trx,
  mix.share_multiple_trx,
  mix.share_cross_border,
  mix.n_distinct_device_types,
  mix.n_distinct_payment_channels,
  mix.n_distinct_trx_sources,
  mix.dominant_payment_channel,
  mix.dominant_payment_method_type

FROM labels l
LEFT JOIN company_velocity            cv  USING (company_id)
LEFT JOIN company_volume              vol USING (company_id)
LEFT JOIN company_daily               d   USING (company_id)
LEFT JOIN company_concentration       con USING (company_id)
LEFT JOIN company_partner_exclusivity ex  USING (company_id)
LEFT JOIN company_cash_conv           cc  USING (company_id)
LEFT JOIN company_flow                fl  USING (company_id)
LEFT JOIN company_invoice             inv USING (company_id)
LEFT JOIN company_amount_fp           fp  USING (company_id)
LEFT JOIN company_repeat              rp  USING (company_id)
LEFT JOIN company_mix                 mix USING (company_id)
-- To drop labelled companies that have no transactions in the window, add:
--   WHERE cv.company_id IS NOT NULL
ORDER BY l.is_gestun_company DESC, vol.total_inbound_l90d DESC;
