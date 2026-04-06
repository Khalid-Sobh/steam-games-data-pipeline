-- Dashboard Tile 2: Number of games released per year, broken down by price tier
-- Used for a stacked bar chart in Looker Studio.
-- Price tiers: Free / Budget (<$10) / Mid ($10–$29) / Premium ($30+)

{{ config(materialized='table') }}

select
    release_year,
    date(release_year, 1, 1)    as release_date,
    price_tier,
    count(*)        as game_count

from {{ ref('stg_steam_games') }}

where
    -- release_year between 2005 and 2024
    release_year >= 1970
    and price_tier is not null

group by
    release_year,
    price_tier

order by
    release_year,
    price_tier
