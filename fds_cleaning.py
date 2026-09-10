"""
FDS data-cleaning helpers.

Written against the specific problems in the FDS pipeline rather than as generic
boilerplate. The three that matter most:

  1. INVERTED NULL-FILL. `get_data()` in the production notebooks fills categorical
     and date columns with -1 but fills NUMERIC columns with the *string* 'None'.
     That forces numeric features to object dtype, which is why the downstream code
     is full of `clean_float_column`, `_clean_numeric_for_model`, and bare
     `try/except ... astype(float)` blocks. `fill_missing()` below does it the right
     way round.

  2. STRING NULLS. 'None', 'nan', '', '-', 'N/A' arrive as text and survive
     `pd.to_numeric` only if you coerce. `normalise_string_nulls()` handles them.

  3. inf FROM RATIOS. `amount_to_invoice_amount` is inf whenever invoice_amount is 0
     or missing. Production drops those rows entirely, which silently removes
     invoice-less transactions from scoring. `handle_inf()` lets you choose.

Usage:
    from fds_cleaning import profile, clean, compare

    rep_before = profile(df)
    df_clean, log = clean(df, id_cols=['external_id', 'company_id'])
    compare(df, df_clean)
"""

from __future__ import annotations

import numpy as np
import pandas as pd

# Values that mean "missing" but arrive as text.
STRING_NULLS = {
    "None", "none", "NONE", "NaN", "nan", "NAN", "NULL", "null", "Null",
    "", " ", "-", "--", "N/A", "n/a", "NA", "#N/A", "?", "nil",
}


# --------------------------------------------------------------------------
# Profiling
# --------------------------------------------------------------------------
def profile(df: pd.DataFrame, top_n_values: int = 3) -> pd.DataFrame:
    """Per-column quality report. Run before and after cleaning."""
    rows = []
    n = len(df)
    for c in df.columns:
        s = df[c]
        num = pd.to_numeric(s, errors="coerce")
        n_str_null = int(s.isin(STRING_NULLS).sum()) if s.dtype == object else 0
        vc = s.value_counts(dropna=True)
        rows.append({
            "column": c,
            "dtype": str(s.dtype),
            "n_missing": int(s.isna().sum()),
            "pct_missing": round(s.isna().mean() * 100, 2),
            "n_string_null": n_str_null,
            "n_inf": int(np.isinf(num).sum()),
            "n_unique": int(s.nunique(dropna=True)),
            "is_constant": s.nunique(dropna=False) <= 1,
            "numeric_parseable_pct": round(num.notna().mean() * 100, 2),
            "top_values": ", ".join(map(str, vc.head(top_n_values).index.tolist())),
        })
    return pd.DataFrame(rows).sort_values("pct_missing", ascending=False).reset_index(drop=True)


def detect_types(df: pd.DataFrame, id_cols=(), numeric_threshold: float = 0.95):
    """
    Split columns into numeric / categorical / datetime / id.

    A column counts as numeric if >= `numeric_threshold` of its non-null values
    parse as numbers — this catches float columns polluted by the string 'None'.
    """
    id_cols = set(id_cols)
    numeric, categorical, datetime_cols = [], [], []

    for c in df.columns:
        if c in id_cols:
            continue
        s = df[c]
        if pd.api.types.is_datetime64_any_dtype(s):
            datetime_cols.append(c)
            continue
        if pd.api.types.is_bool_dtype(s):
            categorical.append(c)
            continue

        non_null = s[~s.isin(STRING_NULLS)] if s.dtype == object else s
        non_null = non_null.dropna()
        if len(non_null) == 0:
            categorical.append(c)
            continue

        parsed = pd.to_numeric(non_null, errors="coerce")
        if parsed.notna().mean() >= numeric_threshold:
            numeric.append(c)
        else:
            categorical.append(c)

    return {
        "numeric": numeric,
        "categorical": categorical,
        "datetime": datetime_cols,
        "id": sorted(id_cols & set(df.columns)),
    }


# --------------------------------------------------------------------------
# Individual cleaning steps
# --------------------------------------------------------------------------
def drop_unnamed(df: pd.DataFrame) -> pd.DataFrame:
    """Remove the 'Unnamed: 0' columns that to_csv/read_csv round-trips create."""
    bad = [c for c in df.columns if str(c).startswith("Unnamed")]
    return df.drop(columns=bad) if bad else df


def normalise_string_nulls(df: pd.DataFrame, cols=None) -> pd.DataFrame:
    """Turn textual nulls ('None', '', '-', 'N/A', ...) into real NaN."""
    df = df.copy()
    cols = cols if cols is not None else df.columns
    for c in cols:
        if c in df.columns and df[c].dtype == object:
            df[c] = df[c].replace(list(STRING_NULLS), np.nan)
    return df


def coerce_numeric(df: pd.DataFrame, cols) -> pd.DataFrame:
    """Force columns to float, turning unparseable values into NaN."""
    df = df.copy()
    for c in cols:
        if c in df.columns:
            df[c] = pd.to_numeric(df[c], errors="coerce")
    return df


def handle_inf(df: pd.DataFrame, cols=None, strategy: str = "nan", cap_quantile: float = 0.99):
    """
    Deal with +/-inf, which ratio features produce on divide-by-zero.

    strategy:
      'nan'  -> replace with NaN and let imputation handle it  (default, recommended)
      'cap'  -> clip to the column's `cap_quantile` finite value
      'zero' -> replace with 0
      'drop' -> drop the offending ROWS  (what production does - it silently
                removes invoice-less transactions; use knowingly)
    """
    df = df.copy()
    cols = cols if cols is not None else df.select_dtypes(include=[np.number]).columns
    n_inf = int(np.isinf(df[cols].to_numpy(dtype="float64", na_value=np.nan)).sum())

    if strategy == "drop":
        mask = np.isinf(df[cols].to_numpy(dtype="float64", na_value=np.nan)).any(axis=1)
        return df.loc[~mask].copy(), {"strategy": "drop", "n_inf": n_inf,
                                      "rows_dropped": int(mask.sum())}

    for c in cols:
        col = df[c].replace([np.inf, -np.inf], np.nan)
        if strategy == "cap":
            hi = col.quantile(cap_quantile)
            df[c] = df[c].replace([np.inf], hi).replace([-np.inf], -abs(hi))
        elif strategy == "zero":
            df[c] = col.fillna(0) if df[c].isin([np.inf, -np.inf]).any() else col
        else:  # 'nan'
            df[c] = col
    return df, {"strategy": strategy, "n_inf": n_inf, "rows_dropped": 0}


def fill_missing(df: pd.DataFrame, numeric_cols=(), categorical_cols=(),
                 numeric_fill="median", categorical_fill=-1) -> pd.DataFrame:
    """
    Impute, the right way round.

    Production does the inverse of this - categorical/date get -1 while NUMERIC
    columns get the string 'None', which is what breaks the dtypes.

    numeric_fill: 'median' | 'mean' | 'zero' | a number
    """
    df = df.copy()
    for c in numeric_cols:
        if c not in df.columns:
            continue
        s = pd.to_numeric(df[c], errors="coerce")
        if numeric_fill == "median":
            v = s.median()
        elif numeric_fill == "mean":
            v = s.mean()
        elif numeric_fill == "zero":
            v = 0
        else:
            v = numeric_fill
        df[c] = s.fillna(0 if pd.isna(v) else v).astype(float)

    for c in categorical_cols:
        if c in df.columns:
            df[c] = df[c].fillna(categorical_fill)
    return df


def dedupe_transactions(df: pd.DataFrame, subset=None, keep="first"):
    """
    Drop duplicate transaction rows.

    order_id / external_id is NOT unique in the payments source (bulk payments
    produce several rows per order), which is why the production notebooks dedupe
    on the composite key below rather than on external_id alone.
    """
    default = ["external_id", "invoice_id", "trx_source_digpay_type"]
    subset = subset or [c for c in default if c in df.columns]
    if not subset:
        return df.drop_duplicates(keep=keep).reset_index(drop=True), {"subset": None}
    before = len(df)
    out = df.drop_duplicates(subset=subset, keep=keep).reset_index(drop=True)
    return out, {"subset": subset, "rows_dropped": before - len(out)}


def drop_constant(df: pd.DataFrame, exclude=()) -> tuple[pd.DataFrame, list]:
    """Remove columns with a single value - they carry no information."""
    exclude = set(exclude)
    const = [c for c in df.columns
             if c not in exclude and df[c].nunique(dropna=False) <= 1]
    return df.drop(columns=const), const


def cap_outliers(df: pd.DataFrame, cols, lower: float = 0.01, upper: float = 0.99) -> pd.DataFrame:
    """Winsorise heavy tails. Amount columns in payments data are extremely skewed."""
    df = df.copy()
    for c in cols:
        if c in df.columns and pd.api.types.is_numeric_dtype(df[c]):
            lo, hi = df[c].quantile(lower), df[c].quantile(upper)
            df[c] = df[c].clip(lo, hi)
    return df


# --------------------------------------------------------------------------
# Orchestration
# --------------------------------------------------------------------------
def clean(df: pd.DataFrame,
          id_cols=("external_id", "company_id", "order_id", "invoice_id", "partner_id"),
          inf_strategy: str = "nan",
          numeric_fill="median",
          categorical_fill=-1,
          dedupe: bool = True,
          drop_constants: bool = True,
          winsorise: bool = False):
    """
    Full cleaning pass. Returns (clean_df, log_dict).

    Order matters: string-nulls must be normalised before type detection, or
    columns polluted with 'None' get misclassified as categorical.
    """
    log = {"rows_in": len(df), "cols_in": df.shape[1]}
    out = drop_unnamed(df)

    # 1. textual nulls -> NaN  (must precede type detection)
    out = normalise_string_nulls(out)

    # 2. classify
    types = detect_types(out, id_cols=id_cols)
    log["types"] = {k: len(v) for k, v in types.items()}

    # 3. numeric coercion
    out = coerce_numeric(out, types["numeric"])

    # 4. inf
    out, inf_log = handle_inf(out, types["numeric"], strategy=inf_strategy)
    log["inf"] = inf_log

    # 5. dedupe
    if dedupe:
        out, dd = dedupe_transactions(out)
        log["dedupe"] = dd

    # 6. impute - numeric numerically, categorical with a sentinel
    out = fill_missing(out,
                       numeric_cols=types["numeric"],
                       categorical_cols=types["categorical"],
                       numeric_fill=numeric_fill,
                       categorical_fill=categorical_fill)

    # 7. optional winsorising
    if winsorise:
        out = cap_outliers(out, types["numeric"])

    # 8. constants
    if drop_constants:
        out, const = drop_constant(out, exclude=id_cols)
        log["constant_dropped"] = const

    log["rows_out"] = len(out)
    log["cols_out"] = out.shape[1]
    return out, log


def compare(before: pd.DataFrame, after: pd.DataFrame) -> pd.DataFrame:
    """Side-by-side before/after summary."""
    def stats(d):
        num = d.select_dtypes(include=[np.number])
        return {
            "rows": len(d),
            "cols": d.shape[1],
            "object_cols": int((d.dtypes == object).sum()),
            "numeric_cols": num.shape[1],
            "total_missing": int(d.isna().sum().sum()),
            "cols_with_missing": int((d.isna().sum() > 0).sum()),
            "n_inf": int(np.isinf(num.to_numpy(dtype="float64", na_value=np.nan)).sum())
                     if num.shape[1] else 0,
        }
    b, a = stats(before), stats(after)
    return pd.DataFrame({"before": b, "after": a,
                         "delta": {k: a[k] - b[k] for k in b}})
