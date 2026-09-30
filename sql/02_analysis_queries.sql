-- =========================================================
-- 1. Latest comparable population and GDP per capita
-- =========================================================

SELECT
    country_code,
    year,
    population,
    ROUND(gdp_per_capita_usd, 2) AS gdp_per_capita_usd
FROM gold.country_year_indicators
WHERE year = (
    SELECT MAX(year)
    FROM gold.common_complete_years
)
ORDER BY country_code;


-- =========================================================
-- 2. Annual population additions and percentage growth
-- =========================================================

SELECT
    country_code,
    year,
    population,
    previous_population,
    population_added,
    ROUND(population_growth_pct, 2) AS population_growth_pct
FROM gold.country_year_changes
ORDER BY country_code, year;


-- =========================================================
-- 3. Annual GDP per capita changes
-- =========================================================

SELECT
    country_code,
    year,
    ROUND(gdp_per_capita_usd, 2) AS gdp_per_capita_usd,
    ROUND(previous_gdp_per_capita_usd, 2)
        AS previous_gdp_per_capita_usd,
    ROUND(gdp_per_capita_change_usd, 2)
        AS gdp_per_capita_change_usd,
    ROUND(gdp_per_capita_growth_pct, 2)
        AS gdp_per_capita_growth_pct
FROM gold.country_year_changes
ORDER BY country_code, year;


-- =========================================================
-- 4. Cumulative change since 2000
-- Uses one common latest year for both countries.
-- =========================================================

WITH endpoints AS (
    SELECT MAX(year) AS end_year
    FROM gold.common_complete_years
    WHERE year > 2000
)
SELECT
    baseline.country_code,
    baseline.year AS start_year,
    latest.year AS end_year,
    baseline.population AS population_2000,
    latest.population AS latest_population,
    latest.population - baseline.population AS population_added,
    ROUND(
        100.0 * (latest.population - baseline.population)
        / NULLIF(baseline.population, 0),
        2
    ) AS population_change_pct,
    ROUND(baseline.gdp_per_capita_usd, 2)
        AS gdp_per_capita_usd_2000,
    ROUND(latest.gdp_per_capita_usd, 2)
        AS latest_gdp_per_capita_usd,
    ROUND(
        100.0
        * (latest.gdp_per_capita_usd - baseline.gdp_per_capita_usd)
        / NULLIF(baseline.gdp_per_capita_usd, 0),
        2
    ) AS gdp_per_capita_change_pct
FROM gold.country_year_indicators AS baseline
JOIN gold.country_year_indicators AS latest
    ON latest.country_code = baseline.country_code
JOIN endpoints
    ON latest.year = endpoints.end_year
WHERE baseline.year = 2000
  AND baseline.year IN (
      SELECT year FROM gold.common_complete_years
  )
ORDER BY baseline.country_code;


-- =========================================================
-- 5. Compound annual growth rates since 2000
-- CAGR uses endpoint values and elapsed years.
-- =========================================================

WITH endpoints AS (
    SELECT MAX(year) AS end_year
    FROM gold.common_complete_years
    WHERE year > 2000
)
SELECT
    baseline.country_code,
    baseline.year AS start_year,
    latest.year AS end_year,
    latest.year - baseline.year AS elapsed_years,
    CASE
        WHEN baseline.population > 0
         AND latest.population > 0
        THEN ROUND(
            100.0 * (
                POWER(
                    latest.population / baseline.population,
                    1.0 / (latest.year - baseline.year)
                ) - 1
            ),
            2
        )
    END AS population_cagr_pct,
    CASE
        WHEN baseline.gdp_per_capita_usd > 0
         AND latest.gdp_per_capita_usd > 0
        THEN ROUND(
            100.0 * (
                POWER(
                    latest.gdp_per_capita_usd
                        / baseline.gdp_per_capita_usd,
                    1.0 / (latest.year - baseline.year)
                ) - 1
            ),
            2
        )
    END AS gdp_per_capita_current_usd_cagr_pct
FROM gold.country_year_indicators AS baseline
JOIN gold.country_year_indicators AS latest
    ON latest.country_code = baseline.country_code
JOIN endpoints
    ON latest.year = endpoints.end_year
WHERE baseline.year = 2000
  AND baseline.year IN (
      SELECT year FROM gold.common_complete_years
  )
ORDER BY baseline.country_code;


-- =========================================================
-- 6. GDP per capita gap and ratio over time
-- Positive gap: Ghana's value exceeds Nigeria's.
-- Ratio of 2: Ghana's value is twice Nigeria's.
-- =========================================================

SELECT
    year,
    ROUND(nigeria_gdp_per_capita_usd, 2)
        AS nigeria_gdp_per_capita_usd,
    ROUND(ghana_gdp_per_capita_usd, 2)
        AS ghana_gdp_per_capita_usd,
    ROUND(ghana_minus_nigeria_gdp_per_capita_usd, 2)
        AS ghana_minus_nigeria_gap_usd,
    ROUND(ghana_to_nigeria_gdp_per_capita_ratio, 3)
        AS ghana_to_nigeria_ratio
FROM gold.country_comparison
ORDER BY year;


-- =========================================================
-- 7. Top five GDP per capita increases and declines
-- Ranks percentage changes separately for each country.
-- =========================================================

WITH classified AS (
    SELECT
        country_code,
        year,
        gdp_per_capita_usd,
        gdp_per_capita_growth_pct,
        CASE
            WHEN gdp_per_capita_growth_pct > 0 THEN 'Increase'
            WHEN gdp_per_capita_growth_pct < 0 THEN 'Decline'
        END AS change_type
    FROM gold.country_year_changes
    WHERE gdp_per_capita_growth_pct IS NOT NULL
      AND gdp_per_capita_growth_pct <> 0
),
ranked AS (
    SELECT
        *,
        ROW_NUMBER() OVER (
            PARTITION BY country_code, change_type
            ORDER BY ABS(gdp_per_capita_growth_pct) DESC, year
        ) AS change_rank
    FROM classified
)
SELECT
    country_code,
    change_type,
    change_rank,
    year,
    ROUND(gdp_per_capita_usd, 2) AS gdp_per_capita_usd,
    ROUND(gdp_per_capita_growth_pct, 2)
        AS gdp_per_capita_growth_pct
FROM ranked
WHERE change_rank <= 5
ORDER BY country_code, change_type, change_rank;


-- =========================================================
-- 8. Population growth alongside falling GDP per capita
-- Describes coinciding changes; does not establish causation.
-- =========================================================

SELECT
    country_code,
    year,
    population_added,
    ROUND(population_growth_pct, 2) AS population_growth_pct,
    ROUND(gdp_per_capita_change_usd, 2)
        AS gdp_per_capita_change_usd,
    ROUND(gdp_per_capita_growth_pct, 2)
        AS gdp_per_capita_growth_pct
FROM gold.country_year_changes
WHERE population_growth_pct > 0
  AND gdp_per_capita_growth_pct < 0
ORDER BY country_code, year;


-- =========================================================
-- 9. Average annual growth rates by decade
-- Each change belongs to its ending year.
-- These are arithmetic averages, not CAGR.
-- Counts expose missing growth observations.
-- =========================================================

WITH decade_rows AS (
    SELECT
        *,
        (year / 10) * 10 AS decade_start
    FROM gold.country_year_changes
)
SELECT
    country_code,
    decade_start,
    decade_start + 9 AS decade_end,
    MIN(year) AS first_observed_year,
    MAX(year) AS last_observed_year,
    COUNT(*) AS observed_years,
    COUNT(population_growth_pct) AS population_growth_observations,
    COUNT(gdp_per_capita_growth_pct)
        AS gdp_per_capita_growth_observations,
    ROUND(AVG(population_growth_pct), 2)
        AS average_annual_population_growth_pct,
    ROUND(AVG(gdp_per_capita_growth_pct), 2)
        AS average_annual_gdp_per_capita_growth_pct,
    CASE
        WHEN COUNT(*) = 10
         AND COUNT(population_growth_pct) = 10
         AND COUNT(gdp_per_capita_growth_pct) = 10
        THEN 'Complete'
        ELSE 'Incomplete coverage'
    END AS coverage_status
FROM decade_rows
GROUP BY country_code, decade_start
ORDER BY country_code, decade_start;


-- =========================================================
-- 10. First recorded population milestone years
-- A milestone reached in the first available year might
-- actually have been crossed before the dataset begins.
-- =========================================================

WITH countries(country_code) AS (
    VALUES ('NGA'), ('GHA')
),
milestones(threshold) AS (
    VALUES
        (10000000::NUMERIC),
        (25000000::NUMERIC),
        (50000000::NUMERIC),
        (100000000::NUMERIC),
        (200000000::NUMERIC)
),
coverage AS (
    SELECT
        country_code,
        MIN(year) AS first_population_year
    FROM gold.country_year_indicators
    WHERE population IS NOT NULL
    GROUP BY country_code
)
SELECT
    countries.country_code,
    milestones.threshold AS population_milestone,
    MIN(indicators.year) AS first_recorded_year_at_or_above,
    CASE
        WHEN MIN(indicators.year) IS NULL
            THEN 'Not observed in available data'
        WHEN MIN(indicators.year) = coverage.first_population_year
            THEN 'Already reached at start of available data'
        ELSE 'First observed crossing within available data'
    END AS milestone_status
FROM countries
CROSS JOIN milestones
LEFT JOIN coverage
    ON coverage.country_code = countries.country_code
LEFT JOIN gold.country_year_indicators AS indicators
    ON indicators.country_code = countries.country_code
   AND indicators.population >= milestones.threshold
GROUP BY
    countries.country_code,
    milestones.threshold,
    coverage.first_population_year
ORDER BY countries.country_code, milestones.threshold;


-- =========================================================
-- 11. Share of Nigeria and Ghana's combined population
-- These are shares of these two countries, not of Africa.
-- =========================================================

SELECT
    year,
    nigeria_population,
    ghana_population,
    nigeria_population + ghana_population AS combined_population,
    ROUND(nigeria_population_share_pct, 2)
        AS nigeria_population_share_pct,
    ROUND(ghana_population_share_pct, 2)
        AS ghana_population_share_pct
FROM gold.country_comparison
ORDER BY year;


-- =========================================================
-- 12A. Coverage and missing-value summary
-- Returns all four expected country-indicator combinations,
-- including combinations with no records.
-- =========================================================

WITH countries(country_code) AS (
    VALUES ('NGA'), ('GHA')
),
indicators(indicator_code) AS (
    VALUES ('SP.POP.TOTL'), ('NY.GDP.PCAP.CD')
)
SELECT
    countries.country_code,
    indicators.indicator_code,
    MIN(observations.year) AS first_year,
    MAX(observations.year) AS latest_year,
    COUNT(observations.year) AS observation_rows,
    COUNT(DISTINCT observations.year) AS distinct_years,
    COUNT(observations.value) AS non_null_values,
    COUNT(*) FILTER (
        WHERE observations.year IS NOT NULL
          AND observations.value IS NULL
    ) AS missing_values,
    COUNT(observations.year)
        - COUNT(DISTINCT observations.year) AS duplicate_year_rows,
    CASE
        WHEN COUNT(observations.year) = 0 THEN 'Missing combination'
        ELSE 'Present'
    END AS combination_status
FROM countries
CROSS JOIN indicators
LEFT JOIN bronze.world_bank_indicators AS observations
    ON observations.country_code = countries.country_code
   AND observations.indicator_code = indicators.indicator_code
GROUP BY countries.country_code, indicators.indicator_code
ORDER BY countries.country_code, indicators.indicator_code;


-- =========================================================
-- 12B. Missing observations within the shared dataset span
-- Uses the minimum and maximum years present in the dataset.
-- An empty dataset has no span; 12A still flags all combinations.
-- Zero rows here means no missing observations in that span.
-- =========================================================

WITH countries(country_code) AS (
    VALUES ('NGA'), ('GHA')
),
indicators(indicator_code) AS (
    VALUES ('SP.POP.TOTL'), ('NY.GDP.PCAP.CD')
),
bounds AS (
    SELECT MIN(year) AS first_year, MAX(year) AS latest_year
    FROM bronze.world_bank_indicators
    WHERE country_code IN ('NGA', 'GHA')
      AND indicator_code IN ('SP.POP.TOTL', 'NY.GDP.PCAP.CD')
),
expected AS (
    SELECT
        countries.country_code,
        indicators.indicator_code,
        years.year
    FROM countries
    CROSS JOIN indicators
    CROSS JOIN bounds
    CROSS JOIN LATERAL GENERATE_SERIES(
        bounds.first_year,
        bounds.latest_year
    ) AS years(year)
)
SELECT
    expected.country_code,
    expected.indicator_code,
    expected.year AS missing_year
FROM expected
WHERE NOT EXISTS (
    SELECT 1
    FROM bronze.world_bank_indicators AS actual
    WHERE actual.country_code = expected.country_code
      AND actual.indicator_code = expected.indicator_code
      AND actual.year = expected.year
)
ORDER BY expected.country_code, expected.indicator_code, expected.year;


-- =========================================================
-- 12C. Missing values in observations that do exist
-- Zero rows means no NULL indicator values.
-- =========================================================

SELECT country_code, indicator_code, year
FROM bronze.world_bank_indicators
WHERE country_code IN ('NGA', 'GHA')
  AND indicator_code IN ('SP.POP.TOTL', 'NY.GDP.PCAP.CD')
  AND value IS NULL
ORDER BY country_code, indicator_code, year;