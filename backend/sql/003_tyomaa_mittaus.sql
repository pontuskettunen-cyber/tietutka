-- Työmaatutka 003: työmaakohtainen mittaus
-- Idea: jokaiselle seurattavalle luvalle haetaan pysäkkivälit, jotka kulkevat lupa-alueen ohi.
-- Niiden ajoaikaa verrataan perustasoon (sama pysäkkiväli, linja, suunta, kellonaikaikkuna ja päivätyyppi
-- ennen työn alkua). Vertailualue normalisoi yleisen ruuhka- ja sääpoikkeaman pois.

-- 1) Seuranta-alueiden luvat
update seuranta_alueet set lupa_id = v.l from (values
  ('60;24/19/82','KP2603149'),('60;24/19/92','KP2603151'),('60;24/19/64','KP2603126'),
  ('60;24/19/63','KP2603129'),('60;24/19/65','LJ2600150')) v(c,l)
where cell = v.c;

-- 2) Pysäkkien sijainnit (lähtötapahtumien mediaanisijainti, päivitetään cronilla)
create table if not exists pysakit (
  stop integer primary key, lat double precision, lon double precision, n integer, paivitetty timestamptz default now());
alter table pysakit enable row level security;

create index if not exists segment_2h_pari_idx on segment_2h (from_stop, to_stop);
create index if not exists hfp_events_stop_idx on hfp_events (stop) where upper(event)='DEP';

-- 3) Etäisyys pisteestä janaan metreinä (tasoprojektio riittää kaupunkimittakaavassa)
create or replace function etaisyys_janaan(plat float8, plon float8, alat float8, alon float8, blat float8, blon float8)
returns float8 language sql immutable as $$
  with k as (select cos(radians(plat))*111320.0 kx, 110540.0 ky),
  p as (select (alon-plon)*kx ax, (alat-plat)*ky ay, (blon-plon)*kx bx, (blat-plat)*ky by_ from k),
  t as (select ax, ay, bx-ax dx, by_-ay dy from p),
  u as (select ax, ay, dx, dy, case when dx*dx+dy*dy=0 then 0 else greatest(0, least(1, -(ax*dx+ay*dy)/(dx*dx+dy*dy))) end s from t)
  select sqrt((ax+s*dx)^2 + (ay+s*dy)^2) from u
$$;

-- 4) Työmaan pysäkkivälit, tila ja aikasarja
create table if not exists tyomaa_segmentit (
  cell text, from_stop integer, to_stop integer, etaisyys_m real,
  primary key (cell, from_stop, to_stop));
create table if not exists tyomaa_tila (
  cell text primary key, alkaa timestamptz, paattyy timestamptz,
  segmentteja int, linjat text[], perustaso_havainnot int, perustaso_ikkunat int,
  ohitukset_24h int, indeksi_24h real, viive_s_24h real, verrokki_indeksi_24h real,
  ohitukset_vrk_ka real, paivitetty timestamptz);
create table if not exists tyomaa_sarja (
  cell text, bucket timestamptz, n int, indeksi real, primary key (cell, bucket));
create table if not exists tyomaa_segmentti_tila (
  cell text, from_stop integer, to_stop integer, linjat text[], n_24h int, indeksi_24h real,
  primary key (cell, from_stop, to_stop));
alter table tyomaa_segmentit enable row level security;
alter table tyomaa_tila enable row level security;
alter table tyomaa_sarja enable row level security;
alter table tyomaa_segmentti_tila enable row level security;

create or replace function paivita_tyomaat() returns text
language plpgsql security definer set search_path = public as $$
declare
  v_snap date := (select max(snap_date) from luvat_snapshot);
  v_vertailu_alku timestamptz;
begin
  -- pysäkit
  insert into pysakit (stop, lat, lon, n, paivitetty)
  select stop, percentile_cont(0.5) within group (order by lat), percentile_cont(0.5) within group (order by lon), count(*), now()
  from hfp_events where upper(event)='DEP' and stop is not null and lat is not null group by stop
  on conflict (stop) do update set lat=excluded.lat, lon=excluded.lon, n=excluded.n, paivitetty=now();

  -- työmaiden pysäkkivälit: jana kulkee alle 60 m päästä lupa-alueen kärkipisteestä
  delete from tyomaa_segmentit;
  insert into tyomaa_segmentit (cell, from_stop, to_stop, etaisyys_m)
  select a.cell, s.from_stop, s.to_stop, min(etaisyys_janaan(v.lat, v.lon, pa.lat, pa.lon, pb.lat, pb.lon))
  from seuranta_alueet a
  join luvat_snapshot l on l.lupa_id = a.lupa_id and l.snap_date = v_snap
  cross join lateral (select (m[2])::float8 lat, (m[1])::float8 lon
                      from regexp_matches(l.geom->>'coordinates' , '\[(-?\d+\.\d+),\s*(-?\d+\.\d+)\]', 'g') m) v
  join (select distinct from_stop, to_stop from segment_2h) s on true
  join pysakit pa on pa.stop = s.from_stop
  join pysakit pb on pb.stop = s.to_stop
  where a.rooli = 'tyomaa'
    and abs(pa.lat - v.lat) < 0.01 and abs(pa.lon - v.lon) < 0.02
    and etaisyys_janaan(v.lat, v.lon, pa.lat, pa.lon, pb.lat, pb.lon) < 60
  group by a.cell, s.from_stop, s.to_stop;

  -- vertailualue: pysäkkivälit, joiden molemmat päät ovat vertailusolussa
  insert into tyomaa_segmentit (cell, from_stop, to_stop, etaisyys_m)
  select a.cell, s.from_stop, s.to_stop, 0
  from seuranta_alueet a
  join (select distinct from_stop, to_stop from segment_2h) s on true
  join pysakit pa on pa.stop = s.from_stop
  join pysakit pb on pb.stop = s.to_stop
  where a.rooli = 'vertailu' and tt_cell(pa.lat, pa.lon) = a.cell and tt_cell(pb.lat, pb.lon) = a.cell
  on conflict do nothing;

  -- vertailualueen perustaso päättyy ensimmäisen työmaan alkaessa
  select min(l.alkaa) into v_vertailu_alku from seuranta_alueet a join luvat_snapshot l on l.lupa_id=a.lupa_id and l.snap_date=v_snap
  where a.rooli='tyomaa' and l.alkaa > now() - interval '60 days';

  -- havainnot + perustaso samasta kellonaikaikkunasta ja päivätyypistä
  create temp table _h on commit drop as
  with alueet as (
    select a.cell, a.rooli, coalesce(l.alkaa, v_vertailu_alku, now()) alkaa
    from seuranta_alueet a left join luvat_snapshot l on l.lupa_id=a.lupa_id and l.snap_date=v_snap
    where a.aktiivinen),
  h as (
    select al.cell, al.rooli, al.alkaa, g.bucket, g.from_stop, g.to_stop, g.route, g.dir, g.n, g.sum_tt,
      extract(hour from g.bucket)::int slot,
      case when extract(isodow from g.bucket at time zone 'Europe/Helsinki') in (6,7) then 'vl' else 'ark' end paiva
    from alueet al join tyomaa_segmentit ts on ts.cell=al.cell
    join segment_2h g on g.from_stop=ts.from_stop and g.to_stop=ts.to_stop),
  b as (
    select cell, from_stop, to_stop, route, dir, slot, paiva, sum(sum_tt)::float8/sum(n) base, sum(n) bn
    from h where bucket < alkaa group by 1,2,3,4,5,6,7)
  select h.*, b.base from h left join b using (cell, from_stop, to_stop, route, dir, slot, paiva);

  delete from tyomaa_sarja;
  insert into tyomaa_sarja (cell, bucket, n, indeksi)
  select cell, bucket, sum(n), sum(sum_tt)::float8/nullif(sum(n*base),0)
  from _h where base is not null and bucket > now() - interval '14 days' group by cell, bucket;

  delete from tyomaa_segmentti_tila;
  insert into tyomaa_segmentti_tila (cell, from_stop, to_stop, linjat, n_24h, indeksi_24h)
  select ts.cell, ts.from_stop, ts.to_stop,
    (select array_agg(distinct route order by route) from _h x where x.cell=ts.cell and x.from_stop=ts.from_stop and x.to_stop=ts.to_stop),
    coalesce(sum(h.n) filter (where h.bucket > now()-interval '24 hours'),0),
    sum(h.sum_tt) filter (where h.bucket > now()-interval '24 hours' and h.base is not null)
      / nullif(sum(h.n*h.base) filter (where h.bucket > now()-interval '24 hours' and h.base is not null),0)
  from tyomaa_segmentit ts left join _h h on h.cell=ts.cell and h.from_stop=ts.from_stop and h.to_stop=ts.to_stop
  group by ts.cell, ts.from_stop, ts.to_stop;

  delete from tyomaa_tila;
  insert into tyomaa_tila
  select a.cell, l.alkaa, l.paattyy,
    (select count(*) from tyomaa_segmentit s where s.cell=a.cell),
    (select array_agg(distinct route order by route) from _h x where x.cell=a.cell),
    (select coalesce(sum(n),0) from _h x where x.cell=a.cell and x.bucket < x.alkaa),
    (select count(distinct (slot, paiva)) from _h x where x.cell=a.cell and x.bucket < x.alkaa),
    (select coalesce(sum(n),0) from _h x where x.cell=a.cell and x.bucket > now()-interval '24 hours'),
    (select sum(sum_tt)/nullif(sum(n*base),0) from _h x where x.cell=a.cell and x.base is not null and x.bucket > now()-interval '24 hours'),
    (select sum(sum_tt - n*base) from _h x where x.cell=a.cell and x.base is not null and x.bucket > now()-interval '24 hours'),
    null,
    (select sum(n)::real / greatest(1, extract(epoch from (max(bucket)-min(bucket)+interval '2 hours'))/86400) from _h x where x.cell=a.cell),
    now()
  from seuranta_alueet a left join luvat_snapshot l on l.lupa_id=a.lupa_id and l.snap_date=v_snap
  where a.aktiivinen;
  update tyomaa_tila set verrokki_indeksi_24h = (select t.indeksi_24h from tyomaa_tila t join seuranta_alueet a using (cell) where a.rooli='vertailu' limit 1);

  return 'segmentteja '||(select count(*) from tyomaa_segmentit)||', pysakkeja '||(select count(*) from pysakit);
end $$;
revoke execute on function paivita_tyomaat() from public, anon, authenticated;

-- 5) Julkiset näkymät
create or replace view v_tyomaat with (security_invoker = false) as
select a.cell, a.nimi, a.rooli, a.lupa_id, l.osoite, l.tarkoitus, l.kaupunginosa, l.layer,
  t.alkaa, t.paattyy, t.segmentteja, t.linjat, t.perustaso_havainnot, t.perustaso_ikkunat,
  t.ohitukset_24h, t.indeksi_24h, t.viive_s_24h, t.verrokki_indeksi_24h, t.ohitukset_vrk_ka, t.paivitetty,
  l.geom
from seuranta_alueet a
left join tyomaa_tila t using (cell)
left join luvat_snapshot l on l.lupa_id=a.lupa_id and l.snap_date=(select max(snap_date) from luvat_snapshot)
where a.aktiivinen;

create or replace view v_tyomaa_sarja with (security_invoker = false) as
select cell, bucket, n, indeksi from tyomaa_sarja;

create or replace view v_tyomaa_segmentit with (security_invoker = false) as
select s.cell, s.from_stop, s.to_stop, pa.lat from_lat, pa.lon from_lon, pb.lat to_lat, pb.lon to_lon,
  s.linjat, s.n_24h, s.indeksi_24h
from tyomaa_segmentti_tila s join pysakit pa on pa.stop=s.from_stop join pysakit pb on pb.stop=s.to_stop;

grant select on v_tyomaat, v_tyomaa_sarja, v_tyomaa_segmentit to anon, authenticated;

select cron.schedule('tyomaat-10min', '*/10 * * * *', $$select paivita_tyomaat()$$);
select paivita_tyomaat();
