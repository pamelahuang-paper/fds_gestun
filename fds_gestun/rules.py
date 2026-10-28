"""Deterministic rules that run beside the model.

Why rules at all: the model is trained on 582 labels and learns what the
*average* gestun company looks like. Three companies confirmed by review in
September were scored clean by it (0.27, 0.63, 0.67) and stayed clean after two
rounds of new features - their patterns are rare enough that 582 labels cannot
teach them. A rule does not need a base rate, so it catches them today; the
model keeps catching the volume.

Measured on the 582 labelled companies: 72% of the companies these rules flag
are gestun, 8 clean companies are flagged. On the 10-16 Sep window they add 157
companies to the model's 1,835.

Pipeline role : a second opinion on the same feature matrix. Never overrides the
                model score; it only adds a flag and the reason.
Deploy        : REQUIRED if the scoring output is to carry rule_flag.
Change when   : review finds a pattern the model keeps missing. Re-measure
                precision on the labelled set before shipping a new rule.
"""
from __future__ import annotations
from dataclasses import dataclass
from typing import Callable

import pandas as pd


@dataclass(frozen=True)
class Rule:
    code: str
    description: str
    test: Callable[[pd.DataFrame], pd.Series]


def _col(frame: pd.DataFrame, name: str) -> pd.Series:
    """A missing column reads as all-NaN, so a rule never raises on a frame
    built before its features existed - it just never fires."""
    if name in frame.columns:
        return pd.to_numeric(frame[name], errors="coerce")
    return pd.Series([float("nan")] * len(frame), index=frame.index)


RULES: tuple[Rule, ...] = (
    Rule(
        "R1", "payout terpusat: >=85% nilai Out ke satu perorangan, 2-3 partner, "
              "rata-rata transaksi >=10 juta",
        # n_out_partners >= 2 is load-bearing, not cosmetic. With a single Out
        # partner, top1_out_partner_amount_share is 1.0 by arithmetic and
        # n_out_partners <= 3 is free -- three of the five conditions are
        # satisfied by having one counterparty, not by concentrating on it. The
        # first version omitted it and fired on 369 companies in the 17-23 Sep
        # window, 220 of them single-partner; with the floor it fires on 149 and
        # out-of-fold precision on the labelled set goes 0.77 -> 1.00 (on 4
        # hits, so read that as "no longer obviously wrong", not as proof).
        lambda f: (_col(f, "top1_out_partner_amount_share") >= 0.85)
                  & (_col(f, "top1_out_partner_is_personal") == 1)
                  & (_col(f, "n_out_partners") >= 2)
                  & (_col(f, "n_out_partners") <= 3)
                  & (_col(f, "pct_partner_personal_name") >= 0.5)
                  & (_col(f, "avg_txn_amount") >= 10_000_000)),
    Rule(
        "R2", "pemilik mendanai sendiri: >=30% nilai In dari partner bernama "
              "pemilik, dan >=50% nilai lewat kartu kredit",
        lambda f: (_col(f, "pct_amount_in_partner_eq_self") >= 0.30)
                  & (_col(f, "cc_amount_share") >= 0.5)),
    Rule(
        "R3", "uji kartu: >=3 kartu berbeda dipakai pada satu transaksi, pada "
              ">=50% transaksi berkartu",
        lambda f: (_col(f, "max_cards_in_one_txn") >= 3)
                  & (_col(f, "pct_txn_multi_card") >= 0.5)),
)


def apply_rules(frame: pd.DataFrame) -> pd.DataFrame:
    """company_id, rule_flag, rule_hits ('R1|R3', empty string when none).

    NaN is not a hit: a company with no disbursement history must not be
    flagged by a rule that cannot be evaluated for it.
    """
    hits = {rule.code: rule.test(frame).fillna(False).astype(bool) for rule in RULES}
    matrix = pd.DataFrame(hits, index=frame.index)
    return pd.DataFrame({
        "company_id": frame["company_id"].values,
        "rule_flag": matrix.any(axis=1).values,
        "rule_hits": matrix.apply(
            lambda row: "|".join(c for c in matrix.columns if row[c]), axis=1).values,
    })
