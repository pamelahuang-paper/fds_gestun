"""Train, persist and apply the gestun classifier.

The saved artefact carries the feature order and the categorical level sets.
Both matter: XGBoost positions features by index, and a category the model has
never seen carries no information but will still be scored -- during evaluation
one novel user_owner_name produced a +4.13 contribution on its own.
"""
from __future__ import annotations
import json
import logging
from dataclasses import dataclass
from pathlib import Path
from typing import Sequence

import numpy as np
import pandas as pd
from xgboost import XGBClassifier

from . import config, features

log = logging.getLogger(__name__)


@dataclass
class GestunModel:
    booster: XGBClassifier
    feature_names: list[str]
    categories: dict[str, list[str]]
    trained_on: int
    positives: int

    # -- persistence -----------------------------------------------------------
    def save(self, model_path: Path | None = None,
             meta_path: Path | None = None) -> None:
        model_path = model_path or config.MODEL_PATH
        meta_path = meta_path or config.METADATA_PATH
        model_path.parent.mkdir(parents=True, exist_ok=True)
        self.booster.save_model(str(model_path))
        meta_path.write_text(json.dumps({
            "feature_names": self.feature_names,
            "categories": self.categories,
            "trained_on": self.trained_on,
            "positives": self.positives,
            "params": config.MODEL_PARAMS.as_kwargs(),
        }, indent=2))
        log.info("saved model to %s (%d features)", model_path, len(self.feature_names))

    @classmethod
    def load(cls, model_path: Path | None = None,
             meta_path: Path | None = None) -> "GestunModel":
        model_path = model_path or config.MODEL_PATH
        meta_path = meta_path or config.METADATA_PATH
        if not model_path.exists() or not meta_path.exists():
            raise FileNotFoundError(
                f"no trained model at {model_path}. Run `fds-gestun train` first.")
        meta = json.loads(meta_path.read_text())
        booster = XGBClassifier(**config.MODEL_PARAMS.as_kwargs())
        booster.load_model(str(model_path))
        return cls(booster=booster, feature_names=meta["feature_names"],
                   categories=meta["categories"], trained_on=meta["trained_on"],
                   positives=meta["positives"])

    # -- inference -------------------------------------------------------------
    def prepare(self, frame: pd.DataFrame) -> pd.DataFrame:
        """Align an arbitrary feature frame to the model's expected columns and
        categorical levels. Missing columns become NaN; unseen categories become
        NaN rather than a silently-invented level."""
        out = pd.DataFrame(index=frame.index)
        for name in self.feature_names:
            col = frame[name] if name in frame.columns else pd.Series(
                np.nan, index=frame.index)
            if name in self.categories:
                levels = self.categories[name]
                values = col.astype("object")
                # Mask unseen levels explicitly. Casting straight to the dtype is
                # deprecated in pandas and will raise once that lands.
                values = values.where(values.isin(levels))
                col = pd.Categorical(values, categories=levels)
            else:
                # Everything the model saw as numeric must arrive numeric. A source
                # that returned no rows yields all-NaN string columns, which XGBoost
                # rejects at predict time rather than treating as missing.
                col = pd.to_numeric(col, errors="coerce")
            out[name] = col
        return out

    def predict_proba(self, frame: pd.DataFrame) -> np.ndarray:
        return self.booster.predict_proba(self.prepare(frame))[:, 1]

    def score(self, frame: pd.DataFrame,
              threshold: float | None = None) -> pd.DataFrame:
        """Return one row per company: probability, decision and risk band."""
        threshold = config.DECISION_THRESHOLD if threshold is None else threshold
        proba = self.predict_proba(frame)
        prepared = self.prepare(frame)
        result = pd.DataFrame({
            "company_id": frame["company_id"].to_numpy()
            if "company_id" in frame.columns else np.arange(len(frame)),
            "gestun_probability": proba.round(4),
            "gestun_pct": (proba * 100).round(1),
            "decision": np.where(proba >= threshold, "GESTUN", "clean"),
            "risk_band": [risk_band(p) for p in proba],
            "features_present": prepared.notna().sum(axis=1).to_numpy(),
            "features_total": len(self.feature_names),
        })
        return result.sort_values("gestun_probability", ascending=False,
                                  ignore_index=True)


def risk_band(p: float) -> str:
    for cutoff, label in config.RISK_BANDS:
        if p >= cutoff:
            return label
    return "low"


def _categorical_levels(frame: pd.DataFrame,
                        feature_names: Sequence[str]) -> dict[str, list[str]]:
    """Reading a CSV yields pandas StringDtype, not object, so test numeric-ness
    rather than comparing dtype against 'object'."""
    levels = {}
    for name in feature_names:
        if name in frame.columns and not pd.api.types.is_numeric_dtype(frame[name]):
            levels[name] = sorted(frame[name].astype("object").dropna().unique().tolist())
    return levels


def train(training_frame: pd.DataFrame | None = None,
          feature_names: Sequence[str] | None = None) -> GestunModel:
    """Fit on the labelled set. Class imbalance is handled with scale_pos_weight
    rather than resampling, so the training rows stay untouched."""
    if training_frame is None:
        training_frame = load_training_set()
    feature_names = list(feature_names or features.model_feature_names())
    missing = [f for f in feature_names if f not in training_frame.columns]
    if missing:
        raise ValueError(f"training set is missing {len(missing)} features: {missing[:5]}")

    y = training_frame["is_gestun"].astype(int)
    if y.nunique() < 2:
        raise ValueError("training set has only one class")
    categories = _categorical_levels(training_frame, feature_names)

    model = GestunModel(booster=None, feature_names=feature_names,  # type: ignore[arg-type]
                        categories=categories, trained_on=len(training_frame),
                        positives=int(y.sum()))
    X = model.prepare(training_frame)
    neg, pos = int((y == 0).sum()), int(y.sum())
    booster = XGBClassifier(scale_pos_weight=neg / pos, **config.MODEL_PARAMS.as_kwargs())
    booster.fit(X, y)
    model.booster = booster
    log.info("trained on %d companies (%d gestun, %d clean)", len(y), pos, neg)
    return model


def load_training_set() -> pd.DataFrame:
    path = config.TRAINING_SET_PATH
    if not path.exists():
        raise FileNotFoundError(f"training set not found: {path}")
    frame = pd.read_csv(path)
    if "is_gestun" not in frame.columns:
        raise ValueError(f"{path} has no is_gestun column")
    return frame
