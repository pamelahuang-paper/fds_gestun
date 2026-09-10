-- Extracted from FDS_Gestun_Combined_Features.ipynb.
-- @company_ids : ARRAY<STRING> of companies to build features for.
-- Edit this file, not the notebook: the notebook is exploration, this is the source of truth.

WITH base AS (SELECT company_id, lbl AS is_gestun FROM (
    SELECT company_id, MIN(is_gestun) AS lbl, COUNT(DISTINCT is_gestun) AS n_lab
    FROM (SELECT company_id, 0 AS is_gestun
   FROM UNNEST(@company_ids) AS company_id) GROUP BY company_id)
  WHERE n_lab = 1),
a AS (
  SELECT company_id, user_id, fingerprint_id, ip_address_code, user_agent_name,
         is_success_flag, log_created_datetime AS ts
  FROM `paper-prod.data_warehouse_layer.fact__paper__auth_log`
  WHERE fingerprint_id IS NOT NULL
),
-- how many DIFFERENT companies use each fingerprint / ip (whole population, not just labelled)
fp_spread AS (SELECT fingerprint_id,  COUNT(DISTINCT company_id) AS cos_on_fp FROM a GROUP BY 1),
ip_spread AS (SELECT ip_address_code, COUNT(DISTINCT company_id) AS cos_on_ip FROM a GROUP BY 1),
-- blacklisted devices: map code -> id
bl AS (
  SELECT DISTINCT f.fingerprint_id
  FROM `paper-prod.data_warehouse_pii_layer.dim__paper__fingerprint` f
  JOIN `paper-prod.data_warehouse_pii_layer.dim__paper__blacklisted_fingerprint` b
    ON f.fingerprint_code = b.fingerprint_code
),
j AS (
  SELECT a.*, fs.cos_on_fp, ips.cos_on_ip,
         IF(bl.fingerprint_id IS NOT NULL, 1, 0) AS is_bl_fp
  FROM a
  LEFT JOIN fp_spread fs USING (fingerprint_id)
  LEFT JOIN ip_spread ips USING (ip_address_code)
  LEFT JOIN bl USING (fingerprint_id)
)
SELECT b.company_id,
  COUNT(*)                                   AS n_auth_events,
  COUNT(DISTINCT j.fingerprint_id)           AS n_fingerprints,
  COUNT(DISTINCT j.ip_address_code)          AS n_ip_addresses,
  COUNT(DISTINCT j.user_agent_name)          AS n_user_agents,
  COUNT(DISTINCT j.user_id)                  AS n_users,
  ROUND(SAFE_DIVIDE(COUNT(DISTINCT j.fingerprint_id), COUNT(DISTINCT j.user_id)),3) AS fp_per_user,
  ROUND(SAFE_DIVIDE(COUNT(DISTINCT j.fingerprint_id), COUNT(*)),4)                  AS fp_per_auth_event,
  -- device / IP sharing with OTHER companies  (fraud-ring signal)
  MAX(j.cos_on_fp)                                                     AS max_companies_on_a_device,
  ROUND(AVG(CAST(j.cos_on_fp > 1 AS INT64)),4)                         AS shared_device_event_rate,
  MAX(j.cos_on_ip)                                                     AS max_companies_on_an_ip,
  ROUND(AVG(CAST(j.cos_on_ip > 1 AS INT64)),4)                         AS shared_ip_event_rate,
  -- blacklist linkage
  MAX(j.is_bl_fp)                                                      AS has_blacklisted_device,
  -- behaviour
  ROUND(AVG(j.is_success_flag),4)                                      AS auth_success_rate,
  DATE_DIFF(DATE(MAX(j.ts)), DATE(MIN(j.ts)), DAY)                     AS auth_span_days,
  ROUND(SAFE_DIVIDE(COUNT(*), NULLIF(DATE_DIFF(DATE(MAX(j.ts)), DATE(MIN(j.ts)), DAY),0)),3) AS auth_per_day
FROM base b LEFT JOIN j ON j.company_id = b.company_id
GROUP BY 1
