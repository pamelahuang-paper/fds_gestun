"""Cross-validated evaluation. Quote the standard deviation with the mean --
at this sample size a single split moves several points on the seed."""
from __future__ import annotations
import logging
from typing import Sequence

import numpy as np
import pandas as pd
from sklearn.model_selection import (RepeatedStratifiedKFold, StratifiedKFold,
                                     cross_val_predict)
from sklearn.metrics import (confusion_matrix, precision_score, recall_score,
                             f1_score, roc_auc_score)
from xgboost import XGBClassifier

from . import config, features, model as model_mod

log = logging.getLogger(__name__)


def _fit_predict(X, y, train_idx, test_idx):
    y_train = y.iloc[train_idx]
    neg, pos = int((y_train == 0).sum()), int(y_train.sum())
    clf = XGBClassifier(scale_pos_weight=neg / pos, **config.MODEL_PARAMS.as_kwargs())
    clf.fit(X.iloc[train_idx], y_train)
    return (clf.predict(X.iloc[test_idx]),
            clf.predict_proba(X.iloc[test_idx])[:, 1])


def cross_validate(training_frame: pd.DataFrame | None = None,
                   feature_names: Sequence[str] | None = None,
                   n_splits: int = 5, n_repeats: int = 10) -> dict:
    """Repeated stratified k-fold. Every company is predicted while held out."""
    if training_frame is None:
        training_frame = model_mod.load_training_set()
    feature_names = list(feature_names or features.model_feature_names())
    missing = [f for f in feature_names if f not in training_frame.columns]
    if missing:
        raise ValueError(
            f"training set is missing {len(missing)} features: {missing[:5]}. "
            "Evaluating with them absent would silently report a smaller model.")
    stub = model_mod.GestunModel(
        booster=None, feature_names=feature_names,  # type: ignore[arg-type]
        categories=model_mod._categorical_levels(training_frame, feature_names),
        trained_on=len(training_frame), positives=0)
    X = stub.prepare(training_frame)
    y = training_frame["is_gestun"].astype(int)

    precision, recall, f1, auc = [], [], [], []
    splitter = RepeatedStratifiedKFold(n_splits=n_splits, n_repeats=n_repeats,
                                       random_state=config.SEED)
    for train_idx, test_idx in splitter.split(X, y):
        pred, proba = _fit_predict(X, y, train_idx, test_idx)
        truth = y.iloc[test_idx]
        precision.append(precision_score(truth, pred, zero_division=0))
        recall.append(recall_score(truth, pred))
        f1.append(f1_score(truth, pred))
        auc.append(roc_auc_score(truth, proba))
    return {
        "n_companies": len(y), "n_gestun": int(y.sum()),
        "n_features": len(feature_names), "n_fits": len(precision),
        "precision": round(float(np.mean(precision)), 3),
        "precision_sd": round(float(np.std(precision)), 3),
        "recall": round(float(np.mean(recall)), 3),
        "recall_sd": round(float(np.std(recall)), 3),
        "f1": round(float(np.mean(f1)), 3),
        "roc_auc": round(float(np.mean(auc)), 3),
    }


def threshold_table(training_frame: pd.DataFrame | None = None,
                    feature_names: Sequence[str] | None = None) -> pd.DataFrame:
    """Out-of-fold confusion matrix at each candidate threshold. This is the
    table to set DECISION_THRESHOLD from -- not the default 0.5."""
    if training_frame is None:
        training_frame = model_mod.load_training_set()
    feature_names = list(feature_names or features.model_feature_names())
    missing = [f for f in feature_names if f not in training_frame.columns]
    if missing:
        raise ValueError(
            f"training set is missing {len(missing)} features: {missing[:5]}. "
            "Evaluating with them absent would silently report a smaller model.")
    stub = model_mod.GestunModel(
        booster=None, feature_names=feature_names,  # type: ignore[arg-type]
        categories=model_mod._categorical_levels(training_frame, feature_names),
        trained_on=len(training_frame), positives=0)
    X = stub.prepare(training_frame)
    y = training_frame["is_gestun"].astype(int)
    neg, pos = int((y == 0).sum()), int(y.sum())
    clf = XGBClassifier(scale_pos_weight=neg / pos, **config.MODEL_PARAMS.as_kwargs())
    oof = cross_val_predict(
        clf, X, y, cv=StratifiedKFold(5, shuffle=True, random_state=config.SEED),
        method="predict_proba")[:, 1]

    rows = []
    for threshold in (0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9):
        pred = (oof >= threshold).astype(int)
        tn, fp, fn, tp = confusion_matrix(y, pred).ravel()
        rows.append({"threshold": threshold, "TP": tp, "FP": fp, "FN": fn, "TN": tn,
                     "precision": round(precision_score(y, pred, zero_division=0), 3),
                     "recall": round(recall_score(y, pred), 3)})
    return pd.DataFrame(rows)
