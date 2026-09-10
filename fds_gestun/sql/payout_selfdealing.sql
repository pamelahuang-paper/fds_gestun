-- Extracted from FDS_Gestun_Combined_Features.ipynb.
-- @company_ids : ARRAY<STRING> of companies to build features for.
-- Edit this file, not the notebook: the notebook is exploration, this is the source of truth.

CREATE TEMP FUNCTION norm(s STRING) AS (
  TRIM(REGEXP_REPLACE(REGEXP_REPLACE(REGEXP_REPLACE(LOWER(IFNULL(s, '')),
    r'[^a-z0-9]+', ' '),
    r'\b(pt|cv|ud|pd|tbk|persero|firma|sdr|sdri|bpk|bapak|ibu|bu|mr|mrs|ms|mas|mbak|kak|kakak|mom|pak|toko)\b', ' '),
    r'\s+', ' ')));

WITH base AS (
  SELECT company_id, lbl AS is_gestun FROM (
    SELECT company_id, MIN(is_gestun) AS lbl, COUNT(DISTINCT is_gestun) AS n_lab
    FROM (SELECT company_id, 0 AS is_gestun
   FROM UNNEST(@company_ids) AS company_id) GROUP BY company_id)
  WHERE n_lab = 1),

-- the three names that stand for "the company itself"
self_nm AS (
  SELECT c.company_id,
    ARRAY(SELECT DISTINCT n FROM UNNEST([norm(c.company_name), norm(c.user_owner_name),
                                         norm(c.company_latest_bank_owner_name)]) n
          WHERE n != '') AS self_names
  FROM `paper-prod.data_warehouse_layer.dim__paper__company` c
  JOIN base USING (company_id)),

-- join base FIRST: rddp is ~8M rows and only 535 companies are labelled
out_txn AS (
  SELECT r.company_id, r.partner_id, r.partner_name, r.transaction_amount
  FROM `paper-prod.data_mart_layer.rpt__raw_data_digital_payments_daily` r
  JOIN base USING (company_id)
  WHERE r.payment_status_name = 'PAID' AND r.digital_payment_type_name = 'Out'
    AND r.partner_name IS NOT NULL AND TRIM(r.partner_name) != ''),

acct AS (
  SELECT DISTINCT d.company_id, norm(d.finance_account_bank_account_name) AS an
  FROM `paper-prod.data_warehouse_layer.fact__paper__digpay_disbursement_transaction` d
  JOIN base USING (company_id)
  WHERE d.finance_account_bank_account_name IS NOT NULL
    AND norm(d.finance_account_bank_account_name) != ''),
acct_arr AS (SELECT company_id, ARRAY_AGG(an) AS accts FROM acct GROUP BY 1),

partner AS (
  SELECT company_id, partner_id, ANY_VALUE(norm(partner_name)) AS pn,
         COUNT(*) AS n_txn, SUM(transaction_amount) AS amt
  FROM out_txn GROUP BY 1, 2),

-- match = normalised equality, or every >=3-char token of the shorter name inside the longer
scored AS (
  SELECT p.company_id, p.partner_id, p.n_txn, p.amt,
    CAST((SELECT MAX(CASE WHEN s = p.pn THEN 1
            WHEN (SELECT COUNT(*) FROM UNNEST(SPLIT(s, ' ')) t WHERE LENGTH(t) >= 3
                    AND t IN UNNEST(SPLIT(p.pn, ' '))) >=
                 LEAST((SELECT COUNT(*) FROM UNNEST(SPLIT(s, ' ')) t WHERE LENGTH(t) >= 3),
                       (SELECT COUNT(*) FROM UNNEST(SPLIT(p.pn, ' ')) t WHERE LENGTH(t) >= 3))
                 AND (SELECT COUNT(*) FROM UNNEST(SPLIT(s, ' ')) t WHERE LENGTH(t) >= 3) > 0
                 AND (SELECT COUNT(*) FROM UNNEST(SPLIT(p.pn, ' ')) t WHERE LENGTH(t) >= 3) > 0
            THEN 1 ELSE 0 END) FROM UNNEST(sn.self_names) s) = 1 AS INT64) AS eq_self,
    CAST((SELECT MAX(CASE WHEN a = p.pn THEN 1
            WHEN (SELECT COUNT(*) FROM UNNEST(SPLIT(a, ' ')) t WHERE LENGTH(t) >= 3
                    AND t IN UNNEST(SPLIT(p.pn, ' '))) >=
                 LEAST((SELECT COUNT(*) FROM UNNEST(SPLIT(a, ' ')) t WHERE LENGTH(t) >= 3),
                       (SELECT COUNT(*) FROM UNNEST(SPLIT(p.pn, ' ')) t WHERE LENGTH(t) >= 3))
                 AND (SELECT COUNT(*) FROM UNNEST(SPLIT(a, ' ')) t WHERE LENGTH(t) >= 3) > 0
                 AND (SELECT COUNT(*) FROM UNNEST(SPLIT(p.pn, ' ')) t WHERE LENGTH(t) >= 3) > 0
            THEN 1 ELSE 0 END) FROM UNNEST(aa.accts) a) = 1 AS INT64) AS eq_payout_acct,
    CAST(aa.accts IS NOT NULL AS INT64) AS has_acct
  FROM partner p
  LEFT JOIN self_nm  sn USING (company_id)
  LEFT JOIN acct_arr aa USING (company_id)),

agg AS (
  SELECT company_id,
    COUNT(*) AS n_out_partners, SUM(n_txn) AS n_out_txns,

    -- 1. partner name == the company / its owner / its registered bank owner
    ROUND(AVG(eq_self), 4)                                    AS pct_out_partner_eq_self,
    ROUND(SAFE_DIVIDE(SUM(n_txn * eq_self), SUM(n_txn)), 4)   AS pct_out_txn_partner_eq_self,
    ROUND(SAFE_DIVIDE(SUM(amt * eq_self), SUM(amt)), 4)       AS pct_amount_out_partner_eq_self,
    MAX(eq_self)                                              AS has_out_partner_eq_self,

    -- 2. partner name == the payout account the money lands in.
    --    NULL, not 0, when the company has no disbursement account on file.
    ROUND(AVG(IF(has_acct = 1, eq_payout_acct, NULL)), 4)     AS pct_out_partner_eq_payout_acct,
    ROUND(SAFE_DIVIDE(SUM(IF(has_acct = 1, n_txn * eq_payout_acct, 0)),
                      SUM(IF(has_acct = 1, n_txn, NULL))), 4) AS pct_out_txn_partner_eq_payout_acct,
    ROUND(SAFE_DIVIDE(SUM(IF(has_acct = 1, amt * eq_payout_acct, 0)),
                      SUM(IF(has_acct = 1, amt, NULL))), 4)   AS pct_amount_out_partner_eq_payout_acct,
    MAX(IF(has_acct = 1, eq_payout_acct, NULL))               AS has_out_partner_eq_payout_acct
  FROM scored GROUP BY 1)

SELECT base.company_id, base.is_gestun, agg.* EXCEPT (company_id)
FROM base LEFT JOIN agg USING (company_id)
