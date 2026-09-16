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
# Describe how the dataset was built, not what the company did. mlfds_n_txns is 44% null
# and its missingness is label-correlated.
PIPELINE_ARTIFACTS = ("mlfds_n_txns", "peer_vocab_level", "n_tokens")
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

# Out-of-fold precision/recall on 582 labelled companies, by threshold:
#   0.5 -> 0.877 / 0.834      0.7 -> 0.912 / 0.761      0.8 -> 0.937 / 0.727
# 0.5 is the default; raise it if review capacity is the constraint.
DECISION_THRESHOLD = float(os.getenv("FDS_THRESHOLD", "0.5"))
RISK_BANDS = ((0.90, "very high"), (0.70, "high"), (0.50, "elevated"), (0.30, "borderline"))
