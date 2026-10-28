-- Pay-in side self-dealing: the company paying itself.
-- @company_ids : ARRAY<STRING> of companies to build features for.
--
-- payout_selfdealing.sql only looks at 'Out' partners. Two gestun patterns
-- slip past it:
--   1. the owner appears as the BUYER on an 'In' transaction, paying the
--      company's own invoice with a credit card;
--   2. the card itself is in the owner's name, whoever the partner is.
-- Same normalisation and same name-match rule as payout_selfdealing.sql, so the
-- two families are comparable.

CREATE TEMP FUNCTION norm(s STRING) AS (
  TRIM(REGEXP_REPLACE(REGEXP_REPLACE(REGEXP_REPLACE(LOWER(IFNULL(s, '')),
    r'[^a-z0-9]+', ' '),
    r'\b(pt|cv|ud|pd|tbk|persero|firma|sdr|sdri|bpk|bapak|ibu|bu|mr|mrs|ms|mas|mbak|kak|kakak|mom|pak|toko)\b', ' '),
    r'\s+', ' ')));

-- normalised equality, or every >=3-char token of the shorter name inside the longer
CREATE TEMP FUNCTION name_match(s STRING, p STRING) AS (
  s = p OR (
    (SELECT COUNT(*) FROM UNNEST(SPLIT(s, ' ')) t WHERE LENGTH(t) >= 3) > 0
    AND (SELECT COUNT(*) FROM UNNEST(SPLIT(p, ' ')) t WHERE LENGTH(t) >= 3) > 0
    AND (SELECT COUNT(*) FROM UNNEST(SPLIT(s, ' ')) t
         WHERE LENGTH(t) >= 3 AND t IN UNNEST(SPLIT(p, ' '))) >=
        LEAST((SELECT COUNT(*) FROM UNNEST(SPLIT(s, ' ')) t WHERE LENGTH(t) >= 3),
              (SELECT COUNT(*) FROM UNNEST(SPLIT(p, ' ')) t WHERE LENGTH(t) >= 3))));

WITH base AS (
  SELECT DISTINCT company_id FROM UNNEST(@company_ids) AS company_id),

-- the three names that stand for "the company itself"
self_nm AS (
  SELECT c.company_id,
    ARRAY(SELECT DISTINCT n FROM UNNEST([norm(c.company_name), norm(c.user_owner_name),
                                         norm(c.company_latest_bank_owner_name)]) n
          WHERE n != '') AS self_names
  FROM `paper-prod.data_warehouse_layer.dim__paper__company` c
  JOIN base USING (company_id)),

-- 1. 'In' partners: who paid the company's invoices
in_partner AS (
  SELECT r.company_id, r.partner_id, ANY_VALUE(norm(r.partner_name)) AS pn,
         COUNT(*) AS n_txn, SUM(r.transaction_amount) AS amt
  FROM `paper-prod.data_mart_layer.rpt__raw_data_digital_payments_daily` r
  JOIN base USING (company_id)
  WHERE r.payment_status_name = 'PAID' AND r.digital_payment_type_name = 'In'
    AND r.partner_name IS NOT NULL AND TRIM(r.partner_name) != ''
  GROUP BY 1, 2),

in_scored AS (
  SELECT p.company_id, p.n_txn, p.amt,
    CAST(EXISTS(SELECT 1 FROM UNNEST(sn.self_names) s WHERE name_match(s, p.pn)) AS INT64)
      AS eq_self
  FROM in_partner p
  LEFT JOIN self_nm sn USING (company_id)),

in_agg AS (
  SELECT company_id,
    COUNT(*)                                                AS n_in_partners,
    ROUND(AVG(eq_self), 4)                                  AS pct_in_partner_eq_self,
    ROUND(SAFE_DIVIDE(SUM(n_txn * eq_self), SUM(n_txn)), 4) AS pct_in_txn_partner_eq_self,
    ROUND(SAFE_DIVIDE(SUM(amt * eq_self), SUM(amt)), 4)     AS pct_amount_in_partner_eq_self,
    MAX(eq_self)                                            AS has_in_partner_eq_self
  FROM in_scored GROUP BY 1),

-- 2. card holder name, from the card attempts recorded on each paid transaction.
--    Any direction: a card in the owner's name is self-funding whether the
--    money then goes In or Out. Rows with no named holder are left out, so the
--    share is "of card payments where the holder is known".
card_row AS (
  SELECT dp.company_id, dp.external_id, dp.amount,
    ARRAY(SELECT DISTINCT n FROM (
            SELECT norm(JSON_VALUE(x, '$.card_holder_name')) AS n
            FROM UNNEST(JSON_QUERY_ARRAY(dp.credit_card_information_list)) x)
          WHERE n != '') AS holders
  FROM `paper-prod.datawarehouse_rpt.pprrsk001_1_dailypoints_1d` dp
  JOIN base USING (company_id)
  WHERE dp.credit_card_information_list IS NOT NULL),

card_scored AS (
  SELECT r.company_id, r.external_id, r.amount,
    CAST(EXISTS(SELECT 1 FROM UNNEST(sn.self_names) s, UNNEST(r.holders) h
                WHERE name_match(s, h)) AS INT64) AS eq_self
  FROM card_row r
  LEFT JOIN self_nm sn USING (company_id)
  WHERE ARRAY_LENGTH(r.holders) > 0),

card_agg AS (
  SELECT company_id,
    COUNT(DISTINCT external_id)                               AS n_cc_txns_named,
    ROUND(SAFE_DIVIDE(COUNT(DISTINCT IF(eq_self = 1, external_id, NULL)),
                      COUNT(DISTINCT external_id)), 4)        AS pct_cc_txn_holder_eq_self,
    ROUND(SAFE_DIVIDE(SUM(amount * eq_self), SUM(amount)), 4) AS pct_cc_amount_holder_eq_self,
    MAX(eq_self)                                              AS has_cc_holder_eq_self
  FROM card_scored GROUP BY 1)

SELECT b.company_id,
  i.n_in_partners, i.pct_in_partner_eq_self, i.pct_in_txn_partner_eq_self,
  i.pct_amount_in_partner_eq_self, i.has_in_partner_eq_self,
  c.n_cc_txns_named, c.pct_cc_txn_holder_eq_self, c.pct_cc_amount_holder_eq_self,
  c.has_cc_holder_eq_self
FROM base b
LEFT JOIN in_agg i USING (company_id)
LEFT JOIN card_agg c USING (company_id)
