CREATE SCHEMA IF NOT EXISTS gold;

-- One row per country and year.
CREATE OR REPLACE VIEW gold.country_year_indicators AS
SELECT
    country_code,
    year,
    MAX(value) FILTER (
        WHERE indicator_code = 'SP.POP.TOTL'
    ) AS population,
    MAX(value) FILTER (
        WHERE indicator_code = 'NY.GDP.PCAP.CD'
    ) AS gdp_per_capita_usd
FROM bronze.world_bank_indicators
WHERE country_code IN ('NGA', 'GHA')
  AND indicator_code IN ('SP.POP.TOTL', 'NY.GDP.PCAP.CD')
GROUP BY country_code, year;


-- Previous-year values and annual changes for both indicators.
-- The consecutive-year check prevents treating a gap as one year.
CREATE OR REPLACE VIEW gold.country_year_changes AS
WITH history AS (
    SELECT
        country_code,
        year,
        population,
        gdp_per_capita_usd,
        LAG(year) OVER country_history AS previous_year,
        LAG(population) OVER country_history AS previous_population,
        LAG(gdp_per_capita_usd) OVER country_history
            AS previous_gdp_per_capita_usd
    FROM gold.country_year_indicators
    WINDOW country_history AS (
        PARTITION BY country_code
        ORDER BY year
    )
)
SELECT
    *,
    CASE WHEN year = previous_year + 1
        THEN population - previous_population
    END AS population_added,
    CASE WHEN year = previous_year + 1
        THEN 100.0 * (population - previous_population)
            / NULLIF(previous_population, 0)
    END AS population_growth_pct,
    CASE WHEN year = previous_year + 1
        THEN gdp_per_capita_usd - previous_gdp_per_capita_usd
    END AS gdp_per_capita_change_usd,
    CASE WHEN year = previous_year + 1
        THEN 100.0
            * (gdp_per_capita_usd - previous_gdp_per_capita_usd)
            / NULLIF(previous_gdp_per_capita_usd, 0)
    END AS gdp_per_capita_growth_pct
FROM history;


-- Preserve the population view we created earlier.
CREATE OR REPLACE VIEW gold.population_growth AS
SELECT
    country_code,
    year,
    population,
    previous_population,
    population_added,
    ROUND(population_growth_pct, 2) AS population_growth_pct
FROM gold.country_year_changes;


-- Only years with both indicators available for both countries.
CREATE OR REPLACE VIEW gold.common_complete_years AS
SELECT year
FROM gold.country_year_indicators
GROUP BY year
HAVING COUNT(*) = 2
   AND COUNT(population) = 2
   AND COUNT(gdp_per_capita_usd) = 2;


-- A comparison dataset suitable for charts and dashboards.
CREATE OR REPLACE VIEW gold.country_comparison AS
WITH comparison AS (
    SELECT
        year,
        MAX(population) FILTER (
            WHERE country_code = 'NGA'
        ) AS nigeria_population,
        MAX(population) FILTER (
            WHERE country_code = 'GHA'
        ) AS ghana_population,
        MAX(gdp_per_capita_usd) FILTER (
            WHERE country_code = 'NGA'
        ) AS nigeria_gdp_per_capita_usd,
        MAX(gdp_per_capita_usd) FILTER (
            WHERE country_code = 'GHA'
        ) AS ghana_gdp_per_capita_usd
    FROM gold.country_year_indicators
    GROUP BY year
)
SELECT
    *,
    ghana_gdp_per_capita_usd - nigeria_gdp_per_capita_usd
        AS ghana_minus_nigeria_gdp_per_capita_usd,
    ghana_gdp_per_capita_usd
        / NULLIF(nigeria_gdp_per_capita_usd, 0)
        AS ghana_to_nigeria_gdp_per_capita_ratio,
    100.0 * nigeria_population
        / NULLIF(nigeria_population + ghana_population, 0)
        AS nigeria_population_share_pct,
    100.0 * ghana_population
        / NULLIF(nigeria_population + ghana_population, 0)
        AS ghana_population_share_pct
FROM comparison;