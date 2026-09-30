import json
import logging
import os
import time
from datetime import datetime, timezone
from decimal import Decimal, InvalidOperation
from pathlib import Path
from uuid import uuid4

import requests
from sqlalchemy import URL, create_engine, text


# ---------- Configuration ----------

PROJECT_DIR = Path(__file__).resolve().parent

# API country codes mapped to the country codes returned in records.
COUNTRIES = {
    "NG": "NGA",
    "GH": "GHA",
}

INDICATORS = [
    "SP.POP.TOTL",
    "NY.GDP.PCAP.CD",
]

PIPELINE_NAME = "world_bank_indicators"
MAX_ATTEMPTS = 3
REQUEST_TIMEOUT = (10, 30)  # Connection timeout, read timeout.
RETRYABLE_STATUS_CODES = {429, 500, 502, 503, 504}

logger = logging.getLogger(PIPELINE_NAME)


# ---------- Logging and database setup ----------

def configure_logging(run_folder):
    formatter = logging.Formatter(
        "%(asctime)s UTC | %(levelname)s | %(message)s"
    )
    formatter.converter = time.gmtime

    logger.setLevel(logging.INFO)
    logger.propagate = False

    # Avoid duplicate handlers if setup is called again.
    for handler in logger.handlers[:]:
        logger.removeHandler(handler)
        handler.close()

    console_handler = logging.StreamHandler()
    file_handler = logging.FileHandler(
        run_folder / "pipeline.log",
        encoding="utf-8",
    )

    for handler in (console_handler, file_handler):
        handler.setFormatter(formatter)
        logger.addHandler(handler)


def create_database_engine():
    password = os.environ.get("DB_PASSWORD")

    if not password:
        raise ValueError(
            "Set DB_PASSWORD in your PyCharm run configuration."
        )

    database_url = URL.create(
        drivername="postgresql+psycopg",
        username=os.environ.get("DB_USER", "postgres"),
        password=password,
        host=os.environ.get("DB_HOST", "localhost"),
        port=int(os.environ.get("DB_PORT", "5432")),
        database=os.environ.get("DB_NAME", "etl_from_python"),
    )

    return create_engine(
        database_url,
        pool_pre_ping=True,
        hide_parameters=True,
        connect_args={"connect_timeout": 10},
    )


def setup_monitoring(engine):
    statements = [
        "CREATE SCHEMA IF NOT EXISTS monitoring",
        """
        CREATE TABLE IF NOT EXISTS monitoring.pipeline_runs (
            run_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
            pipeline_name TEXT NOT NULL,
            started_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            finished_at TIMESTAMPTZ,
            status TEXT NOT NULL DEFAULT 'running'
                CHECK (status IN ('running', 'success', 'failed')),
            records_processed INTEGER NOT NULL DEFAULT 0
                CHECK (records_processed >= 0),
            error_message TEXT
        )
        """,
    ]

    with engine.begin() as connection:
        for statement in statements:
            connection.execute(text(statement))


def start_run(engine):
    with engine.begin() as connection:
        return connection.execute(
            text("""
                INSERT INTO monitoring.pipeline_runs (pipeline_name)
                VALUES (:pipeline_name)
                RETURNING run_id
            """),
            {"pipeline_name": PIPELINE_NAME},
        ).scalar_one()


def finish_run(engine, run_id, status, error_message=None):
    with engine.begin() as connection:
        connection.execute(
            text("""
                UPDATE monitoring.pipeline_runs
                SET status = :status,
                    finished_at = NOW(),
                    error_message = :error_message
                WHERE run_id = :run_id
            """),
            {
                "run_id": run_id,
                "status": status,
                "error_message": error_message,
            },
        )


# ---------- HTTP requests ----------

def request_page(session, url, params):
    for attempt in range(1, MAX_ATTEMPTS + 1):
        try:
            with session.get(
                url,
                params=params,
                timeout=REQUEST_TIMEOUT,
            ) as response:
                # Retry only selected temporary HTTP failures.
                if response.status_code in RETRYABLE_STATUS_CODES:
                    response.raise_for_status()

                response.raise_for_status()
                return response.text

        except (
            requests.exceptions.Timeout,
            requests.exceptions.ConnectionError,
            requests.exceptions.HTTPError,
        ) as error:
            if isinstance(error, requests.exceptions.HTTPError):
                status = error.response.status_code
                if status not in RETRYABLE_STATUS_CODES:
                    raise

            if attempt == MAX_ATTEMPTS:
                logger.error(
                    "Request failed after %s attempts: %s; page %s",
                    MAX_ATTEMPTS,
                    url,
                    params["page"],
                )
                raise

            delay = 2 ** attempt

            # Respect a numeric Retry-After header, up to 60 seconds.
            if isinstance(error, requests.exceptions.HTTPError):
                retry_after = error.response.headers.get("Retry-After")
                if retry_after and retry_after.isdigit():
                    delay = min(max(delay, int(retry_after)), 60)

            logger.warning(
                "%s on page %s, attempt %s/%s. Retrying in %ss.",
                type(error).__name__,
                params["page"],
                attempt,
                MAX_ATTEMPTS,
                delay,
            )
            time.sleep(delay)


# ---------- Response and observation validation ----------

def validate_response(data, requested_page):
    if (
        not isinstance(data, list)
        or len(data) != 2
        or not isinstance(data[0], dict)
        or not isinstance(data[1], list)
    ):
        raise ValueError("Unexpected API response structure.")

    metadata, records = data

    try:
        actual_page = int(metadata["page"])
        total_pages = int(metadata["pages"])
        expected_total = int(metadata["total"])
    except (KeyError, TypeError, ValueError) as error:
        raise ValueError("Missing or invalid pagination metadata.") from error

    if (
        actual_page != requested_page
        or total_pages < requested_page
        or expected_total <= 0
    ):
        raise ValueError(
            f"Invalid pagination metadata for page {requested_page}."
        )

    return records, total_pages, expected_total


def transform_record(record, expected_country, indicator_code):
    try:
        country = record["countryiso3code"]
        indicator = record["indicator"]["id"]
        year_text = record["date"]
        value = record["value"]
    except (KeyError, TypeError) as error:
        raise ValueError("Observation is missing required fields.") from error

    if country != expected_country or indicator != indicator_code:
        raise ValueError(
            f"Unexpected country or indicator: {country}, {indicator}."
        )

    if (
        not isinstance(year_text, str)
        or len(year_text) != 4
        or not year_text.isdigit()
    ):
        raise ValueError(f"Invalid observation year: {year_text!r}.")

    year = int(year_text)

    if not 1900 <= year <= datetime.now(timezone.utc).year:
        raise ValueError(f"Observation year outside expected range: {year}.")

    # Missing values are allowed; they become SQL NULL.
    if value is not None:
        if isinstance(value, bool) or not isinstance(
            value, (int, float, Decimal)
        ):
            raise ValueError(f"Invalid numeric value: {value!r}.")

        try:
            value = Decimal(str(value))
        except InvalidOperation as error:
            raise ValueError(f"Invalid numeric value: {value!r}.") from error

        # Both configured indicators should be non-negative.
        if not value.is_finite() or value < 0:
            raise ValueError(f"Invalid indicator value: {value!r}.")

    return {
        "country_code": country,
        "indicator_code": indicator,
        "year": year,
        "value": value,
    }


def validate_rows(rows, expected_total):
    if len(rows) != expected_total:
        raise ValueError(
            f"Expected {expected_total} records; extracted {len(rows)}."
        )

    seen_keys = set()

    for row in rows:
        key = (
            row["country_code"],
            row["indicator_code"],
            row["year"],
        )

        if key in seen_keys:
            raise ValueError(f"Duplicate observation: {key}.")

        seen_keys.add(key)


# ---------- Extraction and loading ----------

def extract_world_bank(
    session, country_code, indicator_code, raw_folder
):
    url = (
        f"https://api.worldbank.org/v2/country/{country_code}"
        f"/indicator/{indicator_code}"
    )

    rows = []
    page = 1
    initial_metadata = None

    while True:
        response_text = request_page(
            session,
            url,
            {
                "format": "json",
                "per_page": 100,
                "page": page,
            },
        )

        # Save the response before parsing, including malformed JSON.
        raw_file = raw_folder / (
            f"{country_code}_{indicator_code}_page_{page}.json"
        )
        raw_file.write_text(response_text, encoding="utf-8")

        try:
            data = json.loads(response_text, parse_float=Decimal)
            records, total_pages, expected_total = validate_response(
                data, page
            )
        except ValueError as error:
            raise ValueError(
                f"{country_code}/{indicator_code}: {error} "
                f"Inspect {raw_file}"
            ) from error

        pagination_metadata = (total_pages, expected_total)

        if initial_metadata is None:
            initial_metadata = pagination_metadata
        elif pagination_metadata != initial_metadata:
            raise ValueError(
                "API pagination totals changed during extraction."
            )

        for record in records:
            rows.append(
                transform_record(
                    record,
                    COUNTRIES[country_code],
                    indicator_code,
                )
            )

        logger.info(
            "%s | %s | page %s/%s | %s records",
            country_code,
            indicator_code,
            page,
            total_pages,
            len(records),
        )

        if page == total_pages:
            break

        page += 1

    validate_rows(rows, expected_total)

    missing_values = sum(row["value"] is None for row in rows)
    logger.info(
        "Validated %s records for %s/%s; %s missing values",
        len(rows),
        country_code,
        indicator_code,
        missing_values,
    )

    return rows


def load_to_postgres(engine, rows, run_id):
    if not rows:
        raise ValueError("No records supplied for loading.")

    # Load the batch and update its processed count in one transaction.
    with engine.begin() as connection:
        connection.execute(
            text("""
                INSERT INTO bronze.world_bank_indicators
                    (country_code, indicator_code, year, value)
                VALUES
                    (:country_code, :indicator_code, :year, :value)
                ON CONFLICT (country_code, indicator_code, year)
                DO UPDATE SET value = EXCLUDED.value
            """),
            rows,
        )

        connection.execute(
            text("""
                UPDATE monitoring.pipeline_runs
                SET records_processed = records_processed + :count
                WHERE run_id = :run_id
            """),
            {"count": len(rows), "run_id": run_id},
        )

    logger.info("Committed %s records", len(rows))


# ---------- Pipeline orchestration ----------

def main():
    archive_id = (
        datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
        + "_"
        + uuid4().hex[:8]
    )
    run_folder = PROJECT_DIR / "data" / "runs" / archive_id
    raw_folder = run_folder / "raw"
    raw_folder.mkdir(parents=True, exist_ok=False)

    configure_logging(run_folder)

    engine = None
    run_id = None
    total_processed = 0
    started = time.monotonic()

    try:
        engine = create_database_engine()
        setup_monitoring(engine)
        run_id = start_run(engine)

        logger.info(
            "Started database run %s; archive: %s",
            run_id,
            run_folder,
        )

        with requests.Session() as session:
            session.headers.update({
                "Accept": "application/json",
                "User-Agent": "WorldBankPortfolioPipeline/1.0",
            })

            for country_code in COUNTRIES:
                for indicator_code in INDICATORS:
                    rows = extract_world_bank(
                        session,
                        country_code,
                        indicator_code,
                        raw_folder,
                    )
                    load_to_postgres(engine, rows, run_id)
                    total_processed += len(rows)

        finish_run(engine, run_id, "success")

        logger.info(
            "Pipeline complete: %s records processed in %.1f seconds",
            total_processed,
            time.monotonic() - started,
        )

    except (Exception, KeyboardInterrupt) as error:
        logger.exception(
            "Pipeline stopped after %s committed records",
            total_processed,
        )

        if engine is not None and run_id is not None:
            try:
                finish_run(
                    engine,
                    run_id,
                    "failed",
                    f"{type(error).__name__}: {error}"[:4000],
                )
            except Exception:
                logger.exception(
                    "Could not update database run status; "
                    "inspect this run's pipeline.log."
                )

        # Keep a failed process exit status instead of hiding the error.
        raise

    finally:
        if engine is not None:
            engine.dispose()


if __name__ == "__main__":
    main()