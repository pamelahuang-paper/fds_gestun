-- =============================================================================
-- Gestun labelled feature set
--   fds_gestung_actual_label_050826  JOIN  transaction features
--   Grain: one row per labelled external_id (536 rows)
--
-- ⚠️ READ THIS BEFORE MODELLING ON THE CARDHOLDER FEATURES
--
--   Labels run 2026-07-27 to 2026-08-02. Card identity coverage on them:
--       not gestun   122 of 434   (28%)
--       gestun         5 of 102   (4.9%)
--
--   Only FIVE confirmed gestun transactions carry cardholder data, so nothing in
--   the identity family can be validated on this label set.
--
--   Payment method tells the real story:
--       BANK_TRANSFER              44 gestun /   1 clean   -> 97.8% gestun rate
--       QRIS                       46 /  164              -> 21.9%
--       MITRA_PEMBAYARAN_DIGITAL    6 /  147              ->  3.9%
--       CREDIT_CARD                 5 /  122              ->  3.9%   (BELOW baseline)
--
--   Gestun here is a BANK_TRANSFER / QRIS phenomenon, not card-limit conversion.
--   Confirmed positives are also ~2x larger (58.5M vs 27.1M IDR) and more often
--   self-transactions (86% vs 65%).
-- =============================================================================

DECLARE start_date DATE DEFAULT DATE '2026-07-20';   -- covers the label window
DECLARE end_date   DATE DEFAULT DATE '2026-08-05';


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


WITH labels AS (
  SELECT
    TRIM(external_id) AS external_id,
    TRIM(company_id)  AS label_company_id,
    CASE
      WHEN SAFE_CAST(flag AS INT64) IS NOT NULL THEN SAFE_CAST(flag AS INT64)
      WHEN LOWER(CAST(flag AS STRING)) IN ('true','y','yes','fraud','gestun','not legit') THEN 1
      ELSE 0
    END AS is_gestun
  FROM `paper-prod.datascience_public.fds_gestung_actual_label_050826`
  QUALIFY ROW_NUMBER() OVER (PARTITION BY TRIM(external_id) ORDER BY company_id) = 1
),

payin AS (
  SELECT
    dpt_id, external_id,
    company_id                                    AS payer_company_id,
    supplier_id                                   AS payee_company_id,
    payment_datetime,
    transaction_grand_total_amount                AS amount,
    payment_method_name,
    payment_gateway_name,
    transaction_status_note,
    is_user_to_user_flag,
    user_to_user_level_number,
    is_multiple_transaction_flag,
    device_type_name,
    transaction_created_datetime,
    success_attempt_card_number                   AS card_number,
    success_attempt_card_holder_data_full_name    AS cardholder_name,
    success_attempt_card_holder_data_email        AS cardholder_token
  FROM `paper-prod.data_warehouse_layer.fact__paper__digital_payment_transaction`
  WHERE DATE(payment_datetime) BETWEEN start_date AND end_date
),

co AS (
  SELECT company_id, user_owner_name, company_latest_bank_owner_name, company_name
  FROM `paper-prod.data_warehouse_layer.dim__paper__company`
  QUALIFY ROW_NUMBER() OVER (PARTITION BY company_id ORDER BY user_owner_name) = 1
),
kyc AS (
  SELECT company_id, owner_name AS kyc_owner_name
  FROM `paper-prod.data_warehouse_pii_layer.dim__paper__kyc`
  QUALIFY ROW_NUMBER() OVER (PARTITION BY company_id ORDER BY owner_name) = 1
),

card_reach AS (
  SELECT card_number, COUNT(DISTINCT payee_company_id) AS n_payee_companies_for_card
  FROM payin WHERE card_number IS NOT NULL GROUP BY card_number
),
cardholder_reach AS (
  SELECT cardholder_token,
         COUNT(DISTINCT payee_company_id) AS n_payee_companies_for_cardholder,
         COUNT(DISTINCT payer_company_id) AS n_payer_companies_for_cardholder
  FROM payin WHERE cardholder_token IS NOT NULL GROUP BY cardholder_token
)

SELECT
  ---- label ----
  l.external_id,
  l.is_gestun,
  l.label_company_id,
  IF(p.dpt_id IS NULL, 1, 0)                               AS not_found_in_payments,

  ---- keys ----
  p.payer_company_id,
  p.payee_company_id,
  p.payment_datetime,

  ---- transaction: the features that actually separate on this label set ----
  p.payment_method_name,
  p.payment_gateway_name,
  p.amount,
  IF(p.payer_company_id = p.payee_company_id, 1, 0)        AS is_self_transaction,
  IF(p.payee_company_id IS NULL, 1, 0)                     AS payee_is_null,
  p.is_user_to_user_flag,
  p.user_to_user_level_number,
  p.is_multiple_transaction_flag,
  p.device_type_name,
  TIMESTAMP_DIFF(TIMESTAMP(p.payment_datetime),
                 TIMESTAMP(p.transaction_created_datetime), SECOND)
                                                           AS seconds_created_to_paid,
  IF(MOD(CAST(p.amount AS INT64),  1000000) = 0, 1, 0)     AS is_round_1m,
  IF(MOD(CAST(p.amount AS INT64), 10000000) = 0, 1, 0)     AS is_round_10m,

  ---- cardholder identity: only 4.9% coverage on positives, see header ----
  IF(p.cardholder_name IS NULL, 0, 1)                      AS has_cardholder_data,
  IF(p.cardholder_name IS NULL, NULL, GREATEST(
    IFNULL(token_containment(name_tokens(p.cardholder_name),
                             name_tokens(payee.user_owner_name)), 0),
    IFNULL(token_containment(name_tokens(p.cardholder_name),
                             name_tokens(payee_kyc.kyc_owner_name)), 0),
    IFNULL(token_containment(name_tokens(p.cardholder_name),
                             name_tokens(payee.company_latest_bank_owner_name)), 0),
    IFNULL(lev_ratio(norm_name(p.cardholder_name), norm_name(payee.user_owner_name)), 0)
  ))                                                       AS cardholder_name_vs_company_owner_sim,
  IF(p.cardholder_name IS NULL, NULL, GREATEST(
    IFNULL(token_containment(name_tokens(p.cardholder_name),
                             name_tokens(payer.user_owner_name)), 0),
    IFNULL(lev_ratio(norm_name(p.cardholder_name), norm_name(payer.user_owner_name)), 0)
  ))                                                       AS cardholder_name_vs_payer_owner_sim,
  cr.n_payee_companies_for_card,
  chr.n_payee_companies_for_cardholder,
  chr.n_payer_companies_for_cardholder,

  ---- PII: reviewer context, exclude from the model ----
  p.cardholder_name,
  payee.user_owner_name                                    AS payee_owner_name,
  payer.user_owner_name                                    AS payer_owner_name,
  payee.company_name                                       AS payee_company_name

FROM labels l
LEFT JOIN payin p        ON p.external_id       = l.external_id
LEFT JOIN co  payee      ON payee.company_id    = p.payee_company_id
LEFT JOIN co  payer      ON payer.company_id    = p.payer_company_id
LEFT JOIN kyc payee_kyc  ON payee_kyc.company_id = p.payee_company_id
LEFT JOIN card_reach       cr  ON cr.card_number = p.card_number
LEFT JOIN cardholder_reach chr ON chr.cardholder_token = p.cardholder_token
ORDER BY l.is_gestun DESC, p.payment_datetime
;
