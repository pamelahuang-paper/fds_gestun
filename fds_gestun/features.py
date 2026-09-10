"""Build the company-level feature matrix for an arbitrary list of companies.

Every query lives in sql/ and takes @company_ids, so the same code path serves
training-set refreshes and production scoring.

Pipeline role : company ids in, 184-column feature matrix out. The slow step:
                one BigQuery job per source, ~10 min per 1k companies.
Deploy        : REQUIRED.
Change when   : you add a feature. Add the .sql to sql/, register it in
                SIMPLE_SOURCES, and add a row to fds_gestun_features_179.csv.
"""
from __future__ import annotations
import logging
from typing import Iterable, Sequence

import numpy as np
import pandas as pd

from . import bq, config

log = logging.getLogger(__name__)

# name -> sql file, for the sources that need nothing but @company_ids
SIMPLE_SOURCES = (
    ("invoice_text", "invoice_text.sql"),
    ("payment_method", "payment_method.sql"),
    ("velocity", "velocity.sql"),
    ("partner", "partner.sql"),
    ("partner_name", "partner_name.sql"),
    ("partner_ratio", "partner_ratio.sql"),
    ("disbursement", "disbursement.sql"),
    ("payout_selfdealing", "payout_selfdealing.sql"),
    ("fingerprint", "fingerprint.sql"),
    ("ptcv_partner", "ptcv_partner.sql"),
)


def _dedupe(ids: Iterable[str]) -> list[str]:
    return list(dict.fromkeys(ids))


def build_peer_vocabulary(company_ids: Sequence[str],
                          pool_ids: Sequence[str]) -> pd.DataFrame:
    """Share of a company's invoice tokens that OTHER companies in the same
    business type also use.

    The peer pool must be wider than the companies being scored, or they become
    each other's only peers and the feature measures nothing. Leave-one-out is
    vectorised: count companies per (category, token), then subtract this
    company's own contribution.
    """
    tokens = bq.run_query(bq.load_sql("peer_vocabulary.sql"),
                          pool_ids=_dedupe(list(pool_ids) + list(company_ids)))
    if tokens.empty:
        return pd.DataFrame({"company_id": []})

    def score(level: str) -> dict[str, tuple[int, float]]:
        t = tokens[tokens[level].notna()][[level, "company_id", "w", "n"]]
        users = (t.drop_duplicates([level, "w", "company_id"])
                   .groupby([level, "w"]).size().rename("cos").reset_index())
        peers_in_cat = t.drop_duplicates([level, "company_id"]).groupby(level).size()
        merged = t.merge(users, on=[level, "w"], how="left")
        merged["hit"] = merged.n * ((merged.cos - 1) > 0)   # -1 excludes self
        agg = merged.groupby("company_id")[["hit", "n"]].sum()
        rate = agg.hit / agg.n
        cat_of = t.drop_duplicates("company_id").set_index("company_id")[level]
        return {cid: (int(peers_in_cat.get(cat_of.get(cid), 1)) - 1,
                      float(rate.get(cid, np.nan))) for cid in rate.index}

    child, parent = score("biz_child"), score("biz_parent")
    out = tokens.groupby("company_id").agg(n_tokens=("n", "sum")).reset_index()
    out["n_peers_child"] = out.company_id.map(lambda c: child.get(c, (0, np.nan))[0])
    out["peer_vocab_match_rate_child"] = out.company_id.map(
        lambda c: child.get(c, (0, np.nan))[1])
    out["n_peers_parent"] = out.company_id.map(lambda c: parent.get(c, (0, np.nan))[0])
    out["peer_vocab_match_rate_parent"] = out.company_id.map(
        lambda c: parent.get(c, (0, np.nan))[1])
    out["peer_vocab_match_rate"] = np.where(out.n_peers_child >= 3,
                                            out.peer_vocab_match_rate_child,
                                            out.peer_vocab_match_rate_parent)
    out["peer_vocab_level"] = np.where(out.n_peers_child >= 3, "child", "parent")
    return out[out.company_id.isin(set(company_ids))]


def build_upstream_fds(company_ids: Sequence[str]) -> pd.DataFrame:
    """Upstream FDS columns, transaction grain collapsed to company grain."""
    raw = bq.run_query(bq.load_sql("upstream_fds.sql"), company_ids=company_ids)
    if raw.empty:
        return pd.DataFrame({"company_id": []})
    meta = {"company_id", "order_id", "external_id", "invoice_id", "mlfds_label"}
    feature_cols = [c for c in raw.columns if c not in meta]
    # mlfds_label is a STRING here and is a *different* fraud label; it is excluded
    # from the model but must not break the aggregate.
    raw["mlfds_label"] = pd.to_numeric(raw["mlfds_label"], errors="coerce")
    numeric = [c for c in feature_cols if pd.api.types.is_numeric_dtype(raw[c])]
    categorical = [c for c in feature_cols if c not in numeric]
    grouped = raw.groupby("company_id")
    return pd.concat([
        grouped.agg(mlfds_n_txns=("order_id", "nunique"),
                    mlfds_label_rate=("mlfds_label", "mean")),
        grouped[numeric].median(),
        grouped[categorical].agg(
            lambda s: s.mode().iloc[0] if not s.mode().empty else np.nan),
    ], axis=1).reset_index()


def build_features(company_ids: Sequence[str],
                   peer_pool: Sequence[str] | None = None) -> pd.DataFrame:
    """One row per company, every feature source joined.

    peer_pool defaults to the labelled training set; pass a wider pool if you
    have one. Companies with no data in a source get NaN, which XGBoost routes
    natively -- do not impute, the missingness is informative.
    """
    ids = _dedupe(company_ids)
    if not ids:
        raise ValueError("company_ids is empty")
    log.info("building features for %d companies", len(ids))

    if peer_pool is None:
        peer_pool = _default_peer_pool()

    frames = []
    for name, sql_file in SIMPLE_SOURCES:
        df = bq.run_query(bq.load_sql(sql_file), company_ids=ids)
        log.info("  %-20s %s", name, df.shape)
        frames.append(df)

    peer = build_peer_vocabulary(ids, peer_pool)
    log.info("  %-20s %s", "peer_vocabulary", peer.shape)
    frames.append(peer)

    upstream = build_upstream_fds(ids)
    log.info("  %-20s %s", "upstream_fds", upstream.shape)
    frames.append(upstream)

    out = pd.DataFrame({"company_id": ids})
    for frame in frames:
        if frame.empty:
            continue
        frame = frame.drop(columns=[c for c in ("is_gestun",) if c in frame.columns])
        out = out.merge(frame, on="company_id", how="left")
    log.info("feature matrix %s", out.shape)
    return out


def _default_peer_pool() -> list[str]:
    if not config.TRAINING_SET_PATH.exists():
        log.warning("training set not found at %s; peer pool is the scored batch only",
                    config.TRAINING_SET_PATH)
        return []
    return pd.read_csv(config.TRAINING_SET_PATH, usecols=["company_id"]).company_id.tolist()


def model_feature_names() -> list[str]:
    """The features the model is allowed to see: everything in the dictionary
    except identifiers, the label, label-derived leaks and pipeline artifacts."""
    dictionary = pd.read_csv(config.FEATURE_DICT_PATH)
    excluded = set(config.LEAKY_FEATURES) | set(config.PIPELINE_ARTIFACTS) | {
        "company_id", "is_gestun"}
    base = [f for f in dictionary.feature if f not in excluded]
    return base + [f for f in config.PTCV_FEATURES if f not in base]
