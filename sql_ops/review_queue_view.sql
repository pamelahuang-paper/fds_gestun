-- The review queue as one table, for Connected Sheets / Looker to read.
--
-- Why a view and not a query pasted into the sheet: the queue definition lives in
-- one place. Change REVIEW_THRESHOLD or the rupiah floor in the pipeline and this
-- view keeps agreeing with it, because it reads the `review` column the pipeline
-- writes rather than re-deriving the rule from a threshold copied by hand.
--
-- Only the most recent window is returned. The table keeps every week; a reviewer
-- opening the sheet wants this week's work, and a sheet that grows without bound
-- is a sheet nobody scrolls. Filter on window_end in the sheet to look back.
--
-- Run once:
--   bq query --use_legacy_sql=false < sql_ops/review_queue_view.sql
-- Whoever reads it through Connected Sheets needs BigQuery Data Viewer on
-- datascience_public and the bigquery.jobs.create permission on some project.

CREATE OR REPLACE VIEW `paper-prod.datascience_public.fds_gestun_review_queue`
OPTIONS(description="Current week's gestun review queue. One row per company. "
                    "Sorted by rupiah at risk. Source of truth is "
                    "fds_gestun_scores; this view only filters and renames.")
AS
WITH latest AS (
  SELECT MAX(window_end) AS window_end
  FROM `paper-prod.datascience_public.fds_gestun_scores`
)
SELECT
  s.window_end,
  s.company_id,
  ROUND(s.gestun_pct, 1)            AS score_pct,
  s.decision,
  s.risk_band,
  IFNULL(s.rule_hits, '')           AS rule_hits,
  -- why this company is in the queue, in one readable column
  CASE
    WHEN s.decision = 'GESTUN' AND IFNULL(s.rule_hits, '') != '' THEN 'model + rule'
    WHEN s.decision = 'GESTUN'                                   THEN 'model'
    ELSE                                                              'rule only'
  END                               AS queued_by,
  s.n_txn_in_window                 AS n_txn,
  s.tpv_in_window                   AS tpv,
  s.scored_date,
  s.threshold,
  s.model_features
FROM `paper-prod.datascience_public.fds_gestun_scores` s
JOIN latest USING (window_end)
WHERE s.review
ORDER BY s.tpv_in_window DESC
