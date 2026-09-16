"""The DAG must import cleanly, or the scheduler silently drops it."""
import pytest

airflow = pytest.importorskip("airflow", reason="airflow not installed on this runner")


@pytest.fixture(scope="module")
def dagbag():
    from airflow.models.dagbag import DagBag
    return DagBag(dag_folder="dags")


def test_dag_imports_without_errors(dagbag):
    assert not dagbag.import_errors, dagbag.import_errors


def test_dag_is_registered(dagbag):
    assert "fds_gestun_scoring" in dagbag.dags


def test_task_graph_is_linear_and_complete(dagbag):
    dag = dagbag.dags["fds_gestun_scoring"]
    assert {t.task_id for t in dag.tasks} == {
        "assert_source_is_fresh", "select_candidates", "build_features",
        "score", "publish"}
    upstream = {t.task_id: sorted(t.upstream_task_ids) for t in dag.tasks}
    assert upstream["assert_source_is_fresh"] == []
    assert upstream["select_candidates"] == ["assert_source_is_fresh"]
    assert upstream["build_features"] == ["select_candidates"]
    assert upstream["score"] == ["build_features"]
    assert upstream["publish"] == ["score"]


def test_backfill_is_off(dagbag):
    """Backfilling a fraud queue would replay months of alerts at once."""
    dag = dagbag.dags["fds_gestun_scoring"]
    assert dag.catchup is False
    assert dag.max_active_runs == 1


def test_threshold_default_is_the_review_queue_setting(dagbag):
    """0.5 is the library default; the queue runs at 0.7 for precision."""
    dag = dagbag.dags["fds_gestun_scoring"]
    # Airflow 3 resolves dag.params[...] to the value, not the Param object.
    assert dag.params.dump()["threshold"] == 0.7


def test_freshness_gate_runs_before_any_work(dagbag):
    """The mart rebuilds once a day and a given day is only complete after the
    NEXT day's rebuild. Scoring before that silently uses a fraction of the week,
    which is worse than failing."""
    dag = dagbag.dags["fds_gestun_scoring"]
    gate = dag.get_task("assert_source_is_fresh")
    assert gate.upstream_task_ids == set(), "the gate must run first"
    assert "select_candidates" in gate.downstream_task_ids


def test_schedule_runs_after_the_daily_source_load():
    """The daily load finishes ~05:15 WIB and completes the previous day.
    Observed range 2026-09-03..16 was 04:25-06:38, so the run needs headroom
    past the latest, not the median."""
    import re
    from pathlib import Path
    source = Path("dags/fds_gestun_scoring.py").read_text()
    hour = int(re.search(r'schedule="0 (\d+) \* \* 4"', source).group(1))
    assert hour >= 7, (f"schedule fires at {hour}:00; the source load has been "
                       f"seen finishing as late as 06:38")


def test_schedule_is_weekly_on_thursday():
    """Assert the configured cron from source. CronTriggerTimetable exposes no
    stable public accessor for the expression, and coupling a test to Airflow
    internals is how it breaks on the next upgrade."""
    import re
    from pathlib import Path
    source = Path("dags/fds_gestun_scoring.py").read_text()
    match = re.search(r'schedule="0 \d+ \* \* 4"', source)
    assert match, "expected a weekly cron on Thursday (day 4)"


def test_dag_timezone_is_jakarta(dagbag):
    dag = dagbag.dags["fds_gestun_scoring"]
    assert "Jakarta" in str(dag.timezone)


def test_window_params_default_to_the_data_interval(dagbag):
    """Null defaults mean the run uses its own week. A hardcoded date here would
    pin every run to one window."""
    dag = dagbag.dags["fds_gestun_scoring"]
    params = dag.params.dump()
    assert params["window_start"] is None
    assert params["window_end"] is None


def test_thin_accounts_are_filtered_out(dagbag):
    """The model over-flags companies with almost no history, so the candidate
    query must exclude them rather than fill the queue with noise."""
    dag = dagbag.dags["fds_gestun_scoring"]
    assert dag.params.dump()["min_transactions"] >= 10


# --- the transaction-date window ------------------------------------------------

def _window(params, run_day):
    """Simulate a weekly run: Airflow's interval is the preceding 7 days."""
    import pendulum, sys
    sys.path.insert(0, "dags")
    from fds_gestun_scoring import resolve_window
    end = pendulum.parse(run_day, tz="Asia/Jakarta").at(3, 0)
    return resolve_window(params, end.subtract(days=7), end)


def test_window_is_thursday_to_wednesday_ending_the_day_before_the_run():
    """The source mart lands H-1, so a Thursday run must not include Thursday."""
    import pendulum
    start, end = _window({}, "2026-09-17")          # a Thursday
    assert (start, end) == ("2026-09-10", "2026-09-16")
    assert pendulum.parse(start).format("dddd") == "Thursday"
    assert pendulum.parse(end).format("dddd") == "Wednesday"


def test_window_never_includes_the_run_day():
    """Including the run day would score a partial day of H-1 data."""
    for run_day in ("2026-09-17", "2026-09-24", "2026-10-01"):
        _, end = _window({}, run_day)
        assert end < run_day, f"{run_day} window ends {end}"


def test_window_is_exactly_seven_days():
    import pendulum
    start, end = _window({}, "2026-09-17")
    assert (pendulum.parse(end) - pendulum.parse(start)).days + 1 == 7


def test_consecutive_windows_do_not_overlap_or_skip_a_day():
    """Every transaction day must land in exactly one window."""
    import pendulum
    _, end_1 = _window({}, "2026-09-17")
    start_2, _ = _window({}, "2026-09-24")
    assert pendulum.parse(start_2) == pendulum.parse(end_1).add(days=1)


def test_explicit_params_override_the_interval():
    """Re-scoring a named week must not need a code change."""
    override = {"window_start": "2026-07-01", "window_end": "2026-07-07"}
    assert _window(override, "2026-08-11") == ("2026-07-01", "2026-07-07")


def test_backwards_window_is_rejected():
    import pytest
    with pytest.raises(ValueError, match="after"):
        _window({"window_start": "2026-08-10", "window_end": "2026-08-04"},
                "2026-08-11")


def test_window_does_not_depend_on_when_the_run_happens():
    """CURRENT_DATE() would make an October re-run score October. The window is
    derived from the run day, so a replay gives the same answer as the original."""
    assert _window({}, "2026-09-17") == ("2026-09-10", "2026-09-16")
    assert _window({}, "2026-08-13") == ("2026-08-06", "2026-08-12")


# --- the score -> publish contract ----------------------------------------------

def test_task_signatures_only_request_real_context_keys():
    """Airflow injects a task argument only if it is a known context key.
    A typo becomes a missing-argument error at runtime, not at parse time."""
    import re
    from pathlib import Path
    from airflow.sdk.definitions.context import KNOWN_CONTEXT_KEYS

    source = Path("dags/fds_gestun_scoring.py").read_text()
    passed_explicitly = {"features_path", "scores_path", "company_ids", "peer_pool"}
    for fn in ("select_candidates", "build_features", "score", "publish"):
        match = re.search(rf"def {fn}\(([^)]*)\)", source)
        assert match, fn
        args = [a.split(":")[0].strip() for a in match.group(1).split(",") if a.strip()]
        for arg in args:
            assert arg in KNOWN_CONTEXT_KEYS or arg in passed_explicitly, \
                f"{fn}() asks for '{arg}', which Airflow will not inject"


def test_schema_and_scored_columns_agree():
    """publish() loads with an explicit schema, so a column score() forgets to
    write is a load failure at 03:00 rather than a test failure now."""
    import sys
    sys.path.insert(0, "dags")
    from fds_gestun_scoring import SCORE_SCHEMA

    schema_cols = [n for n, _, _ in SCORE_SCHEMA]
    # what model.score() produces, plus what score() attaches afterwards
    from fds_gestun.model import GestunModel
    produced = {"company_id", "gestun_probability", "gestun_pct", "decision",
                "risk_band", "features_present", "features_total"}
    attached = {"scored_date", "window_start", "window_end", "threshold",
                "model_trained_on", "model_positives", "model_features"}
    assert set(schema_cols) == produced | attached, (
        f"schema/columns drift: {set(schema_cols) ^ (produced | attached)}")


def test_every_schema_column_is_documented():
    """This table outlives the conversation that produced it."""
    import sys
    sys.path.insert(0, "dags")
    from fds_gestun_scoring import SCORE_SCHEMA
    for name, _, description in SCORE_SCHEMA:
        assert description and len(description) > 10, f"{name} has no description"


def test_probability_column_warns_it_is_not_calibrated():
    """The single most misreadable number in the output."""
    import sys
    sys.path.insert(0, "dags")
    from fds_gestun_scoring import SCORE_SCHEMA
    desc = dict((n, d) for n, _, d in SCORE_SCHEMA)["gestun_probability"]
    assert "calibrat" in desc.lower() and "ranking" in desc.lower()
