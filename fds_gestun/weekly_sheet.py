"""Append a week's scored result to a Google Sheet, one block per run.

    python -m fds_gestun.weekly_sheet --csv oct15_p99_invoice_match.csv \
        --sheet 1cfn97JvfWtvbMralIG_dYFJwv6O5Cz6k34W7Z6HuPNU --tab p99_invoice_match

Append-only by design. Each run adds its rows below whatever is already there and
never rewrites a cell it did not write, because reviewers keep their own columns
to the right of the data and a task that rewrote rows would destroy that work.
A week already present is skipped rather than duplicated, so re-running after a
failure is safe.

`run_date` is the leading column and the divider: every row carries the date the
scoring ran, so the weeks stay separable after any sort or filter. A one-cell
label row is also written above each block (--no-divider-row turns it off). That
label row is easier to read and worse to filter -- a non-data row inside a table
is skipped by COUNTA but not by a filter view -- so turn it off if anyone builds
a pivot over this tab.

AUTH. Tries, in order:
  1. the service-account key at FDS_GCP_CREDENTIALS, if that variable is set
  2. application-default credentials
Both need the Sheets scope, which plain `gcloud auth application-default login`
does NOT grant. If ADC is missing it, this module says so and prints the command.
"""

from __future__ import annotations

import argparse
import logging
import os
import sys
from typing import Sequence

import pandas as pd

log = logging.getLogger(__name__)

SCOPES = ["https://www.googleapis.com/auth/spreadsheets"]
RUN_DATE = "run_date"
DIVIDER_FIRST_CELL = "--- run"

RELOGIN = (
    "gcloud auth application-default login --scopes="
    "https://www.googleapis.com/auth/spreadsheets,"
    "https://www.googleapis.com/auth/cloud-platform"
)

QUOTA_HELP = """\
User credentials must name a project for the Sheets API to bill, and naming one
needs serviceusage.services.use on it. As of 2026-10-28 pamela.huang@paper.id
holds bigquery.jobs.create on paper-prod but NOT serviceusage.services.use,
which is exactly why BigQuery works through ADC here and Sheets does not.

Two ways out, both needing someone with IAM rights on the project:

  1. Grant the role, then pass the project:
       roles/serviceusage.serviceUsageConsumer on paper-prod
       python -m fds_gestun.weekly_sheet ... --quota-project paper-prod

  2. Use a service account instead, which carries its own project and needs
     no quota project at all:
       - create a key for a service account that may use the Sheets API
       - share the spreadsheet with that service account as Editor
       - FDS_GCP_CREDENTIALS=/path/to/key.json python -m fds_gestun.weekly_sheet ...

On Composer this does not arise: the DAG authenticates as the environment's
service account, which is route 2."""


# --------------------------------------------------------------------------- auth

def sheets_api(quota_project: str | None = None):
    """A Sheets `spreadsheets()` resource, or SystemExit with what to fix.

    A service account is the path that works unattended: it carries its own
    project, so the Sheets API needs no quota project from the caller. User
    credentials (ADC) do need one, and attributing quota to a project requires
    serviceusage.services.use on it -- see QUOTA_HELP.
    """
    from googleapiclient.discovery import build

    key = os.environ.get("FDS_GCP_CREDENTIALS")
    if key and os.path.exists(key):
        from google.oauth2 import service_account
        try:
            creds = service_account.Credentials.from_service_account_file(
                key, scopes=SCOPES)
            log.info("Sheets: service-account key %s", key)
            return build("sheets", "v4", credentials=creds).spreadsheets()
        except Exception as exc:                      # revoked or malformed key
            log.warning("service-account key unusable (%s); falling back to ADC",
                        type(exc).__name__)

    import google.auth
    try:
        creds, _ = google.auth.default(scopes=SCOPES)
    except Exception as exc:
        raise SystemExit(f"no usable credentials: {exc}\n\nRun:\n  {RELOGIN}")
    quota_project = quota_project or os.environ.get("FDS_QUOTA_PROJECT")
    if quota_project and hasattr(creds, "with_quota_project"):
        creds = creds.with_quota_project(quota_project)
        log.info("Sheets: application-default credentials, quota project %s",
                 quota_project)
    else:
        log.info("Sheets: application-default credentials")
    return build("sheets", "v4", credentials=creds).spreadsheets()


def _explain(exc: Exception) -> str:
    """Turn the failures that actually happen into instructions.

    Order matters: a quota-project problem and a sharing problem both surface as
    403 PERMISSION_DENIED, and only the inner `reason` separates them. Checking
    403 first would send you off sharing a sheet that is already shared.
    """
    text = str(exc)
    if ("ACCESS_TOKEN_SCOPE_INSUFFICIENT" in text
            or "insufficient authentication scopes" in text):
        return ("Your credentials are valid but carry no Sheets scope.\n"
                f"Run this once, then retry:\n  {RELOGIN}")
    if "USER_PROJECT_DENIED" in text:
        return QUOTA_HELP
    if "SERVICE_DISABLED" in text:
        return ("The Sheets API is not enabled for the project your credentials "
                "bill to, and user credentials need one.\n" + QUOTA_HELP)
    if "PERMISSION_DENIED" in text or "403" in text:
        return ("Authenticated, but this account cannot open that spreadsheet.\n"
                "Share the sheet with the account you are authenticated as, "
                "as Editor.")
    if "404" in text or "not found" in text.lower():
        return "No spreadsheet with that id, or the account cannot see it."
    return text


# ----------------------------------------------------------------- row building

def build_block(frame: pd.DataFrame, run_date: str,
                columns: Sequence[str] | None = None,
                divider_row: bool = True) -> tuple[list[str], list[list]]:
    """(header, rows) for one week. `rows` includes the divider when asked for.

    Values are written as-is: this is data brought in from a scoring run, not a
    figure derived inside the sheet, so it is typed rather than a formula.
    NaN becomes "" because the API rejects NaN and a literal 'nan' string in a
    cell reads as data.
    """
    cols = list(columns or frame.columns)
    missing = [c for c in cols if c not in frame.columns]
    if missing:
        raise ValueError(f"csv is missing {len(missing)} columns: {missing}")

    header = [RUN_DATE] + cols
    body = frame[cols].astype(object).where(frame[cols].notna(), "")
    rows: list[list] = [[run_date] + list(r) for r in body.values.tolist()]

    if divider_row:
        window = ""
        for a, b in (("window_start", "window_end"),):
            if a in frame.columns and b in frame.columns and len(frame):
                window = f"  window {frame[a].iloc[0]} to {frame[b].iloc[0]}"
        label = f"{DIVIDER_FIRST_CELL} {run_date}{window}  ({len(rows)} rows)"
        rows = [[label] + [""] * len(cols)] + rows
    return header, rows


# ----------------------------------------------------------------------- append

def already_present(api, sheet_id: str, tab: str, run_date: str) -> bool:
    """Has this run_date been appended before? Column A holds it."""
    got = api.values().get(spreadsheetId=sheet_id,
                           range=f"{tab}!A:A").execute().get("values", [])
    seen = {r[0].strip() for r in got if r and r[0]}
    if run_date in seen:
        return True
    # the divider line carries the date too, so a half-written run still counts
    return any(s.startswith(f"{DIVIDER_FIRST_CELL} {run_date}") for s in seen)


def append_week(sheet_id: str, tab: str, frame: pd.DataFrame, run_date: str,
                columns: Sequence[str] | None = None,
                divider_row: bool = True, api=None,
                quota_project: str | None = None) -> int:
    """Append one week. Returns the number of data rows written, 0 if skipped."""
    api = api or sheets_api(quota_project)
    try:
        titles = [s["properties"]["title"] for s in api.get(
            spreadsheetId=sheet_id,
            fields="sheets.properties.title").execute()["sheets"]]
    except Exception as exc:
        raise SystemExit(_explain(exc))

    header, rows = build_block(frame, run_date, columns, divider_row)

    tab_id = None
    if tab not in titles:
        # Take the new sheetId from addSheet's own reply. Re-reading the
        # spreadsheet to find it costs a round trip and can race another writer.
        reply = api.batchUpdate(spreadsheetId=sheet_id, body={"requests": [
            {"addSheet": {"properties": {"title": tab}}}]}).execute()
        try:
            tab_id = reply["replies"][0]["addSheet"]["properties"]["sheetId"]
        except (KeyError, IndexError, TypeError):
            tab_id = None
        log.info("created tab %s", tab)
        col_a: list = []
    else:
        if already_present(api, sheet_id, tab, run_date):
            log.warning("run_date %s is already in %s; nothing written", run_date, tab)
            return 0
        col_a = api.values().get(spreadsheetId=sheet_id,
                                 range=f"{tab}!A:A").execute().get("values", [])

    if not col_a:
        # First write: header, then freeze it so it survives scrolling.
        api.values().update(
            spreadsheetId=sheet_id, range=f"{tab}!A1",
            valueInputOption="RAW", body={"values": [header]}).execute()
        sid = tab_id
        if sid is None:
            sid = {s["properties"]["title"]: s["properties"]["sheetId"]
                   for s in api.get(
                       spreadsheetId=sheet_id,
                       fields="sheets.properties").execute()["sheets"]}.get(tab)
        if sid is not None:
            api.batchUpdate(spreadsheetId=sheet_id, body={"requests": [
                {"updateSheetProperties": {
                    "properties": {"sheetId": sid,
                                   "gridProperties": {"frozenRowCount": 1}},
                    "fields": "gridProperties.frozenRowCount"}},
                {"repeatCell": {
                    "range": {"sheetId": sid, "startRowIndex": 0, "endRowIndex": 1},
                    "cell": {"userEnteredFormat": {"textFormat": {"bold": True}}},
                    "fields": "userEnteredFormat.textFormat.bold"}},
            ]}).execute()
        start = 2
    else:
        start = len(col_a) + 1

    # Write at an explicit range rather than values().append: append guesses the
    # table's extent and lands in the wrong place once a divider row has broken
    # the block up.
    api.values().update(
        spreadsheetId=sheet_id, range=f"{tab}!A{start}",
        valueInputOption="RAW", body={"values": rows}).execute()

    written = len(rows) - (1 if divider_row else 0)
    log.info("appended %d rows to %s!A%d (run_date %s)", written, tab, start, run_date)
    return written


# -------------------------------------------------------------------------- cli

def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(prog="fds-gestun-weekly-sheet",
                                description=__doc__.split("\n\n")[0])
    p.add_argument("--csv", required=True, help="the week's result CSV")
    p.add_argument("--sheet", required=True, help="spreadsheet id from its URL")
    p.add_argument("--tab", default="p99_invoice_match")
    p.add_argument("--run-date", default=None,
                   help="defaults to scored_date in the CSV, else today")
    p.add_argument("--quota-project", default=None,
                   help="project the Sheets API bills to when using ADC; "
                        "needs serviceusage.services.use on it")
    p.add_argument("--no-divider-row", action="store_true",
                   help="omit the label row above each block")
    p.add_argument("--dry-run", action="store_true",
                   help="build the block and print it; touch no sheet")
    p.add_argument("--export", metavar="PATH", default=None,
                   help="write the block to a CSV for pasting by hand instead "
                        "of calling the API; for when credentials are blocked")
    p.add_argument("-v", "--verbose", action="store_true")
    a = p.parse_args(argv)
    logging.basicConfig(level=logging.DEBUG if a.verbose else logging.INFO,
                        format="%(levelname)s %(message)s")

    frame = pd.read_csv(a.csv)
    run_date = a.run_date
    if run_date is None:
        run_date = (str(frame["scored_date"].iloc[0])
                    if "scored_date" in frame.columns and len(frame)
                    else pd.Timestamp.today().strftime("%Y-%m-%d"))

    if a.export:
        header, rows = build_block(frame, run_date,
                                   divider_row=not a.no_divider_row)
        # Header included only for a first-ever paste; say so rather than guess.
        pd.DataFrame(rows, columns=header).to_csv(a.export, index=False)
        print(f"wrote {a.export}: {len(rows)} rows, {len(header)} columns\n"
              f"run_date {run_date}\n\n"
              f"Paste into the sheet:\n"
              f"  empty tab      -> select A1, paste including the header row\n"
              f"  existing data  -> select column A of the first empty row, then\n"
              f"                    paste WITHOUT the header row\n"
              f"Sheets splits pasted CSV across columns on import; if it lands in\n"
              f"one column, use File > Import and choose Comma as the separator.")
        return 0

    if a.dry_run:
        header, rows = build_block(frame, run_date,
                                   divider_row=not a.no_divider_row)
        print(f"tab      : {a.tab}")
        print(f"run_date : {run_date}")
        print(f"columns  : {len(header)}  -> {header}")
        print(f"rows     : {len(rows)}")
        for r in rows[:3]:
            print("  ", [str(x)[:22] for x in r[:6]], "...")
        return 0

    n = append_week(a.sheet, a.tab, frame, run_date,
                    divider_row=not a.no_divider_row,
                    quota_project=a.quota_project)
    print(f"{'skipped (already present)' if n == 0 else f'wrote {n} rows'}"
          f" -- https://docs.google.com/spreadsheets/d/{a.sheet}/edit")
    return 0


if __name__ == "__main__":
    sys.exit(main())
