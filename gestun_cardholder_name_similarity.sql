-- =============================================================================
-- cardholder_name_vs_company_owner_sim
--
-- Does the person whose CARD paid match the owner of the company RECEIVING the
-- money? On this platform that is the core gestun signature: one human, two
-- identities, money converted from card limit to cash.
--
-- VERIFIED AGAINST PRODUCTION (2026-08-05, May-Jul 2026, card payins):
--
--                       n        sim to PAYER owner   sim to PAYEE owner   payee>=0.9
--   buyer -> supplier   84,601         0.630                0.065          704 (0.83%)
--   self-transaction    55,932         0.000                0.000            0
--
--   Normal commerce: the cardholder matches the PAYER's owner (you pay with your
--   own card) and NOT the PAYEE's (you do not share a name with your supplier).
--   The 0.83% where the cardholder DOES match the payee's owner is the signal.
--
-- TWO CORRECTIONS FROM THE FIRST DRAFT (both found in the data):
--   1. company_id is the PAYER, not the receiver. It equals buyer_id in 205,378
--      of 205,378 rows. The receiving side is supplier_id. Joining the company
--      dimension on company_id measured "did the buyer pay with their own card",
--      which is normally true and therefore useless.
--   2. success_attempt_card_holder_data_email / _phone_number are TOKENISED, not
--      plaintext (all emails 'uni...' at length 30-31, phones length 13). They
--      cannot be matched against company contact details - zero matches in
--      143,322 rows. They ARE usable as a pseudonymous cardholder ID for
--      cross-company linkage. See §cardholder_reach at the bottom.
--
-- EDIT_DISTANCE alone is not enough: EDIT_DISTANCE('BUDI SANTOSO','SANTOSO BUDI')
-- = 10. Indonesian names reorder and carry titles, so the score combines a
-- character measure with a token measure and takes the better of the two.
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

-- |A ∩ B| / min(|A|,|B|)  — order-insensitive, handles "BUDI SANTOSO" vs "BUDI"
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
    supplier_id                                   AS payee_company_id,   -- the RECEIVER
    payment_datetime,
    transaction_grand_total_amount                AS amount,
    payment_method_name,
    success_attempt_card_number                   AS card_number,
    success_attempt_card_holder_data_full_name    AS cardholder_name,
    success_attempt_card_holder_data_email        AS cardholder_token_email,  -- tokenised ID
    success_attempt_card_holder_data_phone_number AS cardholder_token_phone   -- tokenised ID
  FROM `paper-prod.data_warehouse_layer.fact__paper__digital_payment_transaction`
  WHERE DATE(payment_datetime) BETWEEN start_date AND end_date
    AND success_attempt_card_holder_data_full_name IS NOT NULL
    AND supplier_id IS NOT NULL
),

co AS (
  SELECT company_id, user_owner_name, company_name, company_latest_bank_owner_name
  FROM `paper-prod.data_warehouse_layer.dim__paper__company`
  QUALIFY ROW_NUMBER() OVER (PARTITION BY company_id ORDER BY user_owner_name) = 1
),

kyc AS (
  SELECT company_id, owner_name AS kyc_owner_name
  FROM `paper-prod.data_warehouse_pii_layer.dim__paper__kyc`
  QUALIFY ROW_NUMBER() OVER (PARTITION BY company_id ORDER BY owner_name) = 1
),

-- how many distinct companies has this cardholder paid? (pseudonymous ID)
cardholder_reach AS (
  SELECT
    cardholder_token_email,
    COUNT(DISTINCT payee_company_id) AS n_payee_companies_for_cardholder,
    COUNT(DISTINCT payer_company_id) AS n_payer_companies_for_cardholder
  FROM payin
  WHERE cardholder_token_email IS NOT NULL
  GROUP BY cardholder_token_email
),

card_reach AS (
  SELECT card_number,
         COUNT(DISTINCT payee_company_id) AS n_payee_companies_for_card
  FROM payin WHERE card_number IS NOT NULL
  GROUP BY card_number
)

SELECT
  p.dpt_id,
  p.external_id,
  p.payer_company_id,
  p.payee_company_id,
  p.payment_datetime,
  p.amount,
  p.payment_method_name,

  -- reviewer context; drop before modelling
  p.cardholder_name,
  payee.user_owner_name AS payee_owner_name,
  payer.user_owner_name AS payer_owner_name,

  IF(p.payer_company_id = p.payee_company_id, 1, 0) AS is_self_transaction,

  -- ================= THE FEATURE =================
  -- cardholder vs the RECEIVING company's owner. High = one person, both sides.
  GREATEST(
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
  ) AS cardholder_name_vs_company_owner_sim,

  -- control: cardholder vs the PAYING company's owner. Normally HIGH (~0.63).
  -- Low here + high above = the card does not belong to the buyer either.
  GREATEST(
    IFNULL(token_containment(name_tokens(p.cardholder_name),
                             name_tokens(payer.user_owner_name)), 0),
    IFNULL(lev_ratio(norm_name(p.cardholder_name),
                     norm_name(payer.user_owner_name)), 0)
  ) AS cardholder_name_vs_payer_owner_sim,

  -- exact match after normalisation - highest precision
  IF(norm_name(p.cardholder_name) != ''
     AND norm_name(p.cardholder_name) = norm_name(payee.user_owner_name), 1, 0)
     AS cardholder_name_exact_payee_owner,

  -- ================= linkage via the tokenised cardholder ID =================
  chr.n_payee_companies_for_cardholder,
  chr.n_payer_companies_for_cardholder,
  cr.n_payee_companies_for_card,
  -- one card paying many unrelated receivers = a gestun broker's client base
  IF(cr.n_payee_companies_for_card >= 3, 1, 0) AS card_pays_many_companies

FROM payin p
LEFT JOIN co  payee     ON payee.company_id     = p.payee_company_id
LEFT JOIN co  payer     ON payer.company_id     = p.payer_company_id
LEFT JOIN kyc payee_kyc ON payee_kyc.company_id = p.payee_company_id
LEFT JOIN cardholder_reach chr USING (cardholder_token_email)
LEFT JOIN card_reach       cr  USING (card_number)
;
