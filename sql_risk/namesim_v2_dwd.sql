-- ###########################################################################
-- NAMESIM V2 -> PRODUCTION
-- Mengisi paper-prod.datawarehouse_dwd.dim_digitalpayment_transaction_namesim_v2
-- Logika diambil dari migration_testing.namesim_v2_pamela (dibuat 2026-09-14).
--
-- Perbedaan dari versi migration_testing:
--   1. Target pindah ke datawarehouse_dwd (dataset produksi).
--   2. Tambah kolom bulk_key -- ada di schema target, tidak ada di v2_pamela.
--   3. MERGE ... UPDATE sekarang me-refresh SEMUA kolom hasil hitungan,
--      bukan cuma sebagian. Versi lama tidak pernah memperbarui kolom *_sim
--      dan *_list, jadi kalau logika/threshold berubah, baris lama tetap
--      memakai nilai lama tanpa ketahuan.
--   4. Window dibuat lewat DECLARE supaya bisa dipakai backfill.
--
-- Backfill: query ini menghitung ulang dari fct_digitalpayment_transaction_all_n_1d,
-- jadi tidak terbatas pada coverage v2_pamela (2026-08-24 ke atas). Untuk
-- menambal L1A yang hilang, set d_start = '2026-08-31'.
-- ###########################################################################

-- 31 hari, DISAMAKAN dengan window DELETE di dailypoints.
-- dailypoints menghapus+menulis ulang 31 hari terakhir setiap run. Kalau
-- namesim cuma punya 7 hari, 24 hari sisanya dapat l1a_point NULL lagi
-- setiap hari. Dua window ini harus sama.
DECLARE d_start      DATE    DEFAULT DATE_SUB(CURRENT_DATE('Asia/Jakarta'), INTERVAL 31 DAY);
DECLARE d_end        DATE    DEFAULT DATE_SUB(CURRENT_DATE('Asia/Jakarta'), INTERVAL 1 DAY);
DECLARE t_suspicious FLOAT64 DEFAULT 0.40;
DECLARE t_similar    FLOAT64 DEFAULT 0.85;


CREATE TEMP FUNCTION norm(s STRING) AS ((
  TRIM(
    REGEXP_REPLACE(
      REGEXP_REPLACE(
        REGEXP_REPLACE(UPPER(IFNULL(s, '')), r'[^A-Z0-9 ]', ' '),
        r'\b(PT|CV|UD|TBK|PERSERO|PERUSAHAAN|BAPAK|IBU|BP|SDR)\b', ' '),
      r'\s+', ' '))
));

CREATE TEMP FUNCTION sim(a STRING, b STRING) AS ((
  -- NULL, bukan 0, kalau namanya kosong. "Tidak bisa dinilai" beda
  -- artinya dengan "tidak mirip".
  CASE
    WHEN LENGTH(norm(a)) = 0 OR LENGTH(norm(b)) = 0 THEN CAST(NULL AS FLOAT64)
    ELSE
      1 - SAFE_DIVIDE(
        EDIT_DISTANCE(norm(a), norm(b)),
        GREATEST(LENGTH(norm(a)), LENGTH(norm(b))))
    END
));


CREATE TABLE IF NOT EXISTS
  `paper-prod.datawarehouse_dwd.dim_digitalpayment_transaction_namesim_v2`
(
  payment_ds DATE,
  company_id STRING,
  order_id STRING,
  user_company_name STRING,
  user_name STRING,
  user_bank_account_name STRING,
  partner_name STRING,
  partner_bank_account_name STRING,
  user_partner_sim FLOAT64,
  company_partner_sim FLOAT64,
  userfinacc_partner_sim FLOAT64,
  user_partnerfinacc_sim FLOAT64,
  company_partnerfinacc_sim FLOAT64,
  userfinacc_partnerfinacc_sim FLOAT64,
  similarity_category STRING,
  final_score FLOAT64,
  highest_category STRING,
  bulk_key STRING,
  total_bulk_payment_trx FLOAT64,
  total_suspicious_trx FLOAT64,
  total_similar_trx FLOAT64,
  similarity_category_list STRING,
  final_score_list STRING,
  highest_category_list STRING,
  computed_at TIMESTAMP
)
PARTITION BY payment_ds;


CREATE TEMP TABLE staged AS
WITH
  line AS (              -- 1 baris per (order_id, invoice_number)
    SELECT
      DATE(payment_ds_rddp) AS payment_ds,
      CAST(company_id AS STRING) AS company_id,
      CAST(external_id AS STRING) AS order_id,
      CAST(invoice_number AS STRING) AS invoice_number,
      user_company_name,
      COALESCE(user_owner_name, user_owner_name_kyc) AS user_name,
      COALESCE(
        pin_user_bankaccount_name1,
        pin_user_bankaccount_name2,
        pin_user_bankaccount_name3) AS user_bank_account_name,
      partner_user_name AS partner_name,
      COALESCE(
        pout_partner_bankaccount_name1,
        pout_partner_bankaccount_name2,
        pout_partner_bankaccount_name3) AS partner_bank_account_name
    FROM `paper-prod.datawarehouse_dwd.fct_digitalpayment_transaction_all_n_1d`
    WHERE
      LOWER(transaction_status_note) = 'paid'
      AND DATE(payment_ds_rddp) BETWEEN d_start AND d_end
  ),
  scored AS (            -- 6 perbandingan nama
    SELECT
      *,
      sim(user_name, partner_name) AS user_partner_sim,
      sim(user_company_name, partner_name) AS company_partner_sim,
      sim(user_bank_account_name, partner_name) AS userfinacc_partner_sim,
      sim(user_name, partner_bank_account_name) AS user_partnerfinacc_sim,
      sim(user_company_name, partner_bank_account_name)
        AS company_partnerfinacc_sim,
      sim(user_bank_account_name, partner_bank_account_name)
        AS userfinacc_partnerfinacc_sim
    FROM line
  ),
  topped AS (            -- ambil yang paling mirip + nama pasangannya
    SELECT
      s.*,
      (
        SELECT AS STRUCT x.cat, x.score
        FROM
          UNNEST([
            STRUCT('user_partner_sim' AS cat, s.user_partner_sim AS score),
            ('company_partner_sim', s.company_partner_sim),
            ('userfinacc_partner_sim', s.userfinacc_partner_sim),
            ('user_partnerfinacc_sim', s.user_partnerfinacc_sim),
            ('company_partnerfinacc_sim', s.company_partnerfinacc_sim),
            ('userfinacc_partnerfinacc_sim', s.userfinacc_partnerfinacc_sim)])
            AS x
        WHERE x.score IS NOT NULL
        ORDER BY x.score DESC
        LIMIT 1
      ) AS top
    FROM scored s
  ),
  classified AS (        -- masih level invoice
    SELECT
      * EXCEPT (top),
      top.score AS line_score,
      top.cat AS line_category,
      CASE
        WHEN top.score IS NULL THEN 'Unscored'
        WHEN top.score >= t_similar THEN 'Similar'
        WHEN top.score >= t_suspicious THEN 'Suspicious'
        ELSE 'Not Similar'
        END AS line_similarity_category
    FROM topped
  )
SELECT                   -- naik ke level order
  ANY_VALUE(payment_ds) AS payment_ds,
  ANY_VALUE(company_id) AS company_id,
  order_id,
  ANY_VALUE(user_company_name) AS user_company_name,
  ANY_VALUE(user_name) AS user_name,
  ANY_VALUE(user_bank_account_name) AS user_bank_account_name,
  ANY_VALUE(partner_name) AS partner_name,
  ANY_VALUE(partner_bank_account_name) AS partner_bank_account_name,
  MAX(user_partner_sim) AS user_partner_sim,
  MAX(company_partner_sim) AS company_partner_sim,
  MAX(userfinacc_partner_sim) AS userfinacc_partner_sim,
  MAX(user_partnerfinacc_sim) AS user_partnerfinacc_sim,
  MAX(company_partnerfinacc_sim) AS company_partnerfinacc_sim,
  MAX(userfinacc_partnerfinacc_sim) AS userfinacc_partnerfinacc_sim,
  CASE
    WHEN MAX(line_score) IS NULL THEN 'Unscored'
    WHEN MAX(line_score) >= t_similar THEN 'Similar'
    WHEN MAX(line_score) >= t_suspicious THEN 'Suspicious'
    ELSE 'Not Similar'
    END AS similarity_category,
  MAX(line_score) AS final_score,
  ARRAY_AGG(line_category IGNORE NULLS ORDER BY line_score DESC)[SAFE_OFFSET(0)]
    AS highest_category,
  -- Kunci yang mendefinisikan satu bulk. total_bulk_payment_trx di bawah
  -- adalah COUNT(*) baris invoice dalam order_id ini, jadi order_id memang
  -- kunci bulk-nya. Kolom ini tidak dibaca dailypoints -- ganti bebas
  -- kalau bulk_key dimaksudkan untuk hal lain.
  order_id AS bulk_key,
  CAST(COUNT(*) AS FLOAT64) AS total_bulk_payment_trx,
  CAST(COUNTIF(line_similarity_category = 'Suspicious') AS FLOAT64)
    AS total_suspicious_trx,
  CAST(COUNTIF(line_similarity_category = 'Similar') AS FLOAT64)
    AS total_similar_trx,
  STRING_AGG(line_similarity_category, ', ' ORDER BY invoice_number)
    AS similarity_category_list,
  STRING_AGG(CAST(ROUND(line_score, 4) AS STRING), ', '
    ORDER BY invoice_number) AS final_score_list,
  STRING_AGG(line_category, ', ' ORDER BY invoice_number)
    AS highest_category_list,
  CURRENT_TIMESTAMP() AS computed_at
FROM classified
GROUP BY order_id;


MERGE `paper-prod.datawarehouse_dwd.dim_digitalpayment_transaction_namesim_v2` tgt
USING staged src
ON tgt.order_id = src.order_id AND tgt.payment_ds = src.payment_ds
WHEN MATCHED THEN UPDATE SET
  company_id                   = src.company_id,
  user_company_name            = src.user_company_name,
  user_name                    = src.user_name,
  user_bank_account_name       = src.user_bank_account_name,
  partner_name                 = src.partner_name,
  partner_bank_account_name    = src.partner_bank_account_name,
  user_partner_sim             = src.user_partner_sim,
  company_partner_sim          = src.company_partner_sim,
  userfinacc_partner_sim       = src.userfinacc_partner_sim,
  user_partnerfinacc_sim       = src.user_partnerfinacc_sim,
  company_partnerfinacc_sim    = src.company_partnerfinacc_sim,
  userfinacc_partnerfinacc_sim = src.userfinacc_partnerfinacc_sim,
  similarity_category          = src.similarity_category,
  final_score                  = src.final_score,
  highest_category             = src.highest_category,
  bulk_key                     = src.bulk_key,
  total_bulk_payment_trx       = src.total_bulk_payment_trx,
  total_suspicious_trx         = src.total_suspicious_trx,
  total_similar_trx            = src.total_similar_trx,
  similarity_category_list     = src.similarity_category_list,
  final_score_list             = src.final_score_list,
  highest_category_list        = src.highest_category_list,
  computed_at                  = src.computed_at
WHEN NOT MATCHED THEN INSERT (
  payment_ds, company_id, order_id, user_company_name, user_name,
  user_bank_account_name, partner_name, partner_bank_account_name,
  user_partner_sim, company_partner_sim, userfinacc_partner_sim,
  user_partnerfinacc_sim, company_partnerfinacc_sim,
  userfinacc_partnerfinacc_sim, similarity_category, final_score,
  highest_category, bulk_key, total_bulk_payment_trx, total_suspicious_trx,
  total_similar_trx, similarity_category_list, final_score_list,
  highest_category_list, computed_at
) VALUES (
  src.payment_ds, src.company_id, src.order_id, src.user_company_name,
  src.user_name, src.user_bank_account_name, src.partner_name,
  src.partner_bank_account_name, src.user_partner_sim,
  src.company_partner_sim, src.userfinacc_partner_sim,
  src.user_partnerfinacc_sim, src.company_partnerfinacc_sim,
  src.userfinacc_partnerfinacc_sim, src.similarity_category, src.final_score,
  src.highest_category, src.bulk_key, src.total_bulk_payment_trx,
  src.total_suspicious_trx, src.total_similar_trx,
  src.similarity_category_list, src.final_score_list,
  src.highest_category_list, src.computed_at
);
