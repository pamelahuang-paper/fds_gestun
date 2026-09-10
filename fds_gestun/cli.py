"""Command line entry points.

    fds-gestun train      [--training-set CSV] [--eval]
    fds-gestun score      --companies IDS.csv [--out OUT.csv] [--threshold 0.7]
    fds-gestun features   --companies IDS.csv --out FEATURES.csv
    fds-gestun evaluate   [--thresholds]
"""
from __future__ import annotations
import argparse
import json
import logging
import sys
from pathlib import Path

import pandas as pd

from . import config, evaluate, features as feat, model as model_mod

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

    result.to_csv(args.out, index=False)
    flagged = int((result.decision == "GESTUN").sum())
    print(f"wrote {args.out}: {len(result)} companies, {flagged} flagged GESTUN "
          f"at threshold {args.threshold or config.DECISION_THRESHOLD}"
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
