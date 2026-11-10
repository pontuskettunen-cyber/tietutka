-- Työmaatutka 011: pysäkkivälit katuja pitkin (HSL:n linjageometriasta leikattuna)
create table if not exists vali_viiva (
  from_stop int, to_stop int, route text, coords jsonb, poikkeama_m real, paivitetty timestamptz default now(),
  primary key (from_stop, to_stop));
alter table vali_viiva enable row level security;

create or replace view v_lupa_segmentit with (security_invoker = false) as
select s.lupa_id, s.from_stop, s.to_stop, pa.lat from_lat, pa.lon from_lon, pb.lat to_lat, pb.lon to_lon,
  s.linjat, s.n_24h, s.lisaviive_s, s.indeksi_24h,
  na.nimi from_nimi, nb.nimi to_nimi, na.lyhyt from_lyhyt, nb.lyhyt to_lyhyt,
  vv.coords viiva
from lupa_segmentti_tila s
join pysakit pa on pa.stop = s.from_stop join pysakit pb on pb.stop = s.to_stop
left join pysakki_nimet na on na.stop = s.from_stop left join pysakki_nimet nb on nb.stop = s.to_stop
left join vali_viiva vv on vv.from_stop = s.from_stop and vv.to_stop = s.to_stop;
grant select on v_lupa_segmentit to anon, authenticated;

-- uudet välit joka tunti lupasegmenttien jälkeen (funktio käsittelee vain puuttuvat), kaikki kerran viikossa
select cron.schedule('reittiviivat-tunti', '27 * * * *',
  replace((select command from cron.job where jobname='hfp-aggregate-2min'), 'functions/v1/hfp-segmentit', 'functions/v1/reittiviivat'));
select cron.schedule('reittiviivat-viikko', '50 3 * * 1',
  replace((select command from cron.job where jobname='hfp-aggregate-2min'), 'functions/v1/hfp-segmentit', 'functions/v1/reittiviivat?kaikki=1'));
