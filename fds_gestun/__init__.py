"""Gestun (credit-card cash-out) detection for paper.id.

    from fds_gestun import build_features, GestunModel

    model = GestunModel.load()
    model.score(build_features(company_ids))
"""
from .features import build_features, model_feature_names
from .model import GestunModel, train, risk_band

__version__ = "1.0.0"
__all__ = ["build_features", "model_feature_names", "GestunModel", "train", "risk_band"]
