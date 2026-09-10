-- =============================================================================
-- Gestun cardholder-identity feature table
-- Produces exactly the 20 columns documented in gestun_cardholder_features.csv
--
-- Grain : one row per payin transaction (dpt_id)
-- Source: data_warehouse_layer.fact__paper__digital_payment_transaction
--         data_warehouse_layer.dim__paper__company
--         data_warehouse_pii_layer.dim__paper__kyc
--
-- DIFFERENCE FROM gestun_cardholder_name_similarity.sql:
--   That file FILTERED to rows with cardholder data. This one keeps ALL payins and
--   exposes has_cardholder_data instead, so the table can be joined straight to a
--   label set without silently dropping 74% of transactions. Identity features are
--   NULL (not 0) where the card data is absent - 0 would assert "no similarity",
--   which is a different claim from "unknown".
--
-- VERIFIED (May-Jul 2026 card payins):
--   cardholder vs PAYER owner  avg 0.630   <- normal: you pay with your own card
--   cardholder vs PAYEE owner  avg 0.065   <- normal: you don't share a name with a supplier
--   payee sim >= 0.9           0.83%       <- the gestun signal
--   card data present          25.7%
--   company_id = buyer_id      205,378 / 205,378 rows
-- =============================================================================

DECLARE start_date DATE DEFAULT DATE '2026-05-01';
DECLARE end_date   DATE DEFAULT DATE '2026-07-31';


CREATE TEMP FUNCTION norm_name(s STRING) AS ((
  SELECT TRIM(REGEXP_REPLACE(REGEXP_REPLACE(REGEXP_REPLACE(UPPER(COALESCE(s, '')),
    r'[^A-Z ]', ' '),
    r'\b(PT|CV|UD|PD|TBK|PERSERO|BAPAK|IBU|BPK|SDR|SDRI|H|HJ|HAJI|DRS|DRA|IR|DR|PROF|ST|SE|SH|MM|MBA|AMD)\b', ' '),
    r'\s+', ' '))
));

CREATE TEMP FUNCTION name_tokens(s STRING) AS ((
  SELECT ARRAY(SELECT DISTINCT t FROM UNNEST(SPLIT(norm_name(s), ' ')) t WHERE LENGTH(t) > 1)
));

CREATE TEMP FUNCTION token_containment(a ARRAY<STRING>, b ARRAY<STRING>) AS ((
  SELECT SAFE_DIVIDE(
    (SELECT COUNT(DISTINCT x) FROM UNNEST(a) x WHERE x IN (SELECT * FROM UNNEST(b))),
    LEAST(ARRAY_LENGTH(a), ARRAY_LENGTH(b)))
));

CREATE TEMP FUNCTION lev_ratio(a STRING, b STRING) AS ((
  SELECT CASE WHEN a = '' OR b = '' THEN NULL
         ELSE 1 - SAFE_DIVIDE(EDIT_DISTANCE(a, b), GREATEST(LENGTH(a), LENGTH(b))) END
));


WITH payin AS (
  SELECT
    dpt_id,
    external_id,
    company_id                                    AS payer_company_id,   -- = buyer_id
    supplier_id                                   AS payee_company_id,
    payment_datetime,
    transaction_grand_total_amount                AS amount,
    payment_method_name,
    success_attempt_card_number                   AS card_number,
    success_attempt_card_holder_data_full_name    AS cardholder_name,
    success_attempt_card_holder_data_email        AS cardholder_token     -- tokenised ID
  FROM `paper-prod.data_warehouse_layer.fact__paper__digital_payment_transaction`
  WHERE DATE(payment_datetime) BETWEEN start_date AND end_date
),

co AS (
  SELECT company_id, user_owner_name, company_latest_bank_owner_name
  FROM `paper-prod.data_warehouse_layer.dim__paper__company`
  QUALIFY ROW_NUMBER() OVER (PARTITION BY company_id ORDER BY user_owner_name) = 1
),

kyc AS (
  SELECT company_id, owner_name AS kyc_owner_name
  FROM `paper-prod.data_warehouse_pii_layer.dim__paper__kyc`
  QUALIFY ROW_NUMBER() OVER (PARTITION BY company_id ORDER BY owner_name) = 1
),

-- reach measured only over rows that actually carry card identity
cardholder_reach AS (
  SELECT cardholder_token,
         COUNT(DISTINCT payee_company_id) AS n_payee_companies_for_cardholder,
         COUNT(DISTINCT payer_company_id) AS n_payer_companies_for_cardholder
  FROM payin
  WHERE cardholder_token IS NOT NULL
  GROUP BY cardholder_token
),

card_reach AS (
  SELECT card_number,
         COUNT(DISTINCT payee_company_id) AS n_payee_companies_for_card
  FROM payin
  WHERE card_number IS NOT NULL
  GROUP BY card_number
),

scored AS (
  SELECT
    p.*,
    payee.user_owner_name                 AS payee_owner_name,
    payer.user_owner_name                 AS payer_owner_name,
    payee.company_latest_bank_owner_name  AS payee_bank_owner_name,
    payee_kyc.kyc_owner_name              AS payee_kyc_owner_name,

    -- NULL rather than 0 when there is no card identity to compare
    IF(p.cardholder_name IS NULL, NULL, GREATEST(
      IFNULL(token_containment(name_tokens(p.cardholder_name),
                               name_tokens(payee.user_owner_name)), 0),
      IFNULL(token_containment(name_tokens(p.cardholder_name),
                               name_tokens(payee_kyc.kyc_owner_name)), 0),
      IFNULL(token_containment(name_tokens(p.cardholder_name),
                               name_tokens(payee.company_latest_bank_owner_name)), 0),
      IFNULL(lev_ratio(norm_name(p.cardholder_name),
                       norm_name(payee.user_owner_name)), 0),
      IFNULL(lev_ratio(norm_name(p.cardholder_name),
                       norm_name(payee_kyc.kyc_owner_name)), 0)
    )) AS cardholder_name_vs_company_owner_sim,

    IF(p.cardholder_name IS NULL, NULL, GREATEST(
      IFNULL(token_containment(name_tokens(p.cardholder_name),
                               name_tokens(payer.user_owner_name)), 0),
      IFNULL(lev_ratio(norm_name(p.cardholder_name),
                       norm_name(payer.user_owner_name)), 0)
    )) AS cardholder_name_vs_payer_owner_sim

  FROM payin p
  LEFT JOIN co  payee     ON payee.company_id     = p.payee_company_id
  LEFT JOIN co  payer     ON payer.company_id     = p.payer_company_id
  LEFT JOIN kyc payee_kyc ON payee_kyc.company_id = p.payee_company_id
)

-- =============================================================================
-- FINAL — column order matches gestun_cardholder_features.csv
-- =============================================================================
SELECT
  ---- key ----
  s.dpt_id,
  s.external_id,
  s.payer_company_id,
  s.payee_company_id,
  s.payment_datetime,

  ---- context (PII) : reviewer inspection only, exclude from the model ----
  s.cardholder_name,
  s.payee_owner_name,
  s.payer_owner_name,

  ---- transaction ----
  s.amount,
  s.payment_method_name,
  IF(s.payer_company_id = s.payee_company_id, 1, 0)        AS is_self_transaction,

  ---- identity similarity ----
  s.cardholder_name_vs_company_owner_sim,
  s.cardholder_name_vs_payer_owner_sim,
  IF(s.cardholder_name IS NULL, NULL,
     IF(norm_name(s.cardholder_name) != ''
        AND norm_name(s.cardholder_name) = norm_name(s.payee_owner_name), 1, 0))
                                                           AS cardholder_name_exact_payee_owner,
  -- the discriminating combination: card matches the RECEIVER but not the BUYER
  IF(s.cardholder_name IS NULL, NULL,
     GREATEST(0, s.cardholder_name_vs_company_owner_sim
                 - s.cardholder_name_vs_payer_owner_sim))  AS identity_direction_gap,

  ---- identity linkage ----
  chr.n_payee_companies_for_cardholder,
  chr.n_payer_companies_for_cardholder,
  cr.n_payee_companies_for_card,
  IF(cr.n_payee_companies_for_card >= 3, 1, 0)             AS card_pays_many_companies,

  ---- coverage ----
  IF(s.cardholder_name IS NULL, 0, 1)                      AS has_cardholder_data

FROM scored s
LEFT JOIN cardholder_reach chr USING (cardholder_token)
LEFT JOIN card_reach       cr  USING (card_number)
;
