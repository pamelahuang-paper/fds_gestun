LEFT JOIN -- Name similiarity function (v2) --
        (
            SELECT 
                CAST(order_id AS STRING) AS order_id,
                highest_category,
                highest_category_list,
                highest_category_detail_list,
                similarity_category,
                similarity_category_list,
                user_partner_sim,
                company_partner_sim,
                userfinacc_partner_sim,
                user_partnerfinacc_sim,
                company_partnerfinacc_sim,
                userfinacc_partnerfinacc_sim,
                final_sim,
                final_score_list,
                total_bulk_payment,
                IEEE_DIVIDE((CAST(CAST(total_similar_trx AS FLOAT64) AS INT64) + CAST(CAST(total_suspicious_trx AS FLOAT64) AS INT64)),CAST(total_bulk_payment AS INT64)) AS per_sim
            FROM 
                    (
                        SELECT 
                            order_id,
                            highest_category,
                            highest_category_list,
                            final_score_list,
                            -- v2 tidak memproduksi kolom ini. Dipertahankan sebagai
                            -- NULL supaya bentuk output f2 tidak berubah.
                            CAST(NULL AS STRING) AS highest_category_detail_list,
                            CAST(similarity_category AS STRING) AS similarity_category,
                            similarity_category_list,
                            MAX(user_partner_sim) AS user_partner_sim,
                            MAX(company_partner_sim) AS company_partner_sim,
                            MAX(userfinacc_partner_sim) AS userfinacc_partner_sim,
                            MAX(user_partnerfinacc_sim) AS user_partnerfinacc_sim,
                            MAX(company_partnerfinacc_sim) AS company_partnerfinacc_sim,
                            MAX(userfinacc_partnerfinacc_sim) AS userfinacc_partnerfinacc_sim,
                            MAX(CAST(final_score AS FLOAT64)) AS final_sim,
                            MAX(CAST(total_bulk_payment_trx AS FLOAT64)) AS total_bulk_payment,
                            MAX(CAST(total_suspicious_trx AS FLOAT64)) AS total_suspicious_trx,
                            MAX(CAST(total_similar_trx AS FLOAT64)) AS total_similar_trx
                        FROM `paper-prod.datawarehouse_dwd.dim_digitalpayment_transaction_namesim_v2`
                        GROUP BY 1,2,3,4,5,6,7
                    )
        ) AS f2 
ON f1.external_id = f2.order_id
