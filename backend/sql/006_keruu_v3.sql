-- Työmaatutka 006: tarkempi keruu
-- 1) Ajoneuvon viimeisin tila säilyy keruujaksojen välillä -> jakson rajalle osuvat pysäkkivälit eivät enää katoa
-- 2) Pysäkkiväli jaetaan ajoon (lähtö -> saapuminen) ja seisontaan (saapuminen -> lähtö)
-- 3) Lupien pysäkkiväleiltä tallennetaan yksittäiset havainnot 21 vrk -> mediaani ja havaintomäärä

create table if not exists hfp_tila (
  veh text primary key, t timestamptz, stop integer, dl integer, trip text,
  arr_stop integer, arr_t timestamptz, arr_dl integer, paivitetty timestamptz default now());
alter table hfp_tila enable row level security;

alter table segment_2h add column if not exists sum_ddl_ajo double precision not null default 0;
alter table segment_2h add column if not exists n_ajo integer not null default 0;
alter table segment_2h add column if not exists sum_seis double precision not null default 0;
alter table segment_2h add column if not exists n_seis integer not null default 0;

create or replace function seg_add3(rows jsonb) returns void
language sql security definer set search_path = public as $$
  insert into segment_2h as s (bucket, from_stop, to_stop, route, dir, mode, n, sum_tt, sum_tt2, min_tt, max_tt, sum_ddl, n_ddl, sum_ddl_ajo, n_ajo, sum_seis, n_seis)
  select bucket, from_stop, to_stop, route, dir, mode, n, sum_tt, sum_tt2, min_tt, max_tt,
    coalesce(sum_ddl,0), coalesce(n_ddl,0), coalesce(sum_ddl_ajo,0), coalesce(n_ajo,0), coalesce(sum_seis,0), coalesce(n_seis,0)
  from jsonb_to_recordset(rows) as r(bucket timestamptz, from_stop int, to_stop int, route text, dir smallint, mode text,
       n int, sum_tt float8, sum_tt2 float8, min_tt float8, max_tt float8, sum_ddl float8, n_ddl int,
       sum_ddl_ajo float8, n_ajo int, sum_seis float8, n_seis int)
  on conflict (bucket, from_stop, to_stop, route, dir) do update set
    n = s.n + excluded.n, sum_tt = s.sum_tt + excluded.sum_tt, sum_tt2 = s.sum_tt2 + excluded.sum_tt2,
    min_tt = least(s.min_tt, excluded.min_tt), max_tt = greatest(s.max_tt, excluded.max_tt),
    sum_ddl = s.sum_ddl + excluded.sum_ddl, n_ddl = s.n_ddl + excluded.n_ddl,
    sum_ddl_ajo = s.sum_ddl_ajo + excluded.sum_ddl_ajo, n_ajo = s.n_ajo + excluded.n_ajo,
    sum_seis = s.sum_seis + excluded.sum_seis, n_seis = s.n_seis + excluded.n_seis;
$$;
revoke execute on function seg_add3(jsonb) from public, anon, authenticated;

create table if not exists seg_havainto (
  t timestamptz not null, from_stop integer not null, to_stop integer not null, route text not null, dir smallint,
  tt real, ajo real, seis real, ddl real, ddl_ajo real, ddl_seis real);
create index if not exists seg_havainto_pari on seg_havainto (from_stop, to_stop, t);
create index if not exists seg_havainto_t on seg_havainto (t);
alter table seg_havainto enable row level security;

-- seurattavat pysäkkivälit (edge-funktio lukee nämä ja tallentaa niiltä yksittäiset havainnot)
create or replace view seuratut_parit as
select from_stop, to_stop from lupa_segmentit
union select from_stop, to_stop from tyomaa_segmentit;

select cron.schedule('hfp-siivous', '35 2 * * *', $$delete from seg_havainto where t < now() - interval '21 days'; delete from hfp_tila where paivitetty < now() - interval '1 day'$$);
