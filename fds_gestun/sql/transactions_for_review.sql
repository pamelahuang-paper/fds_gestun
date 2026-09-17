-- Transaction detail for companies that have been scored.
-- @company_ids : ARRAY<STRING>   @window_start / @window_end : DATE
--
-- The MODEL is company-grain. This query does not score transactions -- it lists
-- them with the per-transaction attributes a reviewer needs to decide which ones
-- to open first. The company's score is joined on separately by the caller.
WITH t AS (
  SELECT
    r.company_id,
    r.digital_payment_id,
    r.order_id,
    r.transaction_created_datetime,
    r.transaction_amount,
    r.partner_id,
    r.partner_name,
    r.digital_payment_type_name,
    r.payment_method_name
  FROM `paper-prod.data_mart_layer.rpt__raw_data_digital_payments_daily` r
  WHERE r.payment_status_name = 'PAID'
    AND r.company_id IN UNNEST(@company_ids)
    AND DATE(r.transaction_created_datetime) BETWEEN @window_start AND @window_end
),
-- the company's own names, to spot a payee that is really the company itself
self_nm AS (
  SELECT c.company_id,
    ARRAY(SELECT DISTINCT n FROM UNNEST([
        LOWER(TRIM(c.company_name)),
        LOWER(TRIM(c.user_owner_name)),
        LOWER(TRIM(c.company_latest_bank_owner_name))]) n
      WHERE n IS NOT NULL AND n != '') AS self_names
  FROM `paper-prod.data_warehouse_layer.dim__paper__company` c
  WHERE c.company_id IN UNNEST(@company_ids)
)
SELECT
  t.company_id,
  t.digital_payment_id,
  t.order_id,
  t.transaction_created_datetime,
  DATE(t.transaction_created_datetime)              AS transaction_date,
  t.transaction_amount,
  t.partner_id,
  t.partner_name,
  t.digital_payment_type_name                       AS direction,
  t.payment_method_name,

  -- payee is a registered entity: the reviewers' own "beberapa ke PT/CV" heuristic
  CAST(REGEXP_CONTAINS(LOWER(t.partner_name),
    r'(^|[^a-z])(pt|cv|ud|pd|tbk|persero|firma|koperasi|yayasan)([^a-z]|$)')
    AS INT64)                                       AS partner_is_ptcv,

  -- payee name is a single word once legal forms are stripped: the confirmed
  -- single strongest name signal (clean 0.186 vs gestun 0.346)
  CAST(ARRAY_LENGTH(SPLIT(TRIM(REGEXP_REPLACE(REGEXP_REPLACE(
      LOWER(IFNULL(t.partner_name,'')),
      r'\b(pt|cv|ud|pd|tbk|persero|bpk|ibu|bu|mr|mrs|kak|mom|pak|toko)\b',' '),
      r'\s+',' ')), ' ')) = 1 AS INT64)             AS partner_is_single_word,

  -- payee looks like the company itself
  CAST(EXISTS(SELECT 1 FROM UNNEST(s.self_names) n
              WHERE n = LOWER(TRIM(t.partner_name))) AS INT64) AS partner_matches_company,

  -- a negotiated cash-out tends to be round money; a real invoice is an odd number
  CAST(MOD(CAST(t.transaction_amount AS INT64), 1000000) = 0 AS INT64) AS amount_is_round_1m,
  CAST(MOD(CAST(t.transaction_amount AS INT64),  100000) = 0 AS INT64) AS amount_is_round_100k,

  EXTRACT(HOUR FROM t.transaction_created_datetime)  AS hour_of_day,
  CAST(EXTRACT(HOUR FROM t.transaction_created_datetime) < 8
       OR EXTRACT(HOUR FROM t.transaction_created_datetime) >= 20 AS INT64) AS is_offhours,

  -- largest first, so a reviewer opening one company starts where the money is
  ROW_NUMBER() OVER (PARTITION BY t.company_id
                     ORDER BY t.transaction_amount DESC)        AS amount_rank_in_company
FROM t
LEFT JOIN self_nm s USING (company_id)
