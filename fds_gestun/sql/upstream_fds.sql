-- Extracted from FDS_Gestun_Combined_Features.ipynb.
-- @company_ids : ARRAY<STRING> of companies to build features for.
-- Edit this file, not the notebook: the notebook is exploration, this is the source of truth.

WITH labels AS (SELECT company_id FROM UNNEST(@company_ids) AS company_id),
eco AS (
  SELECT external_id, ANY_VALUE(payment_ecosystem_cat) AS payment_ecosystem_cat
  FROM `paper-prod.datawarehouse_dwd.mlfds_ml_labeling` GROUP BY external_id
)
SELECT
  m.company_id, m.order_id, m.external_id, m.invoice_id, m.Label AS mlfds_label,
  m.sequence_of_mitra_transaction, m.delta_created_registered_in_minutes,
  m.delta_payment_created_in_hours, m.delta_payment_registered_in_hours,
  m.delta_payment_firsttrx_in_minutes, m.delta_register_firsttrx_minute,
  m.delta_created_mitra_to_payment_in_minutes, m.delta_registered_firstkyc_cat,
  m.delta_created_firstkyc_cat, m.kyc_date_time_clf, m.kyc_status_transformed,
  m.comp_email_phone_verified, m.user_owner_name, m.user_owner_phone,
  m.similarity_category, m.comp_kyc_status_phone_email_verified,
  m.comp_kyc_status_user_owner_name, m.amount, m.invoice_amount,
  m.amount_to_invoice_amount, m.median_ticket_size_l30d, m.avg_ticket_size_l30d,
  m.invoice_amount_l30d, m.invoice_cnt_l30d, m.std_invoice_count_l30d,
  m.success_rate_transaction_l30d, m.payment_attempt_using_cc,
  m.ttl_uniquecc_uses_in_1trx, m.cnt_uniquecc_at, m.cnt_uniquecc_l7d, m.cnt_uniquecc_l30d,
  m.cnt_comp_at_ccnum, m.cnt_comp_l7d_ccnum, m.is_cc_match_tokenized_def,
  m.number_of_mitra, m.is_new_trx_mitra, m.is_local_partner, m.partner_completeness_detail,
  m.business_child_cat, m.company_size, m.is_company_state_filled,
  m.comp_is_use_invoice_and_itemdesc, m.is_related_to_blacklisted, m.method_clf,
  m.trx_source_digpay_type, m.payment_channel_name,
  eco.payment_ecosystem_cat
FROM `paper-prod.datawarehouse_dwd.mlfds_main_dim_table` m
JOIN labels USING (company_id)
LEFT JOIN eco ON eco.external_id = m.external_id
