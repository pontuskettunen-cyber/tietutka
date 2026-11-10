-- Työmaatutka 008: pysäkkien nimet, tilanäkymä uuteen keruuseen, vanhan pilottitallentimen alasajo

create table if not exists pysakki_nimet (stop integer primary key, nimi text, lyhyt text);
alter table pysakki_nimet enable row level security;

create or replace view v_lupa_segmentit with (security_invoker = false) as
select s.lupa_id, s.from_stop, s.to_stop, pa.lat from_lat, pa.lon from_lon, pb.lat to_lat, pb.lon to_lon,
  s.linjat, s.n_24h, s.lisaviive_s, s.indeksi_24h,
  na.nimi from_nimi, nb.nimi to_nimi, na.lyhyt from_lyhyt, nb.lyhyt to_lyhyt
from lupa_segmentti_tila s
join pysakit pa on pa.stop = s.from_stop join pysakit pb on pb.stop = s.to_stop
left join pysakki_nimet na on na.stop = s.from_stop left join pysakki_nimet nb on nb.stop = s.to_stop;
grant select on v_lupa_segmentit to anon, authenticated;

-- tilanäkymä uuden keruun mukaan + tietokannan koko (ilmaistason raja 500 MB)
drop view if exists v_tila;
create view v_tila with (security_invoker = false) as
select
  (select count(*) from seg_havainto) tapahtumia,
  (select count(*) from seg_havainto where t > now() - interval '10 minutes') viim_10_min,
  (select count(distinct route) from segment_2h where bucket > now() - interval '24 hours') linjoja_24h,
  (select coalesce(sum(n),0) from segment_2h) pysakkivali_havainnot,
  (select count(*) from (select distinct from_stop, to_stop from segment_2h) x) pysakkivaleja,
  (select max(alkoi) from tallennin_loki where funktio = 'hfp-segmentit') viimeisin,
  (select min(bucket) from segment_2h) keruu_alkoi,
  (select count(*) from luvat_snapshot where snap_date = (select max(snap_date) from luvat_snapshot)) lupia_tanaan,
  (select count(*) from tietyot_snapshot where snap_date = (select max(snap_date) from tietyot_snapshot)) tietoita_tanaan,
  round(pg_database_size(current_database()) / 1e6) db_mb;
grant select on v_tila to anon, authenticated;

-- vanha kuuden solun pilottitallennin on korvattu koko verkon keruulla
select cron.unschedule('hfp-recorder-minuutti');
select cron.schedule('pysakit-nimet-kk', '10 3 1 * *',
  replace((select command from cron.job where jobname='hfp-aggregate-2min'), 'functions/v1/hfp-segmentit', 'functions/v1/pysakit-nimet'));
