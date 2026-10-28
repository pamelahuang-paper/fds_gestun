CREATE OR REPLACE TABLE  `paper-prod.datawarehouse_rpt.ppr0002reprisid_1_list_of_fraudulent_transaction` AS

WITH 

fct_trx AS 
(
    SELECT 
        * EXCEPT(method_type_name),
        CASE 
          WHEN UPPER(method_name) IN ('TOKOPEDIA CREDIT CARD', 'TOKOPEDIA_CREDIT_CARD') OR LOWER(payment_method_name) IN ('credit_card') THEN 'CREDIT CARD' 
          ELSE UPPER(method_type_name)
        END AS method_type_name,
        IF(LOWER(digital_payment_type) IN ('pay-out','out'),'Out',NULL) AS p_type
    FROM `paper-prod.datawarehouse_dwd.fct_digitalpayment_transaction_all_n_1d`
    WHERE LOWER(transaction_status_note) = 'paid'
    OR DATE(payment_ds_rddp) IS NOT NULL
    --AND DATE(payment_ds_rddp) >= DATE('2024-02-26')
),

fct_cc_usage AS 
(
    SELECT
        created_dt,
        created_ds,
        external_id,
        --cc_details,
        card_holdername,
        CAST(card_number AS STRING) AS card_number,
        card_attampted_at,
        rn,
        payment_ds_rddp,
        payment_status,
        company_id,
        t2.p_type,
        t2.user_company_name
    FROM `paper-prod.datawarehouse_dwd.fct_digitalpayment_transaction_ccpayment_ext_1d` AS t1
    LEFT JOIN  (
                    SELECT DISTINCT 
                        order_id, 
                        p_type,
                        user_company_name,
                        method_type_name
                    FROM fct_trx
                ) AS t2 
    ON t1.external_id = t2.order_id
    WHERE LOWER(payment_status) = 'paid' AND (UPPER(method_type_name) = 'CREDIT CARD' OR UPPER(method_type_name) = 'CREDIT_CARD')
),

con_ml AS 
(
    SELECT 
        *,
        IF(CAST(rf_pred_proba AS FLOAT64) BETWEEN 0.50 AND 0.59999,0.6,CAST(rf_pred_proba AS FLOAT64)) AS rf_pred_proba_e,
        IF(CAST(xgb_pred_proba AS FLOAT64) BETWEEN 0.50 AND 0.59999,0.6,CAST(xgb_pred_proba AS FLOAT64)) AS xgb_pred_proba_e
    FROM `paper-prod.datawarehouse_dwd.mlfds_ml_labeling`
),

------------------------------------------------- For Blacklisted Account -----------------------------------------
------------------------------------------------- Only Take SP3 Only [CONFIRMED] ----------------------------------
dim_userseg AS 
(
    SELECT 
        company_id,
        company_name,
        business_child,
        business_child_segmentation,
        company_email,
        company_phone,
        company_type,
        user_owner_name,
        user_owner_phone,
        DATE(MIN(first_date_created_digital_payment)) AS first_transaction_ds,
        DATE(MIN(company_created),'Asia/Jakarta') AS register_ds
    FROM `paper-prod.datascience_public.master_segment_table`
    GROUP BY 1,2,3,4,5,6,7,8,9
),

dim_kyc AS 
(
    SELECT 
        * 
    FROM 
            (
                SELECT 
                    *,
                    ROW_NUMBER() OVER(PARTITION BY company_id ORDER BY kyc_ds ASC) AS rn
                FROM 
                        (
                            SELECT 
                                company_id,
                                LOWER(kyc_status_name) AS kyc_status,
                                company_name,
                                owner_name,
                                DATETIME(kyc_created_datetime) AS kyc_ds
                            FROM `paper-prod.data_warehouse_pii_layer.dim__paper__kyc`
                            GROUP BY 1,2,3,4,5
                        )
            )
    WHERE rn = 1
),

con_blacklist AS 
(
    SELECT DISTINCT
        CAST(company_id AS STRING) AS company_id, 
        current_account_status,
        sp2_action_date,
        sp3_action_date,
        COALESCE(sp3_action_date,sp2_action_date,NULL) AS last_action_date,
        block_reason,
        remarks,
        note,
    FROM `paper-prod.datawarehouse_ingestion.dim_user_blacklistedusers_di` 
    WHERE CAST(company_id AS STRING) IS NOT NULL
    AND DATE(sp3_action_date) IS NOT NULL -- Filter SP 3 Only --
),

con_l1b1_blacklist_pout AS 
(
    SELECT
        CAST(finance_account_name AS STRING) AS pout_finance_account_name_bl,
        finance_account_bank_account_number,
        MIN(last_action_date) AS last_action_date
    FROM 
            (
                SELECT 
                    rt2.company_id,
                    rt1.finance_account_name,
                    rt1.finance_account_bank_account_number,
                    rt1.partner_name,
                    rt2.company_name,
                    rt2.owner_name AS user_owner_name_kyc,
                    rt2.user_owner_name,
                    COUNT(DISTINCT rt1.external_id) AS cnt_unq_transaction,
                    SUM(rt2.amount) AS sum_tpv
                FROM `paper-prod.datawarehouse_dwd.fct_digitalpayment_transaction_payout_1d` AS rt1 
                LEFT JOIN   (
                                SELECT 
                                  r1.external_id,
                                  r1.order_id,
                                  r1.company_id,
                                  r3.company_name,
                                  r2.owner_name,
                                  r3.user_owner_name,
                                  r1.amount
                                FROM fct_trx AS r1 
                                LEFT JOIN   (
                                                SELECT 
                                                    company_id,
                                                    owner_name
                                                FROM dim_kyc
                                                GROUP BY 1,2
                                            ) AS r2 
                                ON r1.company_id = r2.company_id 
                                LEFT JOIN 
                                            (
                                                SELECT 
                                                    company_id,
                                                    company_name,
                                                    user_owner_name
                                                FROM dim_userseg
                                                GROUP BY 1,2,3
                                            ) AS r3 
                                ON r1.company_id = r3.company_id
                            ) AS rt2
                ON rt1.external_id = rt2.order_id
                GROUP BY 1,2,3,4,5,6,7
            ) AS t1 
    LEFT JOIN 
            (
                SELECT 
                    company_id ,
                    MIN(DATE(last_action_date)) AS last_action_date
                FROM con_blacklist
                GROUP BY 1
            ) AS t2 
    ON CAST(t1.company_id AS STRING) = CAST(t2.company_id AS STRING)
    WHERE t2.company_id IS NOT NULL
    GROUP BY 1,2
),

con_l1b2_blacklist_pin AS
(
    SELECT
        CAST(finance_account_name AS STRING) AS pin_finance_account_name_bl,
        finance_account_bank_account_number,
        MIN(last_action_date) AS last_action_date
    FROM 
            (
                SELECT 
                    rt1.company_id,
                    rt1.finance_account_bank_account_name AS finance_account_name,
                    rt1.finance_account_bank_account_no AS finance_account_bank_account_number,
                    rt3.company_name,
                    rt2.owner_name AS user_owner_name_kyc,
                    rt3.user_owner_name,
                    COUNT(DISTINCT rt1.disbursement_request_no) AS cnt_unq_transaction,
                    SUM(rt1.disbursement_amount) AS sum_tpv
                FROM `paper-prod.datawarehouse_dwd.fct_digitalpayment_transaction_payin_1d` AS rt1 
                LEFT JOIN   (
                                SELECT 
                                    company_id,
                                    owner_name
                                FROM dim_kyc
                                GROUP BY 1,2
                            ) AS rt2 
                ON CAST(rt1.company_id AS STRING) = CAST(rt2.company_id AS STRING)
                LEFT JOIN 
                            (
                                SELECT 
                                    company_id,
                                    company_name,
                                    user_owner_name
                                FROM dim_userseg
                                GROUP BY 1,2,3
                            ) AS rt3
                ON CAST(rt1.company_id AS STRING) = CAST(rt3.company_id AS STRING)
                GROUP BY 1,2,3,4,5,6
            ) AS t1 
    LEFT JOIN 
            (
                SELECT 
                    company_id,
                    MIN(DATE(last_action_date)) AS last_action_date 
                FROM con_blacklist
                GROUP BY 1
            ) AS t2 
    ON  CAST(t1.company_id AS STRING) = CAST(t2.company_id AS STRING)
    WHERE t2.company_id IS NOT NULL
    GROUP BY 1,2
),

dim_bl AS 
(
    SELECT 
        digital_payment_type,
        finance_account_name_bl,
        finance_account_bank_account_number,
        MIN(last_action_date) AS last_action_ds
    FROM 
            (
                SELECT DISTINCT 
                    'Out' AS digital_payment_type,
                    last_action_date,
                    pout_finance_account_name_bl AS finance_account_name_bl,
                    finance_account_bank_account_number

                FROM con_l1b1_blacklist_pout 

                UNION ALL 

                SELECT DISTINCT
                    'In' AS digital_payment_type,
                    last_action_date,
                    pin_finance_account_name_bl AS finance_account_name_bl,
                    finance_account_bank_account_number
                FROM con_l1b2_blacklist_pin
            )
    GROUP BY 1,2,3
),

con_cc_bl AS 
(
    -- PayOut - CC use by the blacklist account
    SELECT  
        t1.payment_seg,
        'CC owned by the blacklisted company ID' AS cc_desc,
        t1.company_id,
        t1.card_number,
        MIN(t2.last_action_date) AS last_sp_date
    FROM 
                (
                    
                        SELECT
                            created_dt,
                            created_ds,
                            t1.external_id,
                            --cc_details,
                            card_holdername,
                            card_number,
                            card_attampted_at,
                            rn,
                            payment_ds_rddp,
                            payment_status,
                            company_id,
                            IF(LOWER(t2.digital_payment_type) IN ('pay-out','out'),'Out',NULL) AS payment_seg
                        FROM `paper-prod.datawarehouse_dwd.fct_digitalpayment_transaction_ccpayment_ext_1d` AS t1
                        JOIN  (
                                    SELECT DISTINCT 
                                        external_id,
                                        digital_payment_type
                                    FROM fct_trx 
                                    WHERE LOWER(digital_payment_type) IN    (
                                                                                'pay-out',
                                                                                'out' 
                                                                            ) 
                                    AND UPPER(method_type_name) = 'CREDIT CARD' 
                            ) AS t2 
                        ON t1.external_id = t2.external_id
                        WHERE LOWER(payment_status) = 'paid'
                ) AS t1 
    LEFT JOIN   
                (
                    SELECT 
                        company_id,
                        MIN(DATE(sp3_action_date)) AS last_action_date 
                    FROM con_blacklist
                    WHERE sp3_action_date IS NOT NULL
                    GROUP BY 1
                ) AS t2 
    ON t1.company_id = t2.company_id 
    WHERE last_action_date IS NOT NULL
    GROUP BY 1,2,3,4

    UNION ALL 

    -- Pay In CC Transfer to the Blacklist Account -- 
    -- Can be false positive -> Differentiate between Out & In

    SELECT  
        t1.payment_seg,
        'CC used to transact with the blacklisted company ID' AS cc_desc,
        t1.company_id,
        t1.card_number,
        MIN(t2.last_action_date) AS last_sp_date
    FROM 
                (
                    
                        SELECT
                            created_dt,
                            created_ds,
                            t1.external_id,
                            --cc_details,
                            card_holdername,
                            card_number,
                            card_attampted_at,
                            rn,
                            payment_ds_rddp,
                            payment_status,
                            company_id,
                            IF(LOWER(t2.digital_payment_type) IN ('pay-in','in'),'In',NULL) AS payment_seg
                        FROM `paper-prod.datawarehouse_dwd.fct_digitalpayment_transaction_ccpayment_ext_1d` AS t1
                        JOIN  (
                                    SELECT DISTINCT 
                                        external_id,
                                        digital_payment_type
                                    FROM fct_trx 
                                    WHERE LOWER(digital_payment_type) IN    (
                                                                                'pay-in',
                                                                                'in' 
                                                                            ) 
                                    AND (UPPER(method_type_name) = 'CREDIT_CARD' OR UPPER(method_type_name) = 'CREDIT CARD')
                            ) AS t2 
                        ON t1.external_id = t2.external_id
                        WHERE LOWER(payment_status) = 'paid'
                ) AS t1 
    LEFT JOIN   
                (
                    SELECT 
                        company_id,
                        MIN(DATE(sp3_action_date)) AS last_action_date 
                    FROM con_blacklist
                    WHERE sp3_action_date IS NOT NULL
                    GROUP BY 1
                ) AS t2 
    ON t1.company_id = t2.company_id 
    WHERE last_action_date IS NOT NULL
    GROUP BY 1,2,3,4
),

--------------------------------------------------------------------------------------------------------

con_gestun AS 
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
        CAST(final_sim AS FLOAT64) AS final_sim,
        final_score_list,
        total_bulk_payment,
        IEEE_DIVIDE((CAST(total_similar_trx AS FLOAT64) + CAST(total_suspicious_trx AS FLOAT64)),CAST(total_bulk_payment AS FLOAT64)) AS per_sim
    FROM 
            (
                SELECT 
                    order_id,
                    highest_category,
                    -- Insert New Column of Payment Method
                    highest_category_list,
                    final_score_list,
                    highest_category_detail_list,
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
                FROM `paper-prod.datawarehouse_dwd.dim_digitalpayment_transaction_namesim_di`
                GROUP BY 1,2,3,4,5,6,7
            )
),

base_mult AS 
(
    SELECT
        t1.payment_ds_rddp AS payment_ds,
        t1.external_id,
        t1.card_number,
        t2.company_id,
        t2.user_company_name,
        t2.p_type
    FROM fct_cc_usage AS t1 
    JOIN fct_cc_usage AS t2 
    ON (CAST(LEFT(t1.card_number,6) AS STRING) = CAST(LEFT(t2.card_number,6) AS STRING) AND CAST(RIGHT(t1.card_number,4) AS STRING) = CAST(RIGHT(t2.card_number,4) AS STRING) )
    AND DATE(t2.payment_ds_rddp) >= DATE_SUB(DATE(t1.payment_ds_rddp), INTERVAL 30 DAY)
    AND DATE(t2.payment_ds_rddp) < DATE(t1.payment_ds_rddp)
    AND t2.p_type = 'Out'
),

con_mult AS 
(
    SELECT 
        payment_ds,
        card_number,
        company_name_list,
        cnt_mult_acc
    FROM 
        (
            SELECT
                t1.payment_ds AS payment_ds,
                t1.card_number,
                ARRAY_AGG(user_company_name) AS company_name_list,
                COUNT(DISTINCT company_id) AS cnt_mult_acc
            FROM base_mult AS t1
            GROUP BY 1,2
         )
)

SELECT 
    t1.created_dt, --1
    t1.payment_ds, --2
    payment_ws_mon, --3
    external_id,--4
    digpay_type,--5
    MAX(ml_rf_prob) AS ml_rf_prob,
    MAX(ml_xgb_prob) AS ml_xgb_prob,
    MAX(is_ml_predict_fraud) AS is_ml_predict_fraud,
    MAX(is_rel_to_blacklist_byname_poutdisb) AS is_rel_to_blacklist_byname_poutdisb,
    MAX(IF(is_rel_to_blacklist_byname_poutdisb = 1,poutacc_name_bl,NULL)) AS poutacc_name_bl,
    MAX(is_rel_to_blacklist_bybankaccount_poutdisb) AS is_rel_to_blacklist_bybankaccount_poutdisb,
    MAX(IF(is_rel_to_blacklist_bybankaccount_poutdisb =1,poutacc_number_bl,NULL)) AS poutacc_number_bl,
    MAX(is_rel_to_blacklist_byname_finacc) AS is_rel_to_blacklist_byname_finacc,
    MAX(IF(is_rel_to_blacklist_byname_finacc = 1,finacc_name_bl,NULL)) AS finacc_name_bl,
    MAX(is_rel_to_blacklist_bybankaccount_finacc) AS is_rel_to_blacklist_bybankaccount_finacc,
    MAX(IF(is_rel_to_blacklist_bybankaccount_finacc = 1,finaacc_number_bl,NULL)) AS finaacc_number_bl,
    MAX(is_cc_payment) AS is_cc_payment,
    MAX(is_gestun) AS is_gestun,
    MAX(IF(is_gestun = 1,gestun_category_caught,NULL)) AS gestun_category_caught,
    MAX(is_cc_owned_by_the_bl_company) AS is_cc_owned_by_the_bl_company,
    MAX(is_cc_ever_transact_with_bl_company) AS is_cc_ever_transact_with_bl_company,
    method_type_name, --22
    t1.card_number, --23
    card_bin, --24
    issuing_bank, --25
    company_id, --26
    user_company_email, --27
    user_company_name, --28
    user_company_type, --29
    business_child, --30
    business_child_segmentation, --31
    MIN(registration_date) AS registration_date,
    payment_channel_name, --33
    payment_method_name, --34
    payment_provider_name, --35
    MAX(phone_num) AS phone_num, --36
    SUM(amount) AS amount,
    MAX(is_with_invoice) is_with_invoice,
    user_name, --39
    partner_name, --40
    MIN(user_first_transaction_ds) AS user_first_transaction_ds,
    MAX(delta_from_first_transaction) delta_from_first_transaction,
    kyc_status, --43
    trx_source, --44
    pout_partner_bankaccount_name1, --45
    pout_partner_bankaccount_no1,--46
    pout_partner_bankaccount_bank1,--47
    pout_partner_bankaccount_name2,--48
    pout_partner_bankaccount_no2,--49
    pout_partner_bankaccount_bank2,--50
    pout_partner_bankaccount_name3,--51
    pout_partner_bankaccount_no3,--52
    pout_partner_bankaccount_bank3,--53
    finance_account_bankacc_name1,--54
    finance_account_bankacc_no1,--55
    finance_account_bankacc_bank1,--56
    finance_account_bankacc_name2,--57
    finance_account_bankacc_no2,--58
    finance_account_bankacc_bank2,--59
    finance_account_bankacc_name3,--60
    finance_account_bankacc_no3,--61
    finance_account_bankacc_bank3,--62
    MAX(t2.cnt_mult_acc) AS cnt_mult_acc,
    MAX(IF(t2.cnt_mult_acc >= 5,1,NULL)) AS is_mult_acc,
FROM 
        (
            SELECT 
                t1.created_dt,
                t1.payment_ds_rddp AS payment_ds,
                t1.payment_ws_mon,
                t1.external_id,
                UPPER(t1.digital_payment_type) AS digpay_type,
                ROUND(rf_fraud_prob,2) AS ml_rf_prob,
                ROUND(xgb_fraud_prob,2) AS ml_xgb_prob,
                CASE
                  WHEN rf_fraud_prob IS NULL AND xgb_fraud_prob IS NULL THEN NULL
                  WHEN CAST(rf_fraud_prob AS FLOAT64) >= 0.90
                    OR CAST(xgb_fraud_prob AS FLOAT64) >= 0.90 THEN 1
                  ELSE 0
                END AS is_ml_predict_fraud,
                IF(t4.finance_account_name_bl IS NOT NULL,1,0) AS is_rel_to_blacklist_byname_poutdisb,
                t4.finance_account_name_bl AS poutacc_name_bl,
                IF(t5.finance_account_bank_account_number IS NOT NULL,1,0) AS is_rel_to_blacklist_bybankaccount_poutdisb,
                t5.finance_account_bank_account_number AS poutacc_number_bl,
                IF(t6.finance_account_name_bl IS NOT NULL,1,0) AS is_rel_to_blacklist_byname_finacc,
                t6.finance_account_name_bl AS finacc_name_bl,
                IF(t7.finance_account_bank_account_number IS NOT NULL,1,0) AS is_rel_to_blacklist_bybankaccount_finacc,
                t7.finance_account_bank_account_number AS finaacc_number_bl,
                IF(UPPER(t1.method_type_name) IN ('CREDIT_CARD','CREDIT CARD'),1,0) AS is_cc_payment,
                CASE 
                    WHEN total_bulk_payment <= 1 AND LOWER(similarity_category) IN ('similar') THEN 1
                    WHEN total_bulk_payment > 1 AND per_sim > 0.2 THEN 1
                    ELSE 0
                END AS is_gestun,
                CASE 
                    WHEN LOWER(highest_category) = 'user_partner_sim' THEN 'User Name = Partner'
                    WHEN LOWER(highest_category) = 'company_partner_sim' THEN 'User Company = Partner'
                    WHEN LOWER(highest_category) = 'userfinacc_partner_sim' THEN 'User Bank Account = Partner'
                    WHEN LOWER(highest_category) = 'user_partnerfinacc_sim' THEN 'User Name = Partner Bank Account'
                    WHEN LOWER(highest_category) = 'company_partnerfinacc_sim' THEN 'User Company = Partner Bank Account'
                    WHEN LOWER(highest_category) = 'userfinacc_partnerfinacc_sim' THEN 'User Bank Account = Partner Bank Account'
                    ELSE CONCAT('[Bulk Module]',"-",highest_category)  
                END AS gestun_category_caught,
                COALESCE(t2.is_cc_owned_by_the_bl_company,0) AS is_cc_owned_by_the_bl_company,
                COALESCE(t2.is_cc_ever_transact_with_bl_company,0) is_cc_ever_transact_with_bl_company,
                t1.method_type_name,
                t2.card_number,
                CAST(LEFT(t2.card_number,6) AS STRING) AS card_bin,
                t2.issuing_bank,
                t1.company_id,
                t1.user_company_email,
                t1.user_company_name,
                t1.user_company_type,
                t1.business_child,
                t1.business_child_segmentation,
                t1.register_ds AS registration_date,
                UPPER(t1.transaction_payment_channel_name) AS payment_channel_name,
                UPPER(t1.payment_method_name) AS payment_method_name,
                UPPER(t1.payment_provider_name) AS payment_provider_name,
                t1.transaction_phone_number AS phone_num,
                t1.amount,
                IF(t1.invoice_number IS NOT NULL,1,0) AS is_with_invoice,
                t1.user_owner_name_kyc AS user_name,
                t1.partner_user_name AS partner_name,
                t1.user_first_transaction_ds,
                t1.ddiff AS delta_from_first_transaction,
                t1.kyc_status,
                t1.trx_source,
                t1.pout_partner_bankaccount_name1,
                t1.pout_partner_bankaccount_no1,
                t1.pout_partner_bankaccount_bank1,
                t1.pout_partner_bankaccount_name2,
                t1.pout_partner_bankaccount_no2,
                t1.pout_partner_bankaccount_bank2,
                t1.pout_partner_bankaccount_name3,
                t1.pout_partner_bankaccount_no3,
                t1.pout_partner_bankaccount_bank3,
                t1.pin_user_bankaccount_name1 AS finance_account_bankacc_name1,
                t1.pin_user_bankaccount_no1 AS finance_account_bankacc_no1,
                t1.pin_user_bankaccount_bankname1 AS finance_account_bankacc_bank1,
                t1.pin_user_bankaccount_name2 AS finance_account_bankacc_name2,
                t1.pin_user_bankaccount_no2 AS finance_account_bankacc_no2,
                t1.pin_user_bankaccount_bankname2 AS finance_account_bankacc_bank2,
                t1.pin_user_bankaccount_name3 AS finance_account_bankacc_name3,
                t1.pin_user_bankaccount_no3 AS finance_account_bankacc_no3,
                t1.pin_user_bankaccount_bankname3 AS finance_account_bankacc_bank3,
            FROM fct_trx AS t1 
            LEFT JOIN 
                    (
                        SELECT 
                            external_id,
                            company_id,
                            --cc_details,
                            t1.card_number,
                            MAX(t3.issuing_bank) AS issuing_bank,
                            MAX(t4.is_cc_owned_by_the_bl_company) is_cc_owned_by_the_bl_company,
                            MAX(t4.is_cc_ever_transact_with_bl_company) AS is_cc_ever_transact_with_bl_company
                        FROM `paper-prod.datawarehouse_dwd.fct_digitalpayment_transaction_ccpayment_ext_1d` AS t1
                        JOIN  
                            (
                                SELECT DISTINCT order_id 
                                FROM fct_trx
                                WHERE UPPER(method_type_name) = 'CREDIT CARD'
                            ) AS t2 
                        ON t1.external_id = t2.order_id
                        LEFT JOIN 
                            (
                                SELECT 
                                    LEFT(masked_card_number,6) AS card_bin,
                                    MAX(issuing_bank_name_e) AS issuing_bank
                                FROM `paper-prod.datawarehouse_rpt.ppr0003repfino_2_raw`
                                GROUP BY 1
                            ) AS t3 
                        ON CAST(LEFT(t1.card_number,6) AS STRING) = CAST(t3.card_bin AS STRING)
                        LEFT JOIN 
                            (
                                SELECT 
                                    rt1.card_number,
                                    MAX(IF(rt2.cc_desc IS NOT NULL,1,0)) AS is_cc_owned_by_the_bl_company,
                                    MAX(IF(rt3.cc_desc IS NOT NULL,1,0)) AS is_cc_ever_transact_with_bl_company
                                FROM
                                        (
                                            SELECT DISTINCT 
                                                card_number
                                            FROM fct_cc_usage
                                        ) AS rt1 
                                LEFT JOIN 
                                        (           
                                            SELECT 
                                                cc_desc,
                                                company_id,
                                                card_number,
                                            FROM con_cc_bl
                                            WHERE cc_desc = 'CC owned by the blacklisted company ID'
                                        ) AS rt2 
                                ON CAST(rt1.card_number AS STRING) = CAST(rt2.card_number AS STRING)
                                LEFT JOIN 
                                        (           
                                            SELECT 
                                                cc_desc,
                                                company_id,
                                                card_number,
                                            FROM con_cc_bl
                                            WHERE cc_desc = 'CC used to transact with the blacklisted company ID'
                                        ) AS rt3 
                                ON CAST(rt1.card_number AS STRING) = CAST(rt3.card_number AS STRING)
                                GROUP BY 1
                            ) AS t4 
                        ON CAST(t1.card_number AS STRING) = CAST(t4.card_number AS STRING)
                        WHERE LOWER(payment_status) = 'paid'
                        GROUP BY 1,2,3
                    ) AS t2
            ON t1.external_id = t2.external_id
            LEFT JOIN 
                    (
                        SELECT 
                            external_id,
                            MAX(rf_pred_proba_e) AS rf_fraud_prob,
                            MAX(xgb_pred_proba_e) AS xgb_fraud_prob
                        FROM con_ml
                        GROUP BY 1
                    ) AS t3 
            ON CAST(t1.external_id AS STRING) = CAST(t3.external_id AS STRING)
            LEFT JOIN 
                    (
                        SELECT 
                            digital_payment_type,
                            finance_account_name_bl,
                            finance_account_bank_account_number,
                            last_action_ds
                        FROM dim_bl
                    ) AS t4 --PayOut Blacklist Bank Account
            ON  LOWER(t1.digital_payment_type) = LOWER(t4.digital_payment_type)
            AND DATE(t1.payment_ds_rddp) >= DATE(t4.last_action_ds)
            AND (
                    LOWER(t1.pout_partner_bankaccount_name1) = LOWER(t4.finance_account_name_bl) OR 
                    LOWER(t1.pout_partner_bankaccount_name2) = LOWER(t4.finance_account_name_bl) OR 
                    LOWER(t1.pout_partner_bankaccount_name3) = LOWER(t4.finance_account_name_bl)  
                )
            LEFT JOIN 
                    (
                        SELECT 
                            digital_payment_type,
                            finance_account_name_bl,
                            finance_account_bank_account_number,
                            last_action_ds
                        FROM dim_bl
                    ) AS t5 --PayOut Blacklist Bank Account Name
            ON  LOWER(t1.digital_payment_type) = LOWER(t5.digital_payment_type)
            AND DATE(t1.payment_ds_rddp) >= DATE(t5.last_action_ds)
            AND (
                    CAST(t1.pout_partner_bankaccount_no1 AS STRING) = CAST(t5.finance_account_bank_account_number AS STRING) OR 
                    CAST(t1.pout_partner_bankaccount_no2 AS STRING) = CAST(t5.finance_account_bank_account_number AS STRING) OR 
                    CAST(t1.pout_partner_bankaccount_no3 AS STRING) = CAST(t5.finance_account_bank_account_number AS STRING)
                )
            LEFT JOIN 
                    (
                        SELECT 
                            digital_payment_type,
                            finance_account_name_bl,
                            finance_account_bank_account_number,
                            last_action_ds
                        FROM dim_bl
                    ) AS t6 --PayIn Blacklist Bank Account Name
            ON  LOWER(t1.digital_payment_type) = LOWER(t6.digital_payment_type)
            AND DATE(t1.payment_ds_rddp) >= DATE(t6.last_action_ds)
            AND (
                    LOWER(t1.pin_user_bankaccount_name1) = LOWER(t6.finance_account_name_bl) OR 
                    LOWER(t1.pin_user_bankaccount_name2) = LOWER(t6.finance_account_name_bl) OR 
                    LOWER(t1.pin_user_bankaccount_name3) = LOWER(t6.finance_account_name_bl)  
                )
            LEFT JOIN 
                    (
                        SELECT 
                            digital_payment_type,
                            finance_account_name_bl,
                            finance_account_bank_account_number,
                            last_action_ds
                        FROM dim_bl
                    ) AS t7 --PayOut Blacklist Bank Account Name
            ON  LOWER(t1.digital_payment_type) = LOWER(t7.digital_payment_type)
            AND DATE(t1.payment_ds_rddp) >= DATE(t7.last_action_ds)
            AND (
                    CAST(t1.pin_user_bankaccount_no1 AS STRING) = CAST(t7.finance_account_bank_account_number AS STRING) OR 
                    CAST(t1.pin_user_bankaccount_no2 AS STRING) = CAST(t7.finance_account_bank_account_number AS STRING) OR 
                    CAST(t1.pin_user_bankaccount_no3 AS STRING) = CAST(t7.finance_account_bank_account_number AS STRING)
                )
            LEFT JOIN 
                    (
                        SELECT DISTINCT 
                            order_id,
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
                            per_sim
                        FROM con_gestun
                    ) AS t8 
            ON t1.external_id = t8.order_id
            AND (UPPER(t1.method_type_name) = 'CREDIT_CARD' OR UPPER(t1.method_type_name) = 'CREDIT CARD')
        ) AS t1 
LEFT JOIN 
        (
            SELECT 
                payment_ds,
                card_number,
                CAST(cnt_mult_acc AS INT64) AS cnt_mult_acc,
                company_name_list
            FROM con_mult
        ) AS t2 
ON  DATE(t1.payment_ds) = DATE(t2.payment_ds)
AND (CAST(LEFT(t1.card_number,6) AS STRING) = CAST(LEFT(t2.card_number,6) AS STRING) AND CAST(RIGHT(t1.card_number,4) AS STRING) = CAST(RIGHT(t2.card_number,4) AS STRING) )
AND (UPPER(t1.method_type_name) = 'CREDIT_CARD' OR UPPER(t1.method_type_name) = 'CREDIT CARD') 
WHERE   (
            CAST(ml_rf_prob AS FLOAT64) >= 0.9 OR 
            CAST(ml_xgb_prob AS FLOAT64) >= 0.9 OR 
            is_rel_to_blacklist_byname_poutdisb = 1 OR 
            is_rel_to_blacklist_bybankaccount_poutdisb = 1 OR 
            is_rel_to_blacklist_byname_finacc = 1 OR 
            is_rel_to_blacklist_bybankaccount_finacc = 1 OR 
            is_gestun = 1 OR 
            is_cc_owned_by_the_bl_company = 1 OR 
            is_cc_ever_transact_with_bl_company = 1 OR 
            cnt_mult_acc >= 5
        )
AND t1.payment_ds >= DATE('2024-02-26')
GROUP BY 1,2,3,4,5,22,23,24,25,26,27,28,29,30,31,33,34,35,39,40,43,44,45,46,47,48,49,50,51,52,53,54,55,56,57,58,59,60,61,62
ORDER BY payment_ds DESC, company_id DESC