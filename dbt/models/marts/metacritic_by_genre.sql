-- Dashboard Tile 1: Average Metacritic score by genre
-- Explodes the genres array so each game-genre pair becomes a row,
-- then aggregates. Only genres with ≥20 rated games are included
-- to avoid small-sample noise.

{{ config(materialized='table') }}

with exploded as (

    select
        app_id,
        game_name,
        metacritic_score,
        genre.element as genre

    from {{ ref('stg_steam_games') }},
    unnest(genres.list) as genre

    where
        metacritic_score > 0
        and genres is not null

)

select
    genre,
    round(avg(metacritic_score), 1)  as avg_metacritic_score,
    count(*)                          as rated_game_count,
    min(metacritic_score)             as min_score,
    max(metacritic_score)             as max_score

from exploded
group by genre
having count(*) >= 20
order by avg_metacritic_score desc