"""Unit tests. No BigQuery: everything here runs on synthetic frames."""
import numpy as np
import pandas as pd
import pytest

from fds_gestun import config, model as model_mod
from fds_gestun.model import GestunModel, risk_band


FEATURES = ["num_a", "num_b", "cat_a"]


def make_frame(n=120, seed=0):
    rng = np.random.default_rng(seed)
    y = (rng.random(n) < 0.35).astype(int)
    return pd.DataFrame({
        "company_id": [f"co-{i:03d}" for i in range(n)],
        "is_gestun": y,
        # signal, so the fitted model is not degenerate
        "num_a": y * 3.0 + rng.normal(0, 1, n),
        "num_b": rng.normal(0, 1, n),
        "cat_a": np.where(y == 1, "alpha", "beta"),
    })


def test_risk_bands_cover_the_range():
    assert risk_band(0.95) == "very high"
    assert risk_band(0.75) == "high"
    assert risk_band(0.55) == "elevated"
    assert risk_band(0.35) == "borderline"
    assert risk_band(0.01) == "low"


def test_train_and_score_roundtrip(tmp_path):
    frame = make_frame()
    model = model_mod.train(frame, feature_names=FEATURES)
    assert model.positives == int(frame.is_gestun.sum())
    assert model.categories["cat_a"] == ["alpha", "beta"]

    scored = model.score(frame)
    assert len(scored) == len(frame)
    assert scored.gestun_probability.between(0, 1).all()
    # sorted descending
    assert scored.gestun_probability.is_monotonic_decreasing

    model_path, meta_path = tmp_path / "m.json", tmp_path / "m_meta.json"
    model.save(model_path, meta_path)
    reloaded = GestunModel.load(model_path, meta_path)
    assert reloaded.feature_names == model.feature_names
    np.testing.assert_allclose(reloaded.predict_proba(frame),
                               model.predict_proba(frame), rtol=1e-6)


def test_prepare_fills_missing_columns_with_nan():
    frame = make_frame()
    model = model_mod.train(frame, feature_names=FEATURES)
    partial = frame.drop(columns=["num_b"])
    prepared = model.prepare(partial)
    assert list(prepared.columns) == FEATURES        # order preserved
    assert prepared["num_b"].isna().all()


def test_unseen_category_becomes_nan_not_a_new_level():
    """A category the model never saw carries no information. It must not be
    invented as a level -- that produced a spurious +4.13 contribution once."""
    frame = make_frame()
    model = model_mod.train(frame, feature_names=FEATURES)
    novel = frame.head(3).copy()
    novel["cat_a"] = "never-seen"
    assert model.prepare(novel)["cat_a"].isna().all()


def test_train_rejects_single_class():
    frame = make_frame()
    frame["is_gestun"] = 0
    with pytest.raises(ValueError, match="one class"):
        model_mod.train(frame, feature_names=FEATURES)


def test_train_rejects_missing_features():
    frame = make_frame().drop(columns=["num_a"])
    with pytest.raises(ValueError, match="missing"):
        model_mod.train(frame, feature_names=FEATURES)


def test_load_without_artifact_is_a_clear_error(tmp_path):
    with pytest.raises(FileNotFoundError, match="train"):
        GestunModel.load(tmp_path / "nope.json", tmp_path / "nope_meta.json")


def test_prepare_coerces_string_columns_to_numeric():
    """A feature source that returns no rows yields all-NaN string columns.
    XGBoost rejects those at predict time unless prepare() coerces them."""
    frame = make_frame()
    model = model_mod.train(frame, feature_names=FEATURES)
    broken = frame.copy()
    broken["num_b"] = pd.Series([None] * len(broken), dtype="str")
    prepared = model.prepare(broken)
    assert pd.api.types.is_numeric_dtype(prepared["num_b"])
    assert model.predict_proba(broken).shape == (len(broken),)


def test_prepare_dtypes_match_between_train_and_score():
    frame = make_frame()
    model = model_mod.train(frame, feature_names=FEATURES)
    train_dtypes = model.prepare(frame).dtypes
    scored = model.prepare(frame.drop(columns=["num_a", "cat_a"]))
    for name in FEATURES:
        assert scored[name].dtype == train_dtypes[name], name
