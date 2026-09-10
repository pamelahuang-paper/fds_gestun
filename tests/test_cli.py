import pandas as pd
import pytest

from fds_gestun.cli import _read_company_ids, build_parser


def test_reads_csv_with_header(tmp_path):
    path = tmp_path / "ids.csv"
    pd.DataFrame({"company_id": ["a", "b", "a", None, " "]}).to_csv(path, index=False)
    assert _read_company_ids(path) == ["a", "b"]     # deduped, blanks dropped


def test_reads_single_column_without_the_right_header(tmp_path):
    path = tmp_path / "ids.csv"
    path.write_text("uuid\nx\ny\n")
    assert _read_company_ids(path) == ["x", "y"]


def test_missing_file_raises(tmp_path):
    with pytest.raises(FileNotFoundError):
        _read_company_ids(tmp_path / "absent.csv")


def test_empty_file_raises(tmp_path):
    path = tmp_path / "ids.csv"
    path.write_text("company_id\n")
    with pytest.raises(ValueError, match="no company ids"):
        _read_company_ids(path)


def test_score_requires_a_source():
    parser = build_parser()
    with pytest.raises(SystemExit):
        parser.parse_args(["score", "--out", "x.csv"])
