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
        "select_candidates", "build_features", "score", "publish"}
    upstream = {t.task_id: sorted(t.upstream_task_ids) for t in dag.tasks}
    assert upstream["select_candidates"] == []
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


def test_window_is_friday_to_thursday_ending_on_the_run_day():
    """A Thursday run scores the Fri-Thu week ending that same day."""
    import pendulum
    start, end = _window({}, "2026-09-17")          # a Thursday
    assert (start, end) == ("2026-09-11", "2026-09-17")
    assert pendulum.parse(start).format("dddd") == "Friday"
    assert pendulum.parse(end).format("dddd") == "Thursday"


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
    assert _window({}, "2026-09-17") == ("2026-09-11", "2026-09-17")
    assert _window({}, "2026-08-13") == ("2026-08-07", "2026-08-13")
