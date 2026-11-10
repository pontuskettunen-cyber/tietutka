-- v_tila laski joka sivunlatauksella koko seg_havainto- ja segment_2h-taulun (count, sum, distinct).
-- Anonin 3 s aikaraja ylittyi, sivu yritti uudelleen ja lataus kesti 15-20 s.
-- Raskaat luvut lasketaan nyt 10 min välein välimuistiin; kevyet (viimeisin, 10 min, tietokannan koko) pysyvät reaaliaikaisina.
create table if not exists tila_valimuisti(
  id int primary key default 1 check (id = 1),
  tapahtumia bigint, linjoja_24h bigint, pysakkivali_havainnot numeric, pysakkivaleja bigint,
  paivitetty timestamptz);
alter table tila_valimuisti enable row level security;

create or replace function paivita_tila_valimuisti() returns void language sql security definer set search_path = public as $$
  insert into tila_valimuisti(id, tapahtumia, linjoja_24h, pysakkivali_havainnot, pysakkivaleja, paivitetty)
  select 1,
    (select count(*) from seg_havainto),
    (select count(distinct route) from segment_2h where bucket > now() - interval '24 hours'),
    (select coalesce(sum(n),0) from segment_2h),
    (select count(*) from (select distinct from_stop, to_stop from segment_2h) x),
    now()
  on conflict (id) do update set tapahtumia = excluded.tapahtumia, linjoja_24h = excluded.linjoja_24h,
    pysakkivali_havainnot = excluded.pysakkivali_havainnot, pysakkivaleja = excluded.pysakkivaleja, paivitetty = excluded.paivitetty;
$$;
select paivita_tila_valimuisti();

drop view if exists v_tila;
create view v_tila with (security_invoker = false) as
select
  c.tapahtumia,
  (select count(*) from seg_havainto where t > now() - interval '10 minutes') viim_10_min,
  c.linjoja_24h,
  c.pysakkivali_havainnot,
  c.pysakkivaleja,
  (select max(alkoi) from tallennin_loki where funktio = 'hfp-segmentit') viimeisin,
  (select min(bucket) from segment_2h) keruu_alkoi,
  (select count(*) from luvat_snapshot where snap_date = (select max(snap_date) from luvat_snapshot)) lupia_tanaan,
  (select count(*) from tietyot_snapshot where snap_date = (select max(snap_date) from tietyot_snapshot)) tietoita_tanaan,
  round(pg_database_size(current_database()) / 1e6) db_mb,
  (select min(t) from seg_havainto) havainto_alkoi,
  c.paivitetty valimuisti_paivitetty
from tila_valimuisti c;
grant select on v_tila to anon, authenticated;

select cron.schedule('tila-valimuisti', '4,14,24,34,44,54 * * * *', $$select paivita_tila_valimuisti()$$);
