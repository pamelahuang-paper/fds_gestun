-- =============================================================================
-- FDS gestun training set — ONE ROW PER LABELLED external_id
-- Labels: paper-prod.datascience_public.fds_gestung_actual_label_050826
-- Source: paper-prod.data_mart_layer.rpt__raw_data_digital_payments_daily
--
-- POINT-IN-TIME DISCIPLINE
--   Every history feature is computed from transactions STRICTLY BEFORE the
--   labelled transaction's own timestamp (h.ts < t.ts). Company context is not
--   taken as-of a fixed snapshot date, because that would leak future behaviour
--   into a past transaction's row.
--
-- ⚠️ ONE DELIBERATE EXCEPTION — the cash-conversion block looks 24h FORWARD.
--   You cannot know the payout before it happens, so those features are usable
--   for post-hoc REVIEW / investigation scoring, but NOT for real-time blocking.
--   They are prefixed `fwd_` so you can drop them with one filter when training
--   a prevention model. Keeping them in a real-time model would be leakage.
--
-- NOT DERIVABLE FROM THIS SOURCE: card graph (no card/token column),
--   invoice_amount ratios, decline behaviour (no failed rows), KYC, company
--   profile. See fds_features_from_raw_payments.sql header.
-- =============================================================================

DECLARE lookback_days INT64 DEFAULT 90;   -- history depth behind each labelled trx


WITH
-- =============================================================================
-- 0. LABELS — the driving population, at external_id grain
-- =============================================================================
label_raw AS (
  SELECT
    TRIM(company_id)  AS company_id,
    TRIM(external_id) AS external_id,
    -- `flag` type unconfirmed; handles INT64 / BOOL / common strings.
    -- Verify with: SELECT flag, COUNT(*) FROM <label table> GROUP BY flag
    CASE
      WHEN SAFE_CAST(flag AS INT64) IS NOT NULL THEN SAFE_CAST(flag AS INT64)
      WHEN LOWER(CAST(flag AS STRING)) IN ('true','y','yes','fraud','gestun','not legit') THEN 1
      ELSE 0
    END AS is_gestun
  FROM `paper-prod.datascience_public.fds_gestung_actual_label_050826`
  QUALIFY ROW_NUMBER() OVER (PARTITION BY TRIM(external_id) ORDER BY company_id) = 1
),

labelled_companies AS (
  SELECT DISTINCT company_id FROM label_raw
),

-- =============================================================================
-- 1. BASE — all payment activity for the labelled companies
-- =============================================================================
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
    CAST(transaction_amount AS NUMERIC)        AS amount_key,   -- FLOAT64 can't GROUP BY
    CAST(total_fee_amount   AS FLOAT64)        AS fee_amount,
    partner_id,
    partner_name,
    payment_method_type_name,
    payment_method_name                        AS payment_channel_name,
    digital_payment_source_name                AS trx_source_digpay_type,
    LOWER(digital_payment_type_name)           AS digpay_type,  -- 'in' / 'out'
    payment_status_name,
    reference_note,
    device_type_name,
    is_xb_transaction_flag,
    is_user_to_user_flag,
    user_to_user_level_number,
    is_transaction_bulk_flag,
    is_multiple_transaction_flag
  FROM `paper-prod.data_mart_layer.rpt__raw_data_digital_payments_daily`
  WHERE company_id IN (SELECT company_id FROM labelled_companies)
),

inbound  AS (SELECT * FROM base WHERE digpay_type = 'in'),
outbound AS (SELECT * FROM base WHERE digpay_type = 'out'),

-- The labelled transactions themselves, with their own attributes.
-- order_id may repeat in the source (bulk payments), so keep the earliest.
target AS (
  SELECT
    l.external_id,
    l.company_id                AS label_company_id,
    l.is_gestun,
    b.company_id                AS trx_company_id,
    b.ts, b.ts_sec, b.trx_created_ts, b.invoice_id,
    b.amount, b.amount_key, b.fee_amount,
    b.partner_id, b.partner_name,
    b.payment_method_type_name, b.payment_channel_name,
    b.trx_source_digpay_type, b.digpay_type, b.payment_status_name,
    b.reference_note, b.device_type_name,
    b.is_xb_transaction_flag, b.is_user_to_user_flag, b.user_to_user_level_number,
    b.is_transaction_bulk_flag, b.is_multiple_transaction_flag
  FROM label_raw l
  LEFT JOIN base b
    ON b.external_id = l.external_id
  QUALIFY ROW_NUMBER() OVER (PARTITION BY l.external_id ORDER BY b.ts) = 1
),

-- =============================================================================
-- 2. VELOCITY — as-of the labelled transaction
-- =============================================================================
tx_velocity AS (
  SELECT
    external_id,
    COUNT(*) OVER (
      PARTITION BY company_id ORDER BY ts_sec
      RANGE BETWEEN 18000 PRECEDING AND CURRENT ROW
    ) - 1 AS num_trx_last_300_minutes,
    COUNT(*) OVER (
      PARTITION BY company_id, partner_id ORDER BY ts_sec
      RANGE BETWEEN 1800 PRECEDING AND CURRENT ROW
    ) - 1 AS num_trx_same_partner_last_30_minutes,
    COUNT(*) OVER (
      PARTITION BY company_id, amount_key ORDER BY ts_sec
      RANGE BETWEEN 86400 PRECEDING AND CURRENT ROW
    ) - 1 AS num_trx_same_amount_last_24_hour,
    ROW_NUMBER() OVER (
      PARTITION BY company_id, partner_id ORDER BY ts_sec
    ) AS sequence_of_mitra_transaction,
    ts_sec - LAG(ts_sec) OVER (PARTITION BY company_id ORDER BY ts_sec)
      AS seconds_since_prev_trx
  FROM inbound
),

-- =============================================================================
-- 3. COMPANY HISTORY — strictly prior to the labelled transaction
-- =============================================================================
tx_history AS (
  SELECT
    t.external_id,
    COUNT(h.external_id)                                  AS n_prior_trx_l90d,
    COUNTIF(h.ts >= TIMESTAMP_SUB(t.ts, INTERVAL 30 DAY)) AS n_prior_trx_l30d,
    SUM(h.amount)                                         AS prior_inbound_value_l90d,
    APPROX_QUANTILES(h.amount, 2)[OFFSET(1)]              AS median_ticket_size_prior,
    AVG(h.amount)                                         AS avg_ticket_size_prior,
    COUNT(DISTINCT h.invoice_id)                          AS invoice_cnt_prior,
    COUNT(DISTINCT h.partner_id)                          AS number_of_mitra_prior,
    SAFE_DIVIDE(
      SUM(IF(LOWER(h.payment_method_type_name) LIKE '%credit%', h.amount, 0)),
      NULLIF(SUM(h.amount), 0)
    )                                                     AS cc_funded_share_prior,
    SAFE_DIVIDE(COUNT(DISTINCT h.amount_key), COUNT(h.external_id))
                                                          AS distinct_amount_ratio_prior
  FROM target t
  LEFT JOIN inbound h
    ON  h.company_id = t.trx_company_id
    AND h.ts <  t.ts
    AND h.ts >= TIMESTAMP_SUB(t.ts, INTERVAL lookback_days DAY)
  GROUP BY t.external_id
),

-- =============================================================================
-- 4. PARTNER CONCENTRATION — prior spend spread  (gestun §2C)
-- =============================================================================
tx_partner_value AS (
  SELECT t.external_id AS target_id, h.partner_id, SUM(h.amount) AS v
  FROM target t
  JOIN inbound h
    ON  h.company_id = t.trx_company_id
    AND h.partner_id IS NOT NULL
    AND h.ts <  t.ts
    AND h.ts >= TIMESTAMP_SUB(t.ts, INTERVAL lookback_days DAY)
  GROUP BY target_id, h.partner_id
),
tx_concentration AS (
  SELECT
    target_id AS external_id,
    COUNT(*)                                          AS n_partners_prior,
    SAFE_DIVIDE(MAX(v), NULLIF(SUM(v), 0))            AS top1_partner_value_share_prior,
    SAFE_DIVIDE(SUM(v * v), NULLIF(POW(SUM(v), 2), 0)) AS partner_hhi_prior
  FROM tx_partner_value
  GROUP BY target_id
),

-- How exclusive is THIS transaction's partner, as of now? A partner whose only
-- payer is this company is the cleanest gestun signal available here.
tx_partner_reach AS (
  SELECT
    t.external_id,
    COUNT(DISTINCT h.company_id)                      AS partner_n_payers_to_date,
    COUNT(h.external_id)                              AS partner_n_payments_to_date,
    TIMESTAMP_DIFF(t.ts, MIN(h.ts), DAY)              AS partner_age_days_at_trx
  FROM target t
  LEFT JOIN inbound h
    ON  h.partner_id = t.partner_id
    AND t.partner_id IS NOT NULL
    AND h.ts <= t.ts
  GROUP BY t.external_id, t.ts
),

-- repeated identical amount to the same partner, prior only
tx_repeat AS (
  SELECT
    t.external_id,
    COUNT(DISTINCT DATE(h.ts)) AS n_prior_days_identical_amount_same_partner
  FROM target t
  LEFT JOIN inbound h
    ON  h.company_id = t.trx_company_id
    AND h.partner_id = t.partner_id
    AND h.amount_key = t.amount_key
    AND h.ts <  t.ts
    AND h.ts >= TIMESTAMP_SUB(t.ts, INTERVAL 30 DAY)
  GROUP BY t.external_id
),

-- =============================================================================
-- 5. ⚠️ FORWARD-LOOKING: cash conversion  (gestun §2B)
--    Prefixed fwd_ — drop these when training a real-time prevention model.
-- =============================================================================
tx_cash_conv AS (
  SELECT
    t.external_id,
    MIN(TIMESTAMP_DIFF(o.ts, t.ts, MINUTE))                AS fwd_minutes_to_first_payout,
    MAX(SAFE_DIVIDE(o.amount, NULLIF(t.amount, 0)))        AS fwd_max_payout_ratio_24h,
    MAX(CASE WHEN SAFE_DIVIDE(o.amount, NULLIF(t.amount, 0))
                  BETWEEN 0.95 AND 0.98 THEN 1 ELSE 0 END) AS fwd_is_fee_band_ratio,
    COUNT(o.external_id)                                   AS fwd_n_payouts_24h,
    SUM(o.amount)                                          AS fwd_payout_value_24h
  FROM target t
  LEFT JOIN outbound o
    ON  o.company_id = t.trx_company_id
    AND o.ts >  t.ts
    AND o.ts <= TIMESTAMP_ADD(t.ts, INTERVAL 24 HOUR)
  GROUP BY t.external_id
)

-- =============================================================================
-- FINAL — one row per labelled external_id
-- =============================================================================
SELECT
  t.external_id,
  COALESCE(t.trx_company_id, t.label_company_id)           AS company_id,
  t.ts                                                     AS digpay_datetime,

  ---- LABEL ----
  t.is_gestun,
  IF(t.ts IS NULL, 1, 0)                                   AS not_found_in_payments,
  IF(t.trx_company_id IS NOT NULL
     AND t.trx_company_id != t.label_company_id, 1, 0)     AS company_id_mismatch_vs_label,

  ---- transaction attributes ----
  t.amount,
  t.fee_amount,
  SAFE_DIVIDE(t.fee_amount, NULLIF(t.amount, 0))           AS fee_to_amount_ratio,
  t.digpay_type,
  t.payment_status_name,
  t.payment_method_type_name,
  t.payment_channel_name,
  t.trx_source_digpay_type,
  t.device_type_name,
  t.partner_id,
  t.partner_name,
  IF(t.is_xb_transaction_flag = 1, 0, 1)                   AS is_local_partner,
  t.is_user_to_user_flag,
  t.user_to_user_level_number,
  t.is_transaction_bulk_flag,
  t.is_multiple_transaction_flag,

  ---- velocity (as-of) ----
  v.num_trx_last_300_minutes,
  v.num_trx_same_partner_last_30_minutes,
  v.num_trx_same_amount_last_24_hour,
  v.sequence_of_mitra_transaction,
  IF(v.sequence_of_mitra_transaction = 1, 1, 0)            AS is_new_trx_mitra,
  v.seconds_since_prev_trx,

  ---- company history (prior only) ----
  h.n_prior_trx_l30d,
  h.n_prior_trx_l90d,
  h.prior_inbound_value_l90d,
  h.median_ticket_size_prior,
  h.avg_ticket_size_prior,
  h.invoice_cnt_prior,
  h.number_of_mitra_prior,
  h.cc_funded_share_prior,
  h.distinct_amount_ratio_prior,
  -- the deviation ratio the production model lacks entirely
  SAFE_DIVIDE(t.amount, NULLIF(h.median_ticket_size_prior, 0))
                                                           AS amount_to_median_ticket_prior,

  ---- partner concentration (gestun) ----
  c.n_partners_prior,
  c.top1_partner_value_share_prior,
  c.partner_hhi_prior,
  pr.partner_n_payers_to_date,
  IF(pr.partner_n_payers_to_date = 1, 1, 0)                AS partner_is_exclusive_to_this_company,
  pr.partner_n_payments_to_date,
  pr.partner_age_days_at_trx,
  rp.n_prior_days_identical_amount_same_partner,

  ---- invoice authenticity (gestun) ----
  TIMESTAMP_DIFF(t.ts, t.trx_created_ts, SECOND)           AS seconds_created_to_paid,
  IF(TIMESTAMP_DIFF(t.ts, t.trx_created_ts, MINUTE) <= 5, 1, 0)
                                                           AS is_paid_within_5min_of_creation,
  IF(t.invoice_id IS NULL, 1, 0)                           AS has_no_invoice_backing,
  LENGTH(TRIM(COALESCE(t.reference_note, '')))             AS reference_note_len,
  IF(REGEXP_CONTAINS(
       LOWER(TRIM(COALESCE(t.reference_note, ''))),
       r'^(jasa|barang|pembayaran|payment|invoice|transfer|top ?up|-|\.|)$'
     ), 1, 0)                                              AS reference_note_is_generic,

  ---- amount fingerprints (gestun) ----
  IF(MOD(CAST(t.amount AS INT64),  100000) = 0, 1, 0)      AS is_round_100k,
  IF(MOD(CAST(t.amount AS INT64), 1000000) = 0, 1, 0)      AS is_round_1m,

  ---- ⚠️ FORWARD-LOOKING — exclude for real-time models ----
  cc.fwd_minutes_to_first_payout,
  cc.fwd_max_payout_ratio_24h,
  cc.fwd_is_fee_band_ratio,
  cc.fwd_n_payouts_24h,
  cc.fwd_payout_value_24h

FROM target t
LEFT JOIN tx_velocity      v  ON v.external_id  = t.external_id
LEFT JOIN tx_history       h  ON h.external_id  = t.external_id
LEFT JOIN tx_concentration c  ON c.external_id  = t.external_id
LEFT JOIN tx_partner_reach pr ON pr.external_id = t.external_id
LEFT JOIN tx_repeat        rp ON rp.external_id = t.external_id
LEFT JOIN tx_cash_conv     cc ON cc.external_id = t.external_id
ORDER BY t.is_gestun DESC, t.ts;
