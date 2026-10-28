"""Command line entry points.

    fds-gestun train      [--training-set CSV] [--eval]
    fds-gestun score      --companies IDS.csv [--out OUT.csv] [--threshold 0.7]
                          [--min-tpv 10000000]
    fds-gestun features   --companies IDS.csv --out FEATURES.csv
    fds-gestun evaluate   [--thresholds]

Pipeline role : the `fds-gestun` command. Humans and CI enter here.
Deploy        : REQUIRED (the console script points at cli:main).
Change when   : you add a subcommand. Note the overlap guard in cmd_score --
                it stops a company being scored by a model trained on it.
"""
from __future__ import annotations
import argparse
import json
import logging
import sys
from pathlib import Path

import pandas as pd

from . import config, evaluate, features as feat, model as model_mod, rules as rules_mod

log = logging.getLogger("fds_gestun")


def _setup_logging(verbose: bool) -> None:
    logging.basicConfig(
        level=logging.DEBUG if verbose else logging.INFO,
        format="%(asctime)s %(levelname)-7s %(name)s: %(message)s",
        stream=sys.stderr)


def _read_company_ids(path: Path) -> list[str]:
    """Accept a CSV with a company_id column, or a bare one-per-line list."""
    if not path.exists():
        raise FileNotFoundError(f"company list not found: {path}")
    frame = pd.read_csv(path)
    if "company_id" in frame.columns:
        ids = frame["company_id"]
    elif frame.shape[1] == 1:
        ids = frame.iloc[:, 0]
    else:
        raise ValueError(f"{path} has no company_id column")
    ids = ids.dropna().astype(str).str.strip()
    ids = ids[ids != ""].drop_duplicates().tolist()
    if not ids:
        raise ValueError(f"{path} contains no company ids")
    return ids


def cmd_train(args: argparse.Namespace) -> int:
    frame = pd.read_csv(args.training_set) if args.training_set else None
    model = model_mod.train(frame)
    model.save()
    print(json.dumps({"trained_on": model.trained_on, "positives": model.positives,
                      "features": len(model.feature_names),
                      "model_path": str(config.MODEL_PATH)}, indent=2))
    if args.eval:
        print(json.dumps(evaluate.cross_validate(frame), indent=2))
    return 0


def cmd_features(args: argparse.Namespace) -> int:
    ids = _read_company_ids(args.companies)
    frame = feat.build_features(ids)
    frame.to_csv(args.out, index=False)
    print(f"wrote {args.out} ({frame.shape[0]} rows, {frame.shape[1]} columns)")
    return 0


def cmd_score(args: argparse.Namespace) -> int:
    model = model_mod.GestunModel.load()
    if args.features:
        frame = pd.read_csv(args.features)
    else:
        frame = feat.build_features(_read_company_ids(args.companies))
        if args.save_features:
            frame.to_csv(args.save_features, index=False)

    known = _known_labels()
    scored_ids = set(frame["company_id"])
    overlap = scored_ids & set(known)
    if overlap:
        log.warning("%d of %d companies are in the training set; scoring them would "
                    "return a fitted value, not a prediction. Reporting their label "
                    "instead.", len(overlap), len(scored_ids))
        frame = frame[~frame.company_id.isin(overlap)]

    result = model.score(frame, threshold=args.threshold) if len(frame) else pd.DataFrame()
    if overlap:
        labelled = pd.DataFrame({
            "company_id": sorted(overlap),
            "gestun_probability": [float(known[c]) for c in sorted(overlap)],
            "gestun_pct": [100.0 * known[c] for c in sorted(overlap)],
            "decision": ["GESTUN" if known[c] else "clean" for c in sorted(overlap)],
            "risk_band": "known label",
            "features_present": pd.NA, "features_total": len(model.feature_names)})
        result = pd.concat([result, labelled], ignore_index=True)

    # The rule layer reads the same feature matrix. It never changes a model
    # score; it adds a second reason to review a company the model scored clean.
    if len(frame):
        result = result.merge(rules_mod.apply_rules(frame), on="company_id", how="left")
    else:
        result["rule_flag"], result["rule_hits"] = False, ""
    result["rule_flag"] = result["rule_flag"].fillna(False)
    result["rule_hits"] = result["rule_hits"].fillna("")
    # The queue gate, not the model's opinion: see model.review_queue. There is
    # no scored window here, so the rupiah floor reads total_amount_last_7d --
    # which the feature query anchors on the company's LAST transaction, not on
    # a window. Close enough to rank a fresh batch; the DAG uses the real
    # window value instead. --min-tpv 0 turns the floor off.
    tpv = frame.set_index("company_id").get("total_amount_last_7d")
    result["tpv"] = (result.company_id.map(tpv) if tpv is not None else 0.0)
    result["review"] = model_mod.review_queue(
        result.gestun_probability, result.rule_flag, result.tpv,
        min_tpv=args.min_tpv)

    result.to_csv(args.out, index=False)
    flagged = int((result.decision == "GESTUN").sum())
    by_rule_only = int((result.rule_flag & (result.decision != "GESTUN")).sum())
    print(f"wrote {args.out}: {len(result)} companies, {flagged} flagged GESTUN "
          f"at threshold {args.threshold or config.DECISION_THRESHOLD}, "
          f"plus {by_rule_only} flagged by rules only, "
          f"{int(result.review.sum())} in the review queue "
          f"(p>={config.REVIEW_THRESHOLD} or rule, and tpv>="
          f"{args.min_tpv if args.min_tpv is not None else config.REVIEW_MIN_TPV:,.0f})"
          + (f" ({len(overlap)} carried their known label)" if overlap else ""))
    return 0


def cmd_evaluate(args: argparse.Namespace) -> int:
    print(json.dumps(evaluate.cross_validate(), indent=2))
    if args.thresholds:
        print()
        print(evaluate.threshold_table().to_string(index=False))
    return 0


def _known_labels() -> dict[str, int]:
    if not config.TRAINING_SET_PATH.exists():
        return {}
    frame = pd.read_csv(config.TRAINING_SET_PATH, usecols=["company_id", "is_gestun"])
    return dict(zip(frame.company_id, frame.is_gestun.astype(int)))


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="fds-gestun",
                                     description="Gestun scoring for paper.id")
    parser.add_argument("-v", "--verbose", action="store_true")
    sub = parser.add_subparsers(dest="command", required=True)

    p = sub.add_parser("train", help="fit and persist the model")
    p.add_argument("--training-set", type=Path)
    p.add_argument("--eval", action="store_true", help="also print CV metrics")
    p.set_defaults(func=cmd_train)

    p = sub.add_parser("features", help="build the feature matrix only")
    p.add_argument("--companies", type=Path, required=True)
    p.add_argument("--out", type=Path, required=True)
    p.set_defaults(func=cmd_features)

    p = sub.add_parser("score", help="score companies")
    src = p.add_mutually_exclusive_group(required=True)
    src.add_argument("--companies", type=Path, help="CSV of company_id to build and score")
    src.add_argument("--features", type=Path, help="pre-built feature CSV")
    p.add_argument("--out", type=Path, required=True)
    p.add_argument("--save-features", type=Path, help="cache the built features here")
    p.add_argument("--threshold", type=float, default=None)
    p.add_argument("--min-tpv", type=float, default=None,
                   help="rupiah floor for the review queue (default "
                        "config.REVIEW_MIN_TPV; 0 disables it)")
    p.set_defaults(func=cmd_score)

    p = sub.add_parser("evaluate", help="cross-validated metrics")
    p.add_argument("--thresholds", action="store_true")
    p.set_defaults(func=cmd_evaluate)
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    _setup_logging(args.verbose)
    try:
        return args.func(args)
    except (FileNotFoundError, ValueError) as exc:
        log.error("%s", exc)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
