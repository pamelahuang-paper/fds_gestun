-- =============================================================================
-- FDS features from rpt__raw_data_digital_payments_daily
-- Column names bound to the confirmed schema (2026-08-05).
--
-- RESOLVED COLUMN MAP
--   external_id              <- order_id
--   amount                   <- transaction_amount
--   partner / mitra          <- partner_id, partner_name, partner_email, partner_phone_number
--   payment_channel_name     <- payment_method_name
--   method_clf               <- payment_method_type_name
--   trx_source_digpay_type   <- digital_payment_source_name
--   status                   <- payment_status_name
--   is_local_partner         <- NOT is_xb_transaction_flag   (xb = cross-border)
--   invoice created          <- transaction_created_datetime
--
-- NOT AVAILABLE IN THIS TABLE — two significant gaps
--   ❌ No card number / token column.  The whole card-graph family is
--      unbuildable here: cnt_uniquecc_at / _l7d / _l30d, cnt_comp_at_ccnum,
--      cnt_comp_l7d_ccnum, ttl_uniquecc_uses_in_1trx, is_cc_match_tokenized_def.
--      cnt_comp_at_ccnum is arguably the strongest feature in the current model,
--      so this table cannot replace the mart on its own — find the card/tokenization
--      source and join it.
--   ❌ No invoice_amount column.  Only transaction_amount exists, so
--      amount_to_invoice_amount and invoice_amount_l30d need the invoice table.
--      (invoice_cnt_l30d IS buildable via COUNT(DISTINCT invoice_id).)
--   ❌ No failed / declined / pending rows.  payment_status_name takes only three
--      values — PAID, SETTLEMENT, POSTED — which are settlement STAGES, not
--      outcomes. This table contains completed payments only. Therefore:
--        * success_rate_transaction_l30d is uncomputable here (it would be 1.0
--          for every row). It must come from an attempts/authorisation source.
--        * The entire carding-probe family is unreachable: n_declines_before_
--          success_l60m, n_distinct_cards_declined_l60m, decline_reason_entropy.
--          Card testing is invisible if you only ever see the successes.
--   ❌ KYC, company profile, and account-lifecycle deltas — need the company/user
--      dimensions, as before.
--
-- WHAT THIS TABLE UNEXPECTEDLY DOES SUPPORT
--   digital_payment_type_name carries both 'in' and 'out', so the gestun
--   cash-conversion family from FDS_Feature_Ideas_Carding_Gestun.md §2B is
--   buildable right here. So are partner exclusivity (§2C), invoice-authenticity
--   latency (§2D) and amount fingerprints (§2E). Those are in PART B below.
--
-- Every trailing window is anchored to the transaction's own timestamp and is
-- strictly backward-looking (h.ts < t.ts), so this is point-in-time correct.
-- =============================================================================

DECLARE window_start  DATE DEFAULT DATE '2026-07-01';
DECLARE window_end    DATE DEFAULT DATE '2026-07-31';
DECLARE history_start DATE DEFAULT DATE_SUB(DATE '2026-07-01', INTERVAL 90 DAY);


WITH base AS (
  SELECT
    order_id                                          AS external_id,
    digital_payment_id,
    company_id,
    TIMESTAMP(digpay_datetime)                        AS ts,
    UNIX_SECONDS(TIMESTAMP(digpay_datetime))          AS ts_sec,
    TIMESTAMP(transaction_created_datetime)           AS trx_created_ts,
    invoice_date,
    invoice_id,
    CAST(transaction_amount AS FLOAT64)               AS amount,
    -- exact key for equality/partitioning: BigQuery disallows FLOAT64 in
    -- PARTITION BY / GROUP BY, and float equality is unsafe anyway
    CAST(transaction_amount AS NUMERIC)               AS amount_key,
    CAST(total_fee_amount   AS FLOAT64)               AS fee_amount,
    partner_id,
    partner_name,
    partner_email,
    partner_phone_number,
    payment_method_name                               AS payment_channel_name,
    payment_method_type_name,
    digital_payment_source_name                       AS trx_source_digpay_type,
    LOWER(digital_payment_type_name)                  AS digpay_type,      -- 'in' / 'out'
    payment_status_name,
    reference_note,
    device_type_name,
    promotion_code,
    is_xb_transaction_flag,
    is_user_to_user_flag,
    user_to_user_level_number,
    is_transaction_bulk_flag,
    is_multiple_transaction_flag
  FROM `paper-prod.data_mart_layer.rpt__raw_data_digital_payments_daily`
  WHERE DATE(digpay_datetime) BETWEEN history_start AND window_end
    AND company_id NOT IN (
      SELECT DISTINCT company_id
      FROM `paper-prod.datascience_public.master_segment_table`
      WHERE testing_account IS NOT NULL
    )
),

-- inbound only: the population the FDS models score
inbound AS (
  SELECT * FROM base WHERE digpay_type = 'in'
),

-- =============================================================================
-- PART A — EXISTING FDS FEATURES
-- =============================================================================

-- A1. Velocity. RANGE frames over epoch seconds; `- 1` drops the row from its
--     own count.
velocity AS (
  SELECT
    external_id,

    COUNT(*) OVER (
      PARTITION BY company_id ORDER BY ts_sec
      RANGE BETWEEN 18000 PRECEDING AND CURRENT ROW              -- 300 min
    ) - 1 AS num_trx_last_300_minutes,

    COUNT(*) OVER (
      PARTITION BY company_id, partner_id ORDER BY ts_sec
      RANGE BETWEEN 1800 PRECEDING AND CURRENT ROW               -- 30 min
    ) - 1 AS num_trx_same_partner_last_30_minutes,

    COUNT(*) OVER (
      PARTITION BY company_id, amount_key ORDER BY ts_sec
      RANGE BETWEEN 86400 PRECEDING AND CURRENT ROW              -- 24 h
    ) - 1 AS num_trx_same_amount_last_24_hour,

    ROW_NUMBER() OVER (
      PARTITION BY company_id, partner_id ORDER BY ts_sec
    ) AS sequence_of_mitra_transaction,

    ts_sec - LAG(ts_sec) OVER (PARTITION BY company_id ORDER BY ts_sec)
      AS delta_created_last_trx_in_seconds,

    DIV(ts_sec - MIN(ts_sec) OVER (PARTITION BY company_id), 60)
      AS delta_payment_firsttrx_in_minutes
  FROM inbound
),

-- A2. Trailing 30-day aggregates. Self-join because a trailing median cannot be
--     expressed as an analytic frame in BigQuery. `h.ts < t.ts` keeps the current
--     transaction out of its own baseline.
hist_30d AS (
  SELECT
    t.external_id,
    APPROX_QUANTILES(h.amount, 2)[OFFSET(1)]     AS median_ticket_size_l30d,
    AVG(h.amount)                                AS avg_ticket_size_l30d,
    COUNT(DISTINCT h.invoice_id)                 AS invoice_cnt_l30d,
    -- NOTE: success_rate_transaction_l30d is deliberately absent. This table has
    -- no failed rows (PAID / SETTLEMENT / POSTED only), so any success rate
    -- computed here is identically 1.0. Source it from the attempts table.
    -- share of inbound value funded by credit card (gestun §2B)
    SAFE_DIVIDE(
      SUM(IF(LOWER(h.payment_method_type_name) LIKE '%credit%', h.amount, 0)),
      NULLIF(SUM(h.amount), 0)
    )                                            AS cc_funded_share_of_inbound_l30d
  FROM inbound t
  LEFT JOIN inbound h
    ON  h.company_id = t.company_id
    AND h.ts <  t.ts
    AND h.ts >= TIMESTAMP_SUB(t.ts, INTERVAL 30 DAY)
  WHERE DATE(t.ts) BETWEEN window_start AND window_end
  GROUP BY t.external_id
),

-- A3. Std-dev of daily transaction counts, trailing 30 days
daily_counts AS (
  SELECT company_id, DATE(ts) AS d, COUNT(*) AS n
  FROM inbound GROUP BY company_id, d
),
hist_std AS (
  SELECT t.external_id, STDDEV_SAMP(dc.n) AS std_invoice_count_l30d
  FROM inbound t
  LEFT JOIN daily_counts dc
    ON  dc.company_id = t.company_id
    AND dc.d <  DATE(t.ts)
    AND dc.d >= DATE_SUB(DATE(t.ts), INTERVAL 30 DAY)
  WHERE DATE(t.ts) BETWEEN window_start AND window_end
  GROUP BY t.external_id
),

-- A4. Partner counts to date
partner_profile AS (
  SELECT t.external_id, COUNT(DISTINCT h.partner_id) AS number_of_mitra
  FROM inbound t
  LEFT JOIN inbound h
    ON h.company_id = t.company_id AND h.ts <= t.ts
  WHERE DATE(t.ts) BETWEEN window_start AND window_end
  GROUP BY t.external_id
),

-- =============================================================================
-- PART B — NEW FEATURES THIS TABLE UNLOCKS (gestun-oriented)
-- =============================================================================

-- B1. Cash conversion: card money in -> payout out. The fee band is the tell.
cash_conversion AS (
  SELECT
    t.external_id,
    MIN(TIMESTAMP_DIFF(o.ts, t.ts, MINUTE))              AS minutes_cc_in_to_first_payout,
    MAX(SAFE_DIVIDE(o.amount, NULLIF(t.amount, 0)))      AS payout_to_inbound_ratio_24h,
    MAX(CASE WHEN SAFE_DIVIDE(o.amount, NULLIF(t.amount,0))
                  BETWEEN 0.95 AND 0.98 THEN 1 ELSE 0 END) AS is_fee_band_ratio,
    COUNT(o.external_id)                                 AS n_payouts_within_24h
  FROM inbound t
  LEFT JOIN base o
    ON  o.company_id = t.company_id
    AND o.digpay_type = 'out'
    AND o.ts >  t.ts
    AND o.ts <= TIMESTAMP_ADD(t.ts, INTERVAL 24 HOUR)
  WHERE DATE(t.ts) BETWEEN window_start AND window_end
  GROUP BY t.external_id
),

-- B2. Partner exclusivity. n_distinct_payers = 1 means a "merchant" with exactly
--     one customer — the single cleanest gestun signal available here.
partner_reach AS (
  SELECT
    partner_id,
    COUNT(DISTINCT company_id)                    AS n_distinct_payers_l90d,
    COUNT(*)                                      AS n_payments_received_l90d,
    SUM(amount)                                   AS total_received_l90d,
    MIN(ts)                                       AS partner_first_seen_ts
  FROM inbound
  WHERE partner_id IS NOT NULL
  GROUP BY partner_id
),

-- B3. Counterparty concentration on the payer side (trailing 90d)
payer_concentration AS (
  SELECT
    t.external_id,
    COUNT(DISTINCT h.partner_id)                                       AS n_partners_l90d,
    SAFE_DIVIDE(MAX(pv.partner_value), NULLIF(SUM(DISTINCT pv.partner_value), 0))
                                                                       AS top1_partner_value_share_l90d
  FROM inbound t
  LEFT JOIN inbound h
    ON  h.company_id = t.company_id
    AND h.ts <  t.ts
    AND h.ts >= TIMESTAMP_SUB(t.ts, INTERVAL 90 DAY)
  LEFT JOIN (
    SELECT company_id, partner_id, SUM(amount) AS partner_value
    FROM inbound GROUP BY company_id, partner_id
  ) pv
    ON pv.company_id = h.company_id AND pv.partner_id = h.partner_id
  WHERE DATE(t.ts) BETWEEN window_start AND window_end
  GROUP BY t.external_id
),

-- B4. Repeat identical amounts to the same partner
repeat_amounts AS (
  SELECT
    t.external_id,
    COUNT(DISTINCT DATE(h.ts)) AS n_days_identical_amount_same_partner_l30d
  FROM inbound t
  LEFT JOIN inbound h
    ON  h.company_id = t.company_id
    AND h.partner_id = t.partner_id
    AND h.amount_key = t.amount_key
    AND h.ts <  t.ts
    AND h.ts >= TIMESTAMP_SUB(t.ts, INTERVAL 30 DAY)
  WHERE DATE(t.ts) BETWEEN window_start AND window_end
  GROUP BY t.external_id
)

-- =============================================================================
-- FINAL
-- =============================================================================
SELECT
  b.external_id,
  b.company_id,
  b.ts                                                     AS digpay_datetime,

  ---- A: velocity ----
  v.num_trx_last_300_minutes,
  v.num_trx_same_partner_last_30_minutes,
  v.num_trx_same_amount_last_24_hour,
  v.sequence_of_mitra_transaction,
  IF(v.sequence_of_mitra_transaction = 1, 1, 0)            AS is_new_trx_mitra,
  v.delta_created_last_trx_in_seconds,
  v.delta_payment_firsttrx_in_minutes,

  ---- A: amount / history ----
  b.amount,
  h.median_ticket_size_l30d,
  h.avg_ticket_size_l30d,
  h.invoice_cnt_l30d,
  s.std_invoice_count_l30d,
  b.payment_status_name,                                   -- settlement stage, not an outcome
  -- the deviation ratio the current model is missing
  SAFE_DIVIDE(b.amount, NULLIF(h.median_ticket_size_l30d, 0))
                                                           AS amount_to_median_ticket_l30d,

  ---- A: partner / channel ----
  p.number_of_mitra,
  IF(b.is_xb_transaction_flag = 1, 0, 1)                   AS is_local_partner,  -- INT64 flag, not BOOL
  b.payment_channel_name,
  b.payment_method_type_name,
  b.trx_source_digpay_type,

  ---- B: cash conversion (gestun) ----
  cc.minutes_cc_in_to_first_payout,
  cc.payout_to_inbound_ratio_24h,
  cc.is_fee_band_ratio,
  cc.n_payouts_within_24h,
  h.cc_funded_share_of_inbound_l30d,

  ---- B: partner exclusivity (gestun) ----
  pr.n_distinct_payers_l90d                                AS mitra_n_distinct_payers_l90d,
  IF(pr.n_distinct_payers_l90d = 1, 1, 0)                  AS mitra_is_single_payer_only,
  TIMESTAMP_DIFF(b.ts, pr.partner_first_seen_ts, DAY)      AS mitra_age_days_at_payment,
  pc.n_partners_l90d,
  pc.top1_partner_value_share_l90d,
  ra.n_days_identical_amount_same_partner_l30d,

  ---- B: invoice authenticity (gestun) ----
  TIMESTAMP_DIFF(b.ts, b.trx_created_ts, SECOND)           AS seconds_trx_created_to_paid,
  DATE_DIFF(DATE(b.ts), DATE(b.invoice_date), DAY)         AS days_invoice_date_to_paid,
  IF(b.invoice_id IS NULL, 1, 0)                           AS has_no_invoice_backing,
  LENGTH(TRIM(COALESCE(b.reference_note, '')))             AS reference_note_len,
  IF(REGEXP_CONTAINS(
       LOWER(TRIM(COALESCE(b.reference_note, ''))),
       r'^(jasa|barang|pembayaran|payment|invoice|transfer|top ?up|-|\.|)$'
     ), 1, 0)                                              AS reference_note_is_generic,

  ---- B: amount fingerprints (gestun) ----
  IF(MOD(CAST(b.amount AS INT64),   100000) = 0, 1, 0)     AS is_round_100k,
  IF(MOD(CAST(b.amount AS INT64), 1000000) = 0, 1, 0)      AS is_round_1m,
  SAFE_DIVIDE(b.fee_amount, NULLIF(b.amount, 0))           AS fee_to_amount_ratio,

  ---- B: misc flags already present in the table ----
  b.is_user_to_user_flag,
  b.user_to_user_level_number,
  b.is_transaction_bulk_flag,
  b.is_multiple_transaction_flag,
  b.device_type_name,
  IF(b.promotion_code IS NULL, 0, 1)                       AS has_promotion_code

FROM inbound b
LEFT JOIN velocity            v  ON v.external_id  = b.external_id
LEFT JOIN hist_30d            h  ON h.external_id  = b.external_id
LEFT JOIN hist_std            s  ON s.external_id  = b.external_id
LEFT JOIN partner_profile     p  ON p.external_id  = b.external_id
LEFT JOIN cash_conversion     cc ON cc.external_id = b.external_id
LEFT JOIN payer_concentration pc ON pc.external_id = b.external_id
LEFT JOIN repeat_amounts      ra ON ra.external_id = b.external_id
LEFT JOIN partner_reach       pr ON pr.partner_id  = b.partner_id
WHERE DATE(b.ts) BETWEEN window_start AND window_end
ORDER BY b.company_id, b.ts;
