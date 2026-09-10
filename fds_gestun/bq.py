"""BigQuery access. One client, parameterised queries, no string interpolation."""
from __future__ import annotations
import logging
from functools import lru_cache
from typing import Sequence

import pandas as pd
from google.cloud import bigquery

from . import config

log = logging.getLogger(__name__)


@lru_cache(maxsize=1)
def get_client() -> bigquery.Client:
    """Cached BigQuery client. Uses application-default credentials unless
    FDS_GCP_CREDENTIALS points at a service-account key file."""
    if config.CREDENTIALS_PATH:
        from google.oauth2 import service_account
        creds = service_account.Credentials.from_service_account_file(
            config.CREDENTIALS_PATH)
        log.info("BigQuery: service-account credentials from %s", config.CREDENTIALS_PATH)
    else:
        creds = None
        log.info("BigQuery: application-default credentials")
    return bigquery.Client(credentials=creds, project=config.GCP_PROJECT,
                           location=config.BQ_LOCATION)


def _coerce_numeric(df: pd.DataFrame) -> pd.DataFrame:
    """BigQuery NUMERIC and division results arrive as decimal.Decimal in object
    columns and silently break numpy downstream. Coerce columns that are fully
    numeric; leave genuine string columns alone."""
    for col in df.columns:
        if df[col].dtype != "object":
            continue
        converted = pd.to_numeric(df[col], errors="coerce")
        if converted.notna().any() and converted.notna().sum() == df[col].notna().sum():
            df[col] = converted.astype(float)
    return df


def run_query(sql: str, *, company_ids: Sequence[str] | None = None,
              pool_ids: Sequence[str] | None = None) -> pd.DataFrame:
    """Run a query with array parameters and return a numeric-coerced DataFrame."""
    params = []
    if company_ids is not None:
        params.append(bigquery.ArrayQueryParameter("company_ids", "STRING",
                                                   list(company_ids)))
    if pool_ids is not None:
        params.append(bigquery.ArrayQueryParameter("pool_ids", "STRING",
                                                   list(pool_ids)))
    job_config = bigquery.QueryJobConfig(
        query_parameters=params,
        maximum_bytes_billed=config.BQ_MAX_BYTES_BILLED,
    )
    job = get_client().query(sql, job_config=job_config)
    df = job.result(timeout=config.BQ_TIMEOUT_SECONDS).to_dataframe()
    log.debug("query returned %s rows, billed %s bytes", len(df),
              job.total_bytes_billed)
    return _coerce_numeric(df)


def load_sql(name: str) -> str:
    """Read a query template from the sql/ directory."""
    path = config.SQL_DIR / name
    if not path.exists():
        raise FileNotFoundError(f"no such query: {path}")
    return path.read_text()
