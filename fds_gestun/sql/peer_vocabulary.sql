-- Extracted from FDS_Gestun_Combined_Features.ipynb.
-- @company_ids : ARRAY<STRING> of companies to build features for.
-- Edit this file, not the notebook: the notebook is exploration, this is the source of truth.

WITH co AS (
  SELECT company_id,
         business_type_child_name  AS biz_child,
         business_type_parent_name AS biz_parent,
         ROW_NUMBER() OVER (PARTITION BY company_id ORDER BY company_id) AS rk
  FROM `paper-prod.data_warehouse_layer.dim__paper__company`
),
lbl AS (
  SELECT company_id, lbl AS is_gestun FROM (
    SELECT company_id, MIN(is_gestun) AS lbl, COUNT(DISTINCT is_gestun) AS n_lab
    FROM (SELECT company_id, 0 AS is_gestun
   FROM UNNEST(@pool_ids) AS company_id) GROUP BY company_id)
  WHERE n_lab = 1
),
b AS (
  SELECT l.is_gestun, r.company_id, c.biz_child, c.biz_parent,
         LOWER(CONCAT(IFNULL(r.invoice_item_name, ''), ' ',
                      IFNULL(r.invoice_item_description, ''))) AS t
  FROM `paper-prod.data_warehouse_layer.fact__paper__invoice_item` r
  JOIN lbl l USING (company_id)
  LEFT JOIN (SELECT * FROM co WHERE rk = 1) c USING (company_id)
)
SELECT is_gestun, company_id, biz_child, biz_parent, w, COUNT(*) AS n
FROM b, UNNEST(REGEXP_EXTRACT_ALL(t, r'[a-z]{4,}')) AS w
GROUP BY 1, 2, 3, 4, 5
