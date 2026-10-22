# World Bank Data Pipeline

A Python and PostgreSQL project that collects population and GDP
per capita data for Nigeria and Ghana from the World Bank API,
validates the observations, and prepares them for SQL analysis.

## Analytical questions

- How have population and GDP per capita changed over time?
- How has the GDP per capita gap between Nigeria and Ghana changed?
- Which years recorded the largest increases and declines?
- When did population growth coincide with falling GDP per capita?
- Is the dataset complete enough for these comparisons?

## How it works

1. Request each country–indicator combination from the API.
2. Archive each response in a separate run folder.
3. Validate response structure, pagination, totals, and observations.
4. Load each validated batch into PostgreSQL using upserts.
5. Record execution status and committed observation counts.
6. Use SQL views to calculate annual changes and country comparisons.

## Technologies

Python, Requests, SQLAlchemy, Psycopg, PostgreSQL, pytest,
and GitHub Actions.

## Implemented features

- Paginated API extraction
- Bounded retries for timeouts, connection failures, and selected
  temporary HTTP errors
- Raw response archives and timestamped logs
- Country, indicator, year, numeric value, and duplicate validation
- Decimal parsing for numeric values
- PostgreSQL upserts using a composite primary key
- Batch loading and monitoring counts committed in one transaction
- Database run tracking
- SQL window functions for annual growth calculations
- 18 automated validation, request, pagination, and archive tests
- GitHub Actions workflow for running tests on pushes and pull requests

## Project structure

| File | Purpose |
|---|---|
| `main.py` | Extraction, validation, loading, and run tracking |
| `test_pipeline.py` | Automated tests |
| `requirements.txt` | Dependency versions |
| `sql/00_setup.sql` | Source schema and table |
| `sql/01_analysis_views.sql` | Reusable analytical views |
| `sql/02_analysis_queries.sql` | Analysis and quality checks |
| `.github/workflows/tests.yml` | Automated test workflow |

## Local setup

### 1. Create a virtual environment and install dependencies

From the project directory:

```bash
python3 -m venv .venv
source .venv/bin/activate
python -m pip install -r requirements.txt
```

### 2. Prepare PostgreSQL

Create a database named `etl_from_python`.

Connect to that database in pgAdmin and execute:

```text
sql/00_setup.sql
```

The pipeline creates its monitoring schema and table automatically.

### 3. Configure the connection

Set these environment variables in your terminal or PyCharm
run configuration:

| Variable | Default |
|---|---|
| `DB_HOST` | `localhost` |
| `DB_PORT` | `5432` |
| `DB_USER` | `postgres` |
| `DB_NAME` | `etl_from_python` |
| `DB_PASSWORD` | Required; no default |

For a terminal session, enter the password without placing it in
the command itself:

```bash
read -s -p "Database password: " DB_PASSWORD
export DB_PASSWORD
```

The script reads environment variables directly; it does not
automatically load a `.env` file.

### 4. Run the pipeline

```bash
python main.py
```

Responses and logs are saved under:

```text
data/runs/<run_identifier>/
```

Each run creates its own archive. Generated data and credentials
are excluded from version control.

### 5. Create views and run analysis

In pgAdmin, execute `sql/01_analysis_views.sql` in full, then run
the numbered queries from `sql/02_analysis_queries.sql`.

### 6. Run tests

```bash
python -m pytest test_pipeline.py -q
```

The tests use simulated API responses and temporary files.
They do not require a live API or database connection.

## Verified local execution

During development, the pipeline processed 264 observations:
66 annual observations for each of four country–indicator
combinations, covering 1960–2025.

All 18 automated tests passed locally. Future API responses may
change the number of observations and their values.

## Data source and interpretation

Source: [World Bank Indicators API](https://api.worldbank.org/v2/)

| Indicator | Code |
|---|---|
| Population, total | `SP.POP.TOTL` |
| GDP per capita, current US dollars | `NY.GDP.PCAP.CD` |

GDP per capita is measured in current US dollars. Its changes
should not be interpreted as inflation-adjusted economic growth
or purchasing-power comparisons.

## Current limitations

- Pipeline execution is manual and requires a PostgreSQL database.
- GitHub Actions runs tests; it does not run the live extraction.
- Automated tests do not yet cover actual PostgreSQL transactions.
- Upserts retain existing observations absent from later responses.
- A forced shutdown or database outage can leave a monitoring
  record marked `running`.
## Scheduled execution on macOS

The pipeline supports daily local runs through launchd, with database
password retrieval from macOS Keychain, persistent logs and failure
notifications. A scheduler-triggered run and a simulated failure were
tested successfully.

See [automation setup](automation/README.md).

## Run with Docker Compose

### Prerequisites

- Docker Desktop installed and running.
- PostgreSQL running on your Mac and reachable from Docker.
- An `etl_from_python` database prepared using `sql/00_setup.sql`.

This configuration runs the Python pipeline in a container and connects
to PostgreSQL on the host Mac through `host.docker.internal:5432`.
It does not create a PostgreSQL container.

### Build the image

From the project directory:

```bash
docker compose build
```

### Set the database password

In macOS's default zsh terminal:

```zsh
read -s "DB_PASSWORD?Enter PostgreSQL password: "
export DB_PASSWORD
echo
```

For Bash:

```bash
read -s -p "Enter PostgreSQL password: " DB_PASSWORD
export DB_PASSWORD
echo
```

The password must be available in the terminal session used to run
Compose. It is not stored in the image or Compose file.

### Run the pipeline

```bash
docker compose run --rm pipeline
```

Compose supplies the database settings and mounts the local `data`
directory at `/app/data`. Raw responses and logs remain on the Mac
after the container exits.

The pipeline inserts or updates observations in the configured database.
Reruns update matching observation keys rather than inserting duplicates.

### Docker files

| File | Purpose |
|---|---|
| `Dockerfile` | Builds the Python pipeline image |
| `.dockerignore` | Excludes local environments, credentials and generated files from the build context |
| `compose.yaml` | Configures the pipeline container, database connection and archive directory |

### Verified execution

On 22 October 2026, both a direct Docker run and a Docker Compose run
successfully processed 264 observations. Database checks after the
direct run confirmed matching total-row and unique-observation counts.
