-- DROP TABLE IF EXISTS `paper-prod.datawarehouse_rpt.pprrsk001_1_dailypoints_1d` ;
-- CREATE OR REPLACE TABLE  `paper-prod.datawarehouse_rpt.pprrsk001_1_dailypoints_1d`
-- PARTITION BY created_ds AS

DECLARE start_ds, end_ds DATE;
SET start_ds = DATE_SUB(CURRENT_DATE ('Asia/Jakarta'), INTERVAL 31 DAY) ;
SET end_ds = DATE_SUB(CURRENT_DATE ('Asia/Jakarta'), INTERVAL 1 DAY) ;

DELETE `paper-prod.datawarehouse_rpt.pprrsk001_1_dailypoints_1d`
WHERE created_ds BETWEEN start_ds AND end_ds ;

INSERT INTO `paper-prod.datawarehouse_rpt.pprrsk001_1_dailypoints_1d`


WITH 

fct_trd AS 
(
    SELECT 
        *
    FROM `paper-prod.datawarehouse_dwd.fct_digitalpayment_transaction_all_n_1d`
    WHERE LOWER(transaction_status_note) = 'paid'
    OR DATE(payment_ds_rddp) IS NOT NULL
    --AND DATE(payment_ds_rddp) = DATE('2023-08-21')
),

con_l1b_bl AS 
(
        SELECT 
            digital_payment_type,
            finance_account_name_bl,
            REGEXP_REPLACE(finance_account_name_bl, r'[-=]+', '') AS finance_account_name_bl_tr,
            CAST(finance_account_num_bl AS STRING) AS finance_account_num_bl,
            MAX(last_action_date) AS last_action_date,
        FROM `paper-prod.datawarehouse_dwd.dim_users_blacklistedbaname_1d`
        GROUP BY 1,2,3,4
),

con_l1c_newdigpay AS 
(
    SELECT 
        CAST(5 AS INT64) AS threshold,
        CAST(0.25 AS FLOAT64) AS l1c_points_ass
)

SELECT DISTINCT
    f1.* EXCEPT(is_new_namesim_point),
    f2.* EXCEPT (order_id,similarity_category),
    CASE 
        WHEN CAST(total_bulk_payment AS INT64) <= 1 AND LOWER(similarity_category) = 'not similar' THEN 'A). Not Similar'
        WHEN CAST(total_bulk_payment AS INT64) <= 1 AND LOWER(similarity_category) = 'suspicious' THEN 'B). Suspicious'
        WHEN CAST(total_bulk_payment AS INT64) <= 1 AND LOWER(similarity_category) = 'similar' THEN 'C). Similar'
        WHEN CAST(total_bulk_payment AS INT64) > 1 AND per_sim < 0.2 THEN CONCAT('[Bulk Module]',"-",'A). Not Similar')
        WHEN CAST(total_bulk_payment AS INT64) > 1 AND per_sim < 0.5 THEN CONCAT('[Bulk Module]',"-",'B). Suspicious')
        WHEN CAST(total_bulk_payment AS INT64) > 1 AND per_sim >= 0.5 THEN CONCAT('[Bulk Module]',"-",'C). Similar')
        ELSE CONCAT('[Bulk Module]',"-",similarity_category) 
    END AS similarity_category_e,
    CASE 
        WHEN LOWER(highest_category) = 'user_partner_sim' THEN 'User Name = Partner'
        WHEN LOWER(highest_category) = 'company_partner_sim' THEN 'User Company = Partner'
        WHEN LOWER(highest_category) = 'userfinacc_partner_sim' THEN 'User Bank Account = Partner'
        WHEN LOWER(highest_category) = 'user_partnerfinacc_sim' THEN 'User Name = Partner Bank Account'
        WHEN LOWER(highest_category) = 'company_partnerfinacc_sim' THEN 'User Company = Partner Bank Account'
        WHEN LOWER(highest_category) = 'userfinacc_partnerfinacc_sim' THEN 'User Bank Account = Partner Bank Account'
        ELSE CONCAT('[Bulk Module]',"-",highest_category)  
    END AS highest_category_e,
    CASE 
        WHEN is_new_namesim_point = 1 AND CAST(total_bulk_payment AS INT64) <= 1 AND LOWER(similarity_category) = 'not similar' THEN 0
        WHEN is_new_namesim_point = 1 AND CAST(total_bulk_payment AS INT64) <= 1 AND LOWER(similarity_category) = 'suspicious' THEN 1
        WHEN is_new_namesim_point = 1 AND CAST(total_bulk_payment AS INT64) <= 1 AND LOWER(similarity_category) = 'similar' THEN 5
        WHEN is_new_namesim_point = 1 AND CAST(total_bulk_payment AS INT64) > 1 AND per_sim < 0.2 THEN 0
        WHEN is_new_namesim_point = 1 AND CAST(total_bulk_payment AS INT64) > 1 AND per_sim < 0.5 THEN 1
        WHEN is_new_namesim_point = 1 AND CAST(total_bulk_payment AS INT64) > 1 AND per_sim >= 0.5 THEN 5

        WHEN is_new_namesim_point = 0 AND CAST(total_bulk_payment AS INT64) <= 1 AND LOWER(similarity_category) = 'not similar' THEN 0
        WHEN is_new_namesim_point = 0 AND CAST(total_bulk_payment AS INT64) <= 1 AND LOWER(similarity_category) = 'suspicious' THEN 0.5
        WHEN is_new_namesim_point = 0 AND CAST(total_bulk_payment AS INT64) <= 1 AND LOWER(similarity_category) = 'similar' THEN 1
        WHEN is_new_namesim_point = 0 AND CAST(total_bulk_payment AS INT64) > 1 AND per_sim < 0.2 THEN 0
        WHEN is_new_namesim_point = 0 AND CAST(total_bulk_payment AS INT64) > 1 AND per_sim < 0.5 THEN 0.5
        WHEN is_new_namesim_point = 0 AND CAST(total_bulk_payment AS INT64) > 1 AND per_sim >= 0.5 THEN 1
    END AS l1a_point,
    f3.final_score_dttot,
    CASE
        WHEN CAST(final_score_dttot AS FLOAT64) > 0.85 THEN 'C). Similar'
        WHEN CAST(final_score_dttot AS FLOAT64) >= 0.6 THEN 'B). Suspicious'
        ELSE 'A). Not Similar'
    END AS dttot_similarity_category,
    f3.dttot_name,
    f3.highest_category_dttot
FROM 
        (
            SELECT 
                *,
                IF(DATE(payment_ds_rddp) >= DATE('2024-02-05'),1,0) AS is_new_namesim_point
            FROM 
                    (
                        SELECT 
                            *,
                            ROW_NUMBER() OVER(PARTITION BY invoice_number,external_id,company_id, digital_payment_type ORDER BY pout_l1b_point DESC, pin_l1b_point DESC ) AS rn
                        FROM 
                                (
                                    SELECT 
                                        t1.*,
                                        t2.finance_account_name_bl AS bl_pout,
                                        t4.finance_account_name_bl AS bl_pin,
                                        CASE 
                                            WHEN (DATE(payment_ds_rddp) < DATE('2025-04-21') AND t1.digital_payment_type = 'Out' AND t2.finance_account_name_bl IS NOT NULL) THEN 2
                                            WHEN (DATE(payment_ds_rddp) >= DATE('2025-04-21') AND t1.digital_payment_type = 'Out' AND (t3.finance_account_num_bl IS NOT NULL)) THEN 3
                                            WHEN (DATE(payment_ds_rddp) >= DATE('2025-04-21') AND t1.digital_payment_type = 'Out' AND (t2.finance_account_name_bl IS NOT NULL AND t3.finance_account_num_bl IS NOT NULL)) THEN 3
                                            WHEN (DATE(payment_ds_rddp) >= DATE('2025-04-21') AND t1.digital_payment_type = 'Out' AND (t2.finance_account_name_bl IS NOT NULL AND t3.finance_account_num_bl IS NULL)) THEN 1
                                            ELSE 0
                                        END AS pout_l1b_point,
                                        --IF(t1.digital_payment_type = 'Out' AND t2.finance_account_name_bl IS NOT NULL,2,NULL) AS pout_l1b_point,
                                        CASE 
                                            WHEN (DATE(payment_ds_rddp) < DATE('2025-04-21') AND t1.digital_payment_type = 'In' AND t4.finance_account_name_bl IS NOT NULL) THEN 2
                                            WHEN (DATE(payment_ds_rddp) >= DATE('2025-04-21') AND t1.digital_payment_type = 'In' AND (t5.finance_account_num_bl IS NOT NULL)) THEN 3
                                            WHEN (DATE(payment_ds_rddp) >= DATE('2025-04-21') AND t1.digital_payment_type = 'In' AND (t4.finance_account_name_bl IS NOT NULL AND t5.finance_account_num_bl IS NOT NULL)) THEN 3
                                            WHEN (DATE(payment_ds_rddp) >= DATE('2025-04-21') AND t1.digital_payment_type = 'In' AND (t4.finance_account_name_bl IS NOT NULL AND t5.finance_account_num_bl IS NULL)) THEN 1
                                            ELSE 0
                                        END AS pin_l1b_point,
                                        --IF(t1.digital_payment_type = 'In' AND t4.finance_account_name_bl IS NOT NULL,2,NULL) AS pin_l1b_point
                                    FROM
                                            (
                                                SELECT 
                                                    t1.* EXCEPT (pout_partner_bankaccount_name4,pout_partner_bankaccount_no4,pout_partner_bankaccount_bank4),
                                                    t2.* EXCEPT (l1c_points_ass),
                                                    COALESCE(pout_partner_bankaccount_name1,pout_partner_bankaccount_name2,pout_partner_bankaccount_name3) AS pout_bank_acc_coal,
                                                    COALESCE(pin_user_bankaccount_name1,pin_user_bankaccount_name2,pin_user_bankaccount_name3) AS pin_bank_acc_coal,
                                                    CASE 
                                                        WHEN CAST(t1.ddiff AS INT64) <= t2.threshold THEN l1c_points_ass 
                                                        ELSE NULL 
                                                    END AS l1c_point
                                                FROM fct_trd AS t1
                                                CROSS JOIN con_l1c_newdigpay AS t2
                                            ) AS t1 
                                    LEFT JOIN 
                                            (
                                                SELECT
                                                    'Out' AS seg,
                                                    LOWER(finance_account_name_bl) finance_account_name_bl,
                                                    MIN(last_action_date) AS last_action_date,
                                                FROM con_l1b_bl
                                                GROUP BY 1,2
                                                --WHERE digital_payment_type = 'Out'
                                            ) AS t2
                                    ON  LOWER(t1.digital_payment_type) = LOWER(t2.seg)
                                    AND (
                                            LOWER(t1.pout_partner_bankaccount_name1) = LOWER(t2.finance_account_name_bl) OR 
                                            LOWER(t1.pout_partner_bankaccount_name2) = LOWER(t2.finance_account_name_bl) OR 
                                            LOWER(t1.pout_partner_bankaccount_name3) = LOWER(t2.finance_account_name_bl)
                                        )
                                    AND DATE(t1.payment_ds_rddp) >= DATE(t2.last_action_date)
                                    LEFT JOIN
                                            (                                                
                                                SELECT 
                                                    'Out' AS seg,
                                                    CAST(finance_account_num_bl AS STRING) AS finance_account_num_bl,
                                                    MIN(last_action_date) AS last_action_date
                                                FROM con_l1b_bl
                                                GROUP BY 1,2
                                            ) AS t3 
                                    ON  LOWER(t1.digital_payment_type) = LOWER(t3.seg)
                                    AND (
                                            LOWER(CAST(t1.pout_partner_bankaccount_no1 AS STRING)) = LOWER(t3.finance_account_num_bl) OR 
                                            LOWER(CAST(t1.pout_partner_bankaccount_no2 AS STRING)) = LOWER(t3.finance_account_num_bl) OR 
                                            LOWER(CAST(t1.pout_partner_bankaccount_no3 AS STRING)) = LOWER(t3.finance_account_num_bl)
                                        ) 
                                    AND DATE(t1.payment_ds_rddp) >= DATE(t3.last_action_date)
                                    LEFT JOIN 
                                            (
                                                SELECT
                                                    'In' AS seg,
                                                    LOWER(finance_account_name_bl) finance_account_name_bl,
                                                    MIN(last_action_date) AS last_action_date
                                                FROM con_l1b_bl
                                                GROUP BY 1,2
                                                --WHERE digital_payment_type = 'In'
                                            ) AS t4
                                    ON  LOWER(t1.digital_payment_type) = LOWER(t3.seg)
                                    AND (
                                            LOWER(t1.pin_user_bankaccount_name1) = LOWER(t4.finance_account_name_bl) OR 
                                            LOWER(t1.pin_user_bankaccount_name2) = LOWER(t4.finance_account_name_bl) OR 
                                            LOWER(t1.pin_user_bankaccount_name3) = LOWER(t4.finance_account_name_bl)
                                        )
                                    AND DATE(t1.payment_ds_rddp) >= DATE(t4.last_action_date)
                                    LEFT JOIN
                                            (                                                
                                                SELECT 
                                                    'In' AS seg,
                                                    CAST(finance_account_num_bl AS STRING) AS finance_account_num_bl,
                                                    MIN(last_action_date) AS last_action_date
                                                FROM con_l1b_bl
                                                GROUP BY 1,2
                                            ) AS t5
                                    ON  LOWER(t1.digital_payment_type) = LOWER(t5.seg)
                                    AND (
                                            LOWER(CAST(t1.pin_user_bankaccount_no1 AS STRING)) = LOWER(t5.finance_account_num_bl) OR 
                                            LOWER(CAST(t1.pin_user_bankaccount_no2 AS STRING)) = LOWER(t5.finance_account_num_bl) OR 
                                            LOWER(CAST(t1.pin_user_bankaccount_no3 AS STRING)) = LOWER(t5.finance_account_num_bl)
                                        ) 
                                    AND DATE(t1.payment_ds_rddp) >= DATE(t5.last_action_date)
                                    WHERE LOWER(t1.transaction_status_note) = 'paid'
                                    AND DATE(t1.payment_ds_rddp) IS NOT NULL
                                    --AND DATE(t1.payment_ds_rddp) = DATE('2023-08-17')
                                )
                    )
            WHERE rn = 1
        ) AS f1 
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
LEFT JOIN 
        (
            SELECT
                order_id,
                MAX(dttot_name) aS dttot_name,
                MAX(highest_category_dttot) AS highest_category_dttot,
                MAX(final_score_dttot) AS final_score_dttot
            FROM `paper-prod.datawarehouse_dwd.dim_digitalpayment_transaction_dttot_namesim_di`
            GROUP BY 1
        ) AS f3 
ON CAST(f1.external_id AS STRING) = CAST(f3.order_id AS STRING)
WHERE DATE(f1.created_ds) BETWEEN start_ds AND end_ds