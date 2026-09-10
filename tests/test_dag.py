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


def test_thin_accounts_are_filtered_out(dagbag):
    """The model over-flags companies with almost no history, so the candidate
    query must exclude them rather than fill the queue with noise."""
    dag = dagbag.dags["fds_gestun_scoring"]
    assert dag.params.dump()["min_transactions"] >= 10
