"""The SQL files are the deployed artefact, so guard their contract."""
import re
from fds_gestun import bq, config
from fds_gestun.features import SIMPLE_SOURCES

LABEL_TABLE = "fds_gestung_actual_label_130826"


def test_every_referenced_sql_file_exists():
    for _, filename in SIMPLE_SOURCES:
        assert (config.SQL_DIR / filename).exists(), filename
    for filename in ("peer_vocabulary.sql", "upstream_fds.sql"):
        assert (config.SQL_DIR / filename).exists(), filename


def test_no_query_still_reads_the_label_table():
    """Scoring must never depend on the label table -- that is what made the
    notebook queries unusable for unlabelled companies."""
    for path in config.SQL_DIR.glob("*.sql"):
        assert LABEL_TABLE not in path.read_text(), f"{path.name} reads the label table"


def test_every_query_is_parameterised():
    for path in config.SQL_DIR.glob("*.sql"):
        sql = path.read_text()
        assert "@company_ids" in sql or "@pool_ids" in sql, path.name


def test_no_query_interpolates_a_literal_uuid():
    """A UUID baked into the SQL means someone went back to string formatting."""
    uuid = re.compile(r"'[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'")
    for path in config.SQL_DIR.glob("*.sql"):
        assert not uuid.search(path.read_text()), path.name


def test_load_sql_rejects_unknown_names():
    import pytest
    with pytest.raises(FileNotFoundError):
        bq.load_sql("does_not_exist.sql")
