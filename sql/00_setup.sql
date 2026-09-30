-- Run while connected to the etl_from_python database.

CREATE SCHEMA IF NOT EXISTS bronze;

CREATE TABLE IF NOT EXISTS bronze.world_bank_indicators (
    country_code TEXT NOT NULL,
    indicator_code TEXT NOT NULL,
    year INTEGER NOT NULL,
    value NUMERIC,
    PRIMARY KEY (country_code, indicator_code, year)
);