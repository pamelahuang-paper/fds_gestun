-- PATCH: is_ml_predict_fraud must not report "not fraud" for unscored transactions
--
-- Scheduled query : datawarehouse_rpt.ppr0002reprisid_1_list_of_fraudulent_transaction
-- Feeds           : Looker Studio (ML fraud columns)
-- Change          : ONE line. Line 529 of the current query body.
-- Risk            : low. Only the NULL case changes; 1s and 0s stay 1s and 0s.
--
-- THE BUG
--
-- rf_fraud_prob and xgb_fraud_prob come from datawarehouse_dwd.mlfds_ml_labeling,
-- which is loaded once a week by a Composer DAG. When that load lands nearly
-- empty, both columns are NULL -- and IF() with a NULL condition falls to its
-- ELSE branch, so the transaction is published as is_ml_predict_fraud = 0.
--
-- Looker then cannot tell "the model scored this and it looks fine" from "the
-- model never saw this". Observed, week of 2026-09-28:
--
--     payment_ws_mon  rows   is_ml_predict_fraud=1   ml_xgb_prob present
--     2026-09-28      1973   0                       0        <-- unscored
--     2026-09-21      6109   365                     2189
--     2026-09-14      6196   841                     5150
--
-- 1,973 transactions shown as "not fraud" that nothing had looked at. The same
-- thing happened the week of 2026-09-03 (the upstream load wrote 4 rows), so this
-- is recurring, not a one-off.
--
-- The upstream load is a separate problem for its owner -- it succeeds while
-- loading an empty file, so nothing alerts. This patch does not fix that. It
-- makes the symptom visible instead of silently wrong, which is what lets anyone
-- notice next time.

-- ----------------------------------------------------------------------------
-- BEFORE  (line 529)
-- ----------------------------------------------------------------------------
--                 IF(CAST(rf_fraud_prob AS FLOAT64) >= 0.90 OR CAST(xgb_fraud_prob AS FLOAT64) >= 0.90,1,0) is_ml_predict_fraud,

-- ----------------------------------------------------------------------------
-- AFTER   (replace that single line with this block)
-- ----------------------------------------------------------------------------
                CASE
                  -- no score at all: the model has not seen this transaction.
                  -- NULL, not 0 -- 0 is a verdict, and there is none.
                  WHEN rf_fraud_prob IS NULL AND xgb_fraud_prob IS NULL THEN NULL
                  WHEN CAST(rf_fraud_prob AS FLOAT64) >= 0.90
                    OR CAST(xgb_fraud_prob AS FLOAT64) >= 0.90 THEN 1
                  ELSE 0
                END AS is_ml_predict_fraud,

-- ----------------------------------------------------------------------------
-- Nothing else in the query needs to change.
--
-- Line 462 aggregates it as MAX(is_ml_predict_fraud). MAX over an all-NULL group
-- returns NULL, which is the behaviour this patch wants, so leave it alone.
--
-- One case it deliberately does not cover: a transaction scored by only one of
-- the two models. If rf is NULL and xgb is 0.95 the result is 1, and if rf is
-- NULL and xgb is 0.10 the result is 0. That matches the original logic and is
-- correct -- one model's verdict is still a verdict.
-- ----------------------------------------------------------------------------


-- ============================================================================
-- VERIFY, after the patched query has run once
-- ============================================================================
-- Expect: the current week has is_ml_predict_fraud NULL rather than 0, and weeks
-- with a healthy upstream load are unchanged.

SELECT
  payment_ws_mon,
  COUNT(*)                                   AS rows_total,
  COUNTIF(is_ml_predict_fraud = 1)           AS flagged,
  COUNTIF(is_ml_predict_fraud = 0)           AS scored_clean,
  COUNTIF(is_ml_predict_fraud IS NULL)       AS not_scored,   -- 0 before the patch
  COUNTIF(ml_xgb_prob IS NOT NULL)           AS has_xgb_prob
FROM `paper-prod.datawarehouse_rpt.ppr0002reprisid_1_list_of_fraudulent_transaction`
WHERE payment_ws_mon >= DATE_SUB(CURRENT_DATE('Asia/Jakarta'), INTERVAL 28 DAY)
GROUP BY payment_ws_mon
ORDER BY payment_ws_mon DESC;

-- not_scored should equal rows_total - has_xgb_prob for each week. Where it does
-- not, some transactions have one model's score and not the other's, which is
-- fine and still counted as scored.


-- ============================================================================
-- ONE MORE THING, for whoever owns the Looker report
-- ============================================================================
-- Charts that sum or average is_ml_predict_fraud now skip the NULL rows instead
-- of counting them as zero, so a weekly fraud RATE computed as
-- AVG(is_ml_predict_fraud) becomes "rate among scored transactions" -- which is
-- the honest reading, but it is a change in meaning. If a chart needs the
-- denominator to stay the whole week, make that explicit:
--
--   SAFE_DIVIDE(COUNTIF(is_ml_predict_fraud = 1), COUNT(*))
--
-- and add a tile showing COUNTIF(is_ml_predict_fraud IS NULL) so a stalled
-- upstream load is visible on the page rather than buried in the arithmetic.
