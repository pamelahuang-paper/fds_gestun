-- Context around the payer, not the name on the payment.
-- @company_ids : ARRAY<STRING> of companies to build features for.
--
-- payin_selfdealing.sql showed that "the owner pays with the owner's card" is
-- normal here - 81% of clean companies do it. What is not normal is the shape
-- around it: one payer account standing behind several different buyers, a
-- burst of different cards on one payment, and money that all lands on one
-- counterparty. These features measure that shape.

CREATE TEMP FUNCTION norm(s STRING) AS (
  TRIM(REGEXP_REPLACE(REGEXP_REPLACE(REGEXP_REPLACE(LOWER(IFNULL(s, '')),
    r'[^a-z0-9]+', ' '),
    r'\b(pt|cv|ud|pd|tbk|persero|firma|sdr|sdri|bpk|bapak|ibu|bu|mr|mrs|ms|mas|mbak|kak|kakak|mom|pak|toko)\b', ' '),
    r'\s+', ' ')));

WITH base AS (
  SELECT DISTINCT company_id FROM UNNEST(@company_ids) AS company_id),

-- one row per card attempt recorded on a paid transaction
attempt AS (
  SELECT dp.company_id, dp.external_id, norm(dp.partner_user_name) AS pn,
    JSON_VALUE(x, '$.payer_user_id') AS payer_user_id,
    JSON_VALUE(x, '$.card_number')   AS card_number
  FROM `paper-prod.datawarehouse_rpt.pprrsk001_1_dailypoints_1d` dp
  JOIN base USING (company_id),
  UNNEST(JSON_QUERY_ARRAY(dp.credit_card_information_list)) x
  WHERE dp.credit_card_information_list IS NOT NULL),

-- 1. how many different cards were thrown at one payment
per_txn AS (
  SELECT company_id, external_id,
    COUNT(*) AS n_attempts,
    COUNT(DISTINCT card_number) AS n_cards
  FROM attempt WHERE card_number IS NOT NULL GROUP BY 1, 2),

card_agg AS (
  SELECT company_id,
    MAX(n_cards)                                       AS max_cards_in_one_txn,
    MAX(n_attempts)                                    AS max_attempts_in_one_txn,
    ROUND(AVG(n_cards), 4)                             AS avg_cards_per_txn,
    ROUND(AVG(CAST(n_cards >= 2 AS INT64)), 4)         AS pct_txn_multi_card
  FROM per_txn GROUP BY 1),

-- 2. one payer account standing behind several different counterparties
payer AS (
  SELECT company_id, payer_user_id, COUNT(DISTINCT NULLIF(pn, '')) AS n_names,
         COUNT(DISTINCT external_id) AS n_txn
  FROM attempt WHERE payer_user_id IS NOT NULL GROUP BY 1, 2),

payer_agg AS (
  SELECT company_id,
    COUNT(*)                                                   AS n_payer_users,
    MAX(n_names)                                               AS max_names_per_payer,
    ROUND(SAFE_DIVIDE(SUM(IF(n_names >= 2, n_txn, 0)), SUM(n_txn)), 4)
                                                               AS pct_txn_payer_multi_name,
    ROUND(SAFE_DIVIDE(SUM(n_txn), COUNT(*)), 4)                AS avg_txn_per_payer
  FROM payer GROUP BY 1),

-- 3. where the money concentrates, per direction
flow AS (
  SELECT r.company_id, r.digital_payment_type_name AS dir, r.partner_id,
         ANY_VALUE(norm(r.partner_name)) AS pn,
         SUM(r.transaction_amount) AS amt, COUNT(*) AS n_txn
  FROM `paper-prod.data_mart_layer.rpt__raw_data_digital_payments_daily` r
  JOIN base USING (company_id)
  WHERE r.payment_status_name = 'PAID'
    AND r.partner_name IS NOT NULL AND TRIM(r.partner_name) != ''
  GROUP BY 1, 2, 3),

ranked AS (
  SELECT *, SUM(amt) OVER (PARTITION BY company_id, dir) AS dir_amt,
    ROW_NUMBER() OVER (PARTITION BY company_id, dir ORDER BY amt DESC) AS rn
  FROM flow),

top_out AS (
  SELECT company_id,
    ROUND(SAFE_DIVIDE(amt, dir_amt), 4) AS top1_out_partner_amount_share,
    -- a person, not a shop: no business keyword anywhere in the name
    CAST(NOT REGEXP_CONTAINS(pn, r'\b(toko|jaya|abadi|sentosa|makmur|trading|teknik|mandiri|utama|indo|group|store|shop|mart|corp|tbk|ltd|inc)\b')
         AS INT64) AS top1_out_partner_is_personal
  FROM ranked WHERE dir = 'Out' AND rn = 1),

top_in AS (
  SELECT company_id,
    ROUND(SAFE_DIVIDE(amt, dir_amt), 4) AS top1_in_partner_amount_share
  FROM ranked WHERE dir = 'In' AND rn = 1)

SELECT b.company_id,
  c.max_cards_in_one_txn, c.max_attempts_in_one_txn, c.avg_cards_per_txn,
  c.pct_txn_multi_card,
  p.n_payer_users, p.max_names_per_payer, p.pct_txn_payer_multi_name,
  p.avg_txn_per_payer,
  o.top1_out_partner_amount_share, o.top1_out_partner_is_personal,
  i.top1_in_partner_amount_share
FROM base b
LEFT JOIN card_agg  c USING (company_id)
LEFT JOIN payer_agg p USING (company_id)
LEFT JOIN top_out   o USING (company_id)
LEFT JOIN top_in    i USING (company_id)
