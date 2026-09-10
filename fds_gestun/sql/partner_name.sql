-- Extracted from FDS_Gestun_Combined_Features.ipynb.
-- @company_ids : ARRAY<STRING> of companies to build features for.
-- Edit this file, not the notebook: the notebook is exploration, this is the source of truth.

WITH base AS (
  SELECT company_id, lbl AS is_gestun FROM (
    SELECT company_id, MIN(is_gestun) AS lbl, COUNT(DISTINCT is_gestun) AS n_lab
    FROM (SELECT company_id, 0 AS is_gestun
   FROM UNNEST(@company_ids) AS company_id) GROUP BY company_id)
  WHERE n_lab = 1),

rddp AS (
  SELECT company_id, partner_id, partner_name, transaction_amount
  FROM `paper-prod.data_mart_layer.rpt__raw_data_digital_payments_daily`
  WHERE payment_status_name = 'PAID'),

-- one cleaning pass, reused by every flag below
clean AS (
  SELECT company_id, partner_id, partner_name, transaction_amount,
    -- drop phone numbers, bracketed asides and separator punctuation, then collapse spaces
    TRIM(REGEXP_REPLACE(REGEXP_REPLACE(REGEXP_REPLACE(REGEXP_REPLACE(
      IFNULL(partner_name, ''),
      r'(\+?62|\b0)[\s\-]?8[0-9\s\-]{7,}', ' '),
      r'\([^)]*\)', ' '),
      r'[^A-Za-z0-9]+', ' '),
      r'\s+', ' ')) AS nm_raw
  FROM rddp),

tok AS (
  SELECT *,
    -- strip legal forms and honorifics BEFORE counting words, or every PT/CV name
    -- escapes the single-word flag on a technicality
    TRIM(REGEXP_REPLACE(REGEXP_REPLACE(LOWER(nm_raw),
      r'\b(pt|cv|ud|pd|tbk|persero|firma|bpk|bapak|ibu|bu|sdr|sdri|mr|mrs|ms|mas|mbak|kak|kakak|mom|dad|pak)\b', ' '),
      r'\s+', ' ')) AS core
  FROM clean),

flag AS (
  SELECT company_id, partner_id, transaction_amount, nm_raw, core,
    IF(core = '', NULL, ARRAY_LENGTH(SPLIT(core, ' '))) AS n_words,
    LENGTH(core) AS core_len,

    -- one word once legal forms and honorifics are gone
    CAST(core != '' AND ARRAY_LENGTH(SPLIT(core, ' ')) = 1 AS INT64) AS is_single_word,

    -- singkatan: a short all-caps token, a vowel-less token, or dotted initials
    -- (IEC, SBY, CVSK, A.B.C)
    CAST(core != '' AND (
         (ARRAY_LENGTH(SPLIT(core, ' ')) = 1 AND LENGTH(core) <= 5
          AND (nm_raw = UPPER(nm_raw) OR NOT REGEXP_CONTAINS(core, r'[aeiou]')))
      OR REGEXP_CONTAINS(core, r'(^| )[bcdfghjklmnpqrstvwxyz]{2,5}( |$)')
      OR REGEXP_CONTAINS(nm_raw, r'(^| )([A-Z]\s?\.){2,}')
    ) AS INT64) AS is_abbrev,

    -- no merchant/business token anywhere -> reads as a person, not a shop
    CAST(core != '' AND NOT REGEXP_CONTAINS(core,
      r'\b(toko|shop|store|mart|market|grosir|agen|distributor|supplier|jaya|abadi|sejahtera|sejati|makmur|sentosa|mandiri|utama|indonesia|nusantara|group|grup|karya|sukses|berkah|anugerah|cahaya|sinar|mitra|prima|global|tehnik|teknik|teknologi|digital|media|logistik|trans|motor|cell|celluler|ponsel|kitchen|cafe|resto|catering|laundry|salon|klinik|apotek|farma|konveksi|textile|tekstil|plastik|besi|bangunan|material|properti|property|servis|service|solusi|sarana|usaha|dagang|niaga|trading|perkasa|bersama)\b'
    ) AS INT64) AS looks_personal,

    CAST(core != '' AND LENGTH(core) <= 4 AS INT64)                 AS is_very_short,
    CAST(nm_raw != '' AND nm_raw = UPPER(nm_raw)
         AND REGEXP_CONTAINS(nm_raw, r'[A-Z]{2,}') AS INT64)        AS is_allcaps,
    CAST(REGEXP_CONTAINS(nm_raw, r'[0-9]') AS INT64)                AS has_digit,
    CAST(partner_name IS NULL OR TRIM(partner_name) = '' AS INT64)  AS is_missing_name
  FROM tok),

-- distinct-partner grain: each partner counted once however often it is paid
per_partner AS (
  SELECT company_id, partner_id,
    MAX(is_single_word) AS is_single_word, MAX(is_abbrev)     AS is_abbrev,
    MAX(looks_personal) AS looks_personal, MAX(is_very_short) AS is_very_short,
    MAX(is_allcaps)     AS is_allcaps,     MAX(has_digit)     AS has_digit,
    MAX(n_words) AS n_words, MAX(core_len) AS core_len,
    MAX(is_missing_name) AS is_missing_name
  FROM flag WHERE partner_id IS NOT NULL GROUP BY 1, 2),

by_partner AS (
  SELECT company_id,
    COUNT(*) AS n_named_partners,
    ROUND(AVG(is_single_word), 4) AS pct_partner_single_word,
    ROUND(AVG(is_abbrev),      4) AS pct_partner_abbrev,
    ROUND(AVG(looks_personal), 4) AS pct_partner_personal_name,
    ROUND(AVG(is_very_short),  4) AS pct_partner_very_short_name,
    ROUND(AVG(is_allcaps),     4) AS pct_partner_allcaps_name,
    ROUND(AVG(has_digit),      4) AS pct_partner_name_has_digit,
    ROUND(AVG(GREATEST(is_single_word, is_abbrev)), 4) AS pct_partner_sus_name,
    ROUND(AVG(n_words),  3) AS avg_partner_name_words,
    ROUND(AVG(core_len), 2) AS avg_partner_name_len
  FROM per_partner WHERE is_missing_name = 0 GROUP BY 1),

-- transaction- and amount-weighted: paying a one-word partner 90% of the time is the
-- signal, not merely having one such partner somewhere in a long list
by_txn AS (
  SELECT company_id,
    COUNT(*) AS n_partner_txns,
    ROUND(AVG(is_missing_name), 4) AS pct_txn_partner_name_missing,
    ROUND(AVG(IF(is_missing_name = 1, NULL, is_single_word)), 4) AS pct_txn_single_word_partner,
    ROUND(AVG(IF(is_missing_name = 1, NULL, is_abbrev)),      4) AS pct_txn_abbrev_partner,
    ROUND(AVG(IF(is_missing_name = 1, NULL, looks_personal)), 4) AS pct_txn_personal_name_partner,
    ROUND(AVG(IF(is_missing_name = 1, NULL, GREATEST(is_single_word, is_abbrev))), 4) AS pct_txn_sus_name_partner,
    ROUND(SAFE_DIVIDE(
      SUM(IF(is_missing_name = 0 AND GREATEST(is_single_word, is_abbrev) = 1, transaction_amount, 0)),
      SUM(IF(is_missing_name = 0, transaction_amount, NULL))), 4) AS pct_amount_sus_name_partner
  FROM flag GROUP BY 1)

SELECT base.company_id, base.is_gestun,
       by_partner.* EXCEPT (company_id), by_txn.* EXCEPT (company_id)
FROM base
LEFT JOIN by_partner USING (company_id)
LEFT JOIN by_txn     USING (company_id)
