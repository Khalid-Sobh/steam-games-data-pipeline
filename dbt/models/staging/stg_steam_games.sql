-- Staging view: typed, renamed columns on top of raw_games.
-- No filters needed — Spark already enforced data quality at ingestion.

{{ config(materialized='view') }}

select
    app_id,
    name                                        as game_name,
    release_date,
    release_year,
    price,
    price_tier,
    metacritic_score,
    peak_ccu,
    dlc_count,
    owners_lower,
    windows,
    mac,
    linux,
    genres,
    developers,
    publishers

from {{ source('steam_warehouse', 'raw_games') }}


