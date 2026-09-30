import json
from io import BytesIO
from decimal import Decimal
from unittest.mock import Mock

import pytest
import requests

from main import (
    extract_world_bank,
    request_page,
    transform_record,
    validate_response,
    validate_rows,
)


# ---------- Test helpers ----------

def observation(value=35064272):
    return {
        "countryiso3code": "GHA",
        "indicator": {"id": "SP.POP.TOTL"},
        "date": "2025",
        "value": value,
    }


def fake_response(payload, status=200):
    body = json.dumps(payload).encode("utf-8")

    response = requests.Response()
    response.status_code = status
    response.url = "https://api.worldbank.org/test"
    response.encoding = "utf-8"
    response.raw = BytesIO(body)

    return response

# ---------- Validation tests ----------

def test_missing_value_is_preserved():
    row = transform_record(
        observation(value=None),
        "GHA",
        "SP.POP.TOTL",
    )

    assert row["value"] is None


def test_decimal_value_is_preserved():
    row = transform_record(
        observation(value=Decimal("35064272.123456789")),
        "GHA",
        "SP.POP.TOTL",
    )

    assert row["value"] == Decimal("35064272.123456789")


@pytest.mark.parametrize(
    "invalid_value",
    [-1, True, "35064272", float("inf"), float("nan")],
)
def test_invalid_values_are_rejected(invalid_value):
    with pytest.raises(ValueError, match="value"):
        transform_record(
            observation(value=invalid_value),
            "GHA",
            "SP.POP.TOTL",
        )


def test_wrong_country_is_rejected():
    with pytest.raises(ValueError, match="country or indicator"):
        transform_record(
            observation(),
            "NGA",
            "SP.POP.TOTL",
        )


def test_wrong_indicator_is_rejected():
    with pytest.raises(ValueError, match="country or indicator"):
        transform_record(
            observation(),
            "GHA",
            "NY.GDP.PCAP.CD",
        )


def test_duplicate_observations_are_rejected():
    row = transform_record(
        observation(),
        "GHA",
        "SP.POP.TOTL",
    )

    with pytest.raises(ValueError, match="Duplicate observation"):
        validate_rows([row, row.copy()], expected_total=2)


def test_incomplete_extraction_is_rejected():
    row = transform_record(
        observation(),
        "GHA",
        "SP.POP.TOTL",
    )

    with pytest.raises(ValueError, match="Expected 2 records"):
        validate_rows([row], expected_total=2)


def test_wrong_page_is_rejected():
    response = [
        {"page": 1, "pages": 2, "total": 2},
        [observation()],
    ]

    with pytest.raises(ValueError, match="pagination"):
        validate_response(response, requested_page=2)


def test_unexpected_response_is_rejected():
    with pytest.raises(ValueError, match="response structure"):
        validate_response(
            {"error": "Invalid indicator"},
            requested_page=1,
        )


# ---------- Request retry tests ----------

def test_timeout_retries_then_succeeds(monkeypatch):
    sleep = Mock()
    monkeypatch.setattr("main.time.sleep", sleep)

    session = Mock()
    session.get.side_effect = [
        requests.exceptions.Timeout("Simulated timeout"),
        fake_response({"ok": True}),
    ]

    result = request_page(
        session,
        "https://api.worldbank.org/test",
        {"page": 1},
    )

    assert json.loads(result) == {"ok": True}
    assert session.get.call_count == 2
    sleep.assert_called_once_with(2)


def test_timeout_stops_after_three_attempts(monkeypatch):
    sleep = Mock()
    monkeypatch.setattr("main.time.sleep", sleep)

    session = Mock()
    session.get.side_effect = requests.exceptions.Timeout(
        "Simulated persistent timeout"
    )

    with pytest.raises(requests.exceptions.Timeout):
        request_page(
            session,
            "https://api.worldbank.org/test",
            {"page": 1},
        )

    assert session.get.call_count == 3
    assert sleep.call_count == 2


def test_temporary_server_error_is_retried(monkeypatch):
    monkeypatch.setattr("main.time.sleep", Mock())

    session = Mock()
    session.get.side_effect = [
        fake_response({"error": "Unavailable"}, status=503),
        fake_response({"ok": True}),
    ]

    result = request_page(
        session,
        "https://api.worldbank.org/test",
        {"page": 1},
    )

    assert json.loads(result) == {"ok": True}
    assert session.get.call_count == 2


def test_not_found_is_not_retried(monkeypatch):
    sleep = Mock()
    monkeypatch.setattr("main.time.sleep", sleep)

    session = Mock()
    session.get.return_value = fake_response(
        {"error": "Not found"},
        status=404,
    )

    with pytest.raises(requests.exceptions.HTTPError):
        request_page(
            session,
            "https://api.worldbank.org/test",
            {"page": 1},
        )

    assert session.get.call_count == 1
    sleep.assert_not_called()


# ---------- Pagination and archive test ----------

def test_extraction_collects_and_archives_both_pages(tmp_path):
    first_record = observation()

    second_record = observation(value=34427414)
    second_record["date"] = "2024"

    session = Mock()
    session.get.side_effect = [
        fake_response([
            {"page": 1, "pages": 2, "total": 2},
            [first_record],
        ]),
        fake_response([
            {"page": 2, "pages": 2, "total": 2},
            [second_record],
        ]),
    ]

    rows = extract_world_bank(
        session,
        "GH",
        "SP.POP.TOTL",
        tmp_path,
    )

    assert [row["year"] for row in rows] == [2025, 2024]

    requested_pages = [
        call.kwargs["params"]["page"]
        for call in session.get.call_args_list
    ]
    assert requested_pages == [1, 2]

    for page, expected_record in (
        (1, first_record),
        (2, second_record),
    ):
        archive = tmp_path / f"GH_SP.POP.TOTL_page_{page}.json"
        saved_data = json.loads(
            archive.read_text(encoding="utf-8")
        )

        assert saved_data[0]["page"] == page
        assert saved_data[1] == [expected_record]