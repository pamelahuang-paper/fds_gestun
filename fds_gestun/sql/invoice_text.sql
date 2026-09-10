-- Extracted from FDS_Gestun_Combined_Features.ipynb.
-- @company_ids : ARRAY<STRING> of companies to build features for.
-- Edit this file, not the notebook: the notebook is exploration, this is the source of truth.

WITH b AS (
  SELECT company_id, invoice_id,
         TRIM(IFNULL(invoice_item_name, ''))               AS raw_nm,
         LOWER(TRIM(IFNULL(invoice_item_name, '')))        AS nm,
         LOWER(TRIM(IFNULL(invoice_item_description, ''))) AS ds,
         LOWER(CONCAT(IFNULL(invoice_item_name, ''), ' ',
                      IFNULL(invoice_item_description, ''))) AS t
  FROM `paper-prod.data_warehouse_layer.fact__paper__invoice_item`
  WHERE company_id IN UNNEST(@company_ids)
),
per_invoice AS (
  SELECT company_id, invoice_id, COUNT(*) AS lines
  FROM b WHERE invoice_id IS NOT NULL GROUP BY 1, 2
),
inv AS (
  SELECT company_id, AVG(CAST(lines = 1 AS INT64)) AS pct_single_line_invoice
  FROM per_invoice GROUP BY 1
),
name_freq  AS (SELECT company_id, nm, COUNT(*) AS n FROM b WHERE nm != '' GROUP BY 1, 2),
name_share AS (SELECT company_id, nm, n, SUM(n) OVER (PARTITION BY company_id) AS tot FROM name_freq),
conc AS (
  SELECT company_id,
    MAX(n) / ANY_VALUE(tot) AS top1_item_name_share,
    SUM(POW(n / tot, 2))    AS item_name_hhi
  FROM name_share GROUP BY 1
)
SELECT b.company_id,
  COUNT(*)                   AS n_items,
  COUNT(DISTINCT invoice_id) AS n_invoices,

  -- thematic
  ROUND(AVG(CAST(REGEXP_CONTAINS(t, r'\b(baju|sepatu|obat|makan|tiket|travel|tour|liburan|softlens|kosmetik|skincare|hp|handphone|laptop)\b') AS INT64)), 4) AS personal_consumption_rate,
  ROUND(AVG(CAST(REGEXP_CONTAINS(t, r'\b(pulsa|vouc?her|voucer|token|saldo|top ?up|e-?money|emoney|gopay|ovo|dana)\b') AS INT64)), 4)                        AS cash_equivalent_rate,
  ROUND(AVG(CAST(REGEXP_CONTAINS(t, r'\b(bayar|tagihan|pelunasan|lunas|cicilan|angsuran|pembayaran|utang|hutang|bon)\b') AS INT64)), 4)                       AS pay_a_bill_rate,
  ROUND(AVG(CAST(REGEXP_CONTAINS(t, r'\b(renovasi|proyek|project|bahan|material)\b') AS INT64)), 4)                                                           AS renovation_project_rate,

  -- repetition
  ROUND(ANY_VALUE(conc.top1_item_name_share), 4) AS top1_item_name_share,
  ROUND(ANY_VALUE(conc.item_name_hhi), 4)        AS item_name_hhi,
  ROUND(1 / ANY_VALUE(conc.item_name_hhi), 2)    AS eff_item_names,

  -- shape and formatting
  ROUND(STDDEV(LENGTH(nm)) / NULLIF(AVG(LENGTH(nm)), 0), 4)   AS name_len_cv,
  ROUND(STDDEV(LENGTH(ds)) / NULLIF(AVG(LENGTH(ds)), 0), 4)   AS desc_len_cv,
  ROUND(ANY_VALUE(inv.pct_single_line_invoice), 4)            AS pct_single_line_invoice,
  ROUND(AVG(CAST(nm = ds AS INT64)), 4)                       AS name_eq_desc_rate,
  ROUND(AVG(CAST(REGEXP_CONTAINS(nm, r'[0-9]') AS INT64)), 4) AS digit_in_item_name_rate,
  ROUND(AVG(CAST(LENGTH(nm) <= 3 AS INT64)), 4)               AS degenerate_name_rate,
  ROUND(AVG(CAST(REGEXP_CONTAINS(nm, r'[|/()\-]') AS INT64)), 4) AS punct_name_rate,
  ROUND(AVG(CAST(REGEXP_CONTAINS(CONCAT(nm, ' ', ds), r'\b\d+\s?(ml|gr|gram|kg|pcs|pack|cm|mm|inch|liter|ltr|box|lusin|rim)\b') AS INT64)), 4) AS unit_token_rate,
  ROUND(AVG(CAST(raw_nm = UPPER(raw_nm) AND REGEXP_CONTAINS(raw_nm, r'[A-Z]{2,}') AS INT64)), 4) AS allcaps_name_rate

FROM b LEFT JOIN conc USING (company_id) LEFT JOIN inv USING (company_id)
GROUP BY 1
