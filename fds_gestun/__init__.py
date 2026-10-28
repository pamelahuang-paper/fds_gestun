"""Gestun (credit-card cash-out) detection for paper.id.

    from fds_gestun import build_features, GestunModel

    model = GestunModel.load()
    model.score(build_features(company_ids))

Pipeline role : public API. `from fds_gestun import build_features, GestunModel`.
Deploy        : REQUIRED.
Change when   : you add something callers should reach without a deep import.
"""
from .features import (build_features, build_transaction_detail,
                       model_feature_names)
from .model import GestunModel, train, risk_band, review_queue

__version__ = "1.0.0"
__all__ = ["build_features", "build_transaction_detail", "model_feature_names",
           "GestunModel", "train", "risk_band", "review_queue"]
