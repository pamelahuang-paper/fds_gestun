"""
Project: FDS GESTUN
Owner: Pamela Huang (Risk)
Created: September 2026
Description: For configuration purpose
"""
from __future__ import annotations
import os
from dataclasses import dataclass, field
from pathlib import Path

PKG_DIR = Path(__file__).resolve().parent
SQL_DIR = PKG_DIR / "sql"
REPO_DIR = PKG_DIR.parent

# --- BigQuery -----------------------------------------------------------------
GCP_PROJECT = os.getenv("FDS_GCP_PROJECT", "paper-prod")
BQ_LOCATION = os.getenv("FDS_BQ_LOCATION", "asia-southeast1")
# Unset -> google.auth default credentials (service account on the runner,
# workload identity in GKE). Only set this for local development.
CREDENTIALS_PATH = os.getenv("FDS_GCP_CREDENTIALS")
BQ_TIMEOUT_SECONDS = int(os.getenv("FDS_BQ_TIMEOUT", "1800"))
# Guard against a runaway scan; every feature query is a full scan of rddp.
BQ_MAX_BYTES_BILLED = int(os.getenv("FDS_BQ_MAX_BYTES", str(2_000 * 1024**3)))  # 2 TB

# --- artefacts ----------------------------------------------------------------
MODEL_DIR = Path(os.getenv("FDS_MODEL_DIR", REPO_DIR / "artifacts"))
MODEL_PATH = MODEL_DIR / "gestun_model.json"
METADATA_PATH = MODEL_DIR / "gestun_model_meta.json"

TRAINING_SET_PATH = Path(
    os.getenv("FDS_TRAINING_SET", REPO_DIR / "fds_gestun_training_set.csv"))
FEATURE_DICT_PATH = Path(
    os.getenv("FDS_FEATURE_DICT", REPO_DIR / "fds_gestun_features_179.csv"))

# --- features -----------------------------------------------------------------
# Label-derived: a clean company excludes itself from the peer count and a gestun one
# does not, so the classes sit exactly 1 apart. mlfds_label_rate is a different label.
LEAKY_FEATURES = ("n_peers_child", "n_peers_parent", "mlfds_label_rate")
# Raw identifiers. model_feature_names() always claimed to exclude identifiers;
# these two reached the model anyway because they sit in the feature dictionary
# and nothing named them. user_owner_name carried 4.0% of total gain as ~280
# literal owner names memorised from the training set -- a company whose owner
# is not on that list gets nothing from it, so the gain was recall spent on
# recognising 582 specific people. Dropping both: AUC 0.957 -> 0.961, and at
# threshold 0.98 precision 0.959 -> 0.963 with recall 0.454 -> 0.512. It was
# costing accuracy, not buying it.
IDENTIFIER_FEATURES = ("user_owner_name", "user_owner_phone")
# Describe how the dataset was built, not what the company did. mlfds_n_txns is 44% null
# and its missingness is label-correlated.
PIPELINE_ARTIFACTS = ("mlfds_n_txns", "peer_vocab_level", "n_tokens")
# Built for the rule layer, not for the model: they are in the feature dictionary
# and in every scored feature matrix, but the training set predates them and
# rules.py is their only consumer. Listing them here keeps `train` runnable and
# stops them silently becoming model inputs on the next retrain, which would
# change what the model is without anyone deciding to. Promote one by rebuilding
# the training set with it and removing it from this tuple.
RULE_LAYER_FEATURES = (
    "n_in_partners", "pct_in_partner_eq_self", "pct_in_txn_partner_eq_self",
    "pct_amount_in_partner_eq_self", "has_in_partner_eq_self",
    "n_cc_txns_named", "pct_cc_txn_holder_eq_self",
    "pct_cc_amount_holder_eq_self", "has_cc_holder_eq_self",
    "max_cards_in_one_txn", "max_attempts_in_one_txn", "avg_cards_per_txn",
    "pct_txn_multi_card", "n_payer_users", "max_names_per_payer",
    "pct_txn_payer_multi_name", "avg_txn_per_payer",
    "top1_out_partner_amount_share", "top1_out_partner_is_personal",
    "top1_in_partner_amount_share")
PTCV_FEATURES = ("pct_partner_is_ptcv", "pct_txn_to_ptcv_partner",
                 "pct_amount_to_ptcv_partner", "n_ptcv_partners", "has_ptcv_partner")

# --- model --------------------------------------------------------------------
SEED = 42


@dataclass(frozen=True)
class ModelParams:
    n_estimators: int = 300
    max_depth: int = 3
    learning_rate: float = 0.05
    subsample: float = 0.8
    colsample_bytree: float = 0.8
    reg_lambda: float = 2.0
    min_child_weight: int = 2
    tree_method: str = "hist"
    eval_metric: str = "aucpr"
    random_state: int = SEED
    n_jobs: int = int(os.getenv("FDS_N_JOBS", "4"))

    def as_kwargs(self) -> dict:
        return {**self.__dict__, "enable_categorical": True}


MODEL_PARAMS = ModelParams()

# Chosen on the flag rate, not on a precision table: precision barely moves above
# 0.90 while recall falls away, and the score is a ranking rather than a
# likelihood (see gestun_probability's description in the DAG). Scoring the
# 17-23 Sep week of 5,643 companies, this model flags 4.7% at 0.99 -- next to the
# 5.0% the old pprrsk001 model flags on the same population, the only external
# reference point that exists. At 0.70 it flagged 33%, which is the training
# prior (35.2%) played back, not a finding.
#
# WARNING, read before retraining: this number is tuned to one model's score
# distribution and does not survive a retrain. Dropping two identifier features
# moved the median score 0.276 -> 0.404 and turned 0.98 from a 5.3% flag rate
# into 9.6% on the same week, with no change in what the model was asked to do.
# Re-measure the flag rate after every retrain. The durable fix is to flag a
# quantile of the batch instead of a fixed probability; that is not built yet.
DECISION_THRESHOLD = float(os.getenv("FDS_THRESHOLD", "0.99"))
RISK_BANDS = ((0.90, "very high"), (0.70, "high"), (0.50, "elevated"), (0.30, "borderline"))

# --- review queue -------------------------------------------------------------
# decision answers "does the model think this is gestun". The queue answers the
# different question "is this worth a reviewer's hour", and adds the rule layer.
#
# REVIEW_THRESHOLD defaults to DECISION_THRESHOLD: a queue looser than the
# decision feeding it only re-opens the flag-rate argument one column over. Set
# it higher only to ration a backlog.
#
# Why a rupiah floor and not a transaction count: ticket size does not separate
# the classes (clean companies have the HIGHER median ticket, 18.1jt against
# 11.1jt), but total value does, and a queue sorted by money reviews the
# exposure rather than the row count. 10jt drops 37% of companies while keeping
# 98% of the flagged rupiah.
REVIEW_THRESHOLD = float(os.getenv("FDS_REVIEW_THRESHOLD",
                                   str(DECISION_THRESHOLD)))
REVIEW_MIN_TPV = float(os.getenv("FDS_REVIEW_MIN_TPV", "10000000"))
