-- Työmaatutka 004: mittaus kaikille Helsingin voimassa oleville ja alkaville luville.
-- Kaksi mittaria:
--  (a) ennen/jälkeen: ajoaika verrattuna perustasoon ennen työn alkua (alkavat työt)
--  (b) aikataulusta jääminen: paljonko ajoneuvo jää aikataulusta työmaan pysäkkiväleillä
--      verrattuna saman linjan muihin pysäkkiväleihin samassa kahden tunnin ikkunassa
--      (toimii myös jo käynnissä oleville töille)

-- 1) Aikataulupoikkeaman muutos pysäkkivälillä (HFP dl: negatiivinen = myöhässä)
alter table segment_2h add column if not exists sum_ddl double precision not null default 0;
alter table segment_2h add column if not exists n_ddl integer not null default 0;

create or replace function seg_add2(rows jsonb) returns void
language sql security definer set search_path = public as $$
  insert into segment_2h as s (bucket, from_stop, to_stop, route, dir, mode, n, sum_tt, sum_tt2, min_tt, max_tt, sum_ddl, n_ddl)
  select bucket, from_stop, to_stop, route, dir, mode, n, sum_tt, sum_tt2, min_tt, max_tt, coalesce(sum_ddl,0), coalesce(n_ddl,0)
  from jsonb_to_recordset(rows) as r(bucket timestamptz, from_stop int, to_stop int, route text, dir smallint, mode text,
       n int, sum_tt float8, sum_tt2 float8, min_tt float8, max_tt float8, sum_ddl float8, n_ddl int)
  on conflict (bucket, from_stop, to_stop, route, dir) do update set
    n = s.n + excluded.n, sum_tt = s.sum_tt + excluded.sum_tt, sum_tt2 = s.sum_tt2 + excluded.sum_tt2,
    min_tt = least(s.min_tt, excluded.min_tt), max_tt = greatest(s.max_tt, excluded.max_tt),
    sum_ddl = s.sum_ddl + excluded.sum_ddl, n_ddl = s.n_ddl + excluded.n_ddl;
$$;
revoke execute on function seg_add2(jsonb) from public, anon, authenticated;

-- 2) Luvan ja pysäkkivälin yhdistäminen
create table if not exists lupa_segmentit (
  lupa_id text, from_stop integer, to_stop integer, etaisyys_m real,
  primary key (lupa_id, from_stop, to_stop));
alter table lupa_segmentit enable row level security;

create or replace function paivita_lupasegmentit() returns text
language plpgsql security definer set search_path = public as $$
declare v_snap date := (select max(snap_date) from luvat_snapshot);
begin
  -- pysäkkiparit ruudukkoon (0,004°), avaimet päistä ja keskipisteestä
  create temp table _pari on commit drop as
  select p.from_stop, p.to_stop, pa.lat alat, pa.lon alon, pb.lat blat, pb.lon blon
  from (select distinct from_stop, to_stop from segment_2h) p
  join pysakit pa on pa.stop = p.from_stop join pysakit pb on pb.stop = p.to_stop
  where abs(pa.lat-pb.lat) < 0.02 and abs(pa.lon-pb.lon) < 0.04;
  create temp table _parikey on commit drop as
  select distinct from_stop, to_stop, floor(la/0.004)::int ky, floor(lo/0.004)::int kx
  from _pari, lateral (values (alat,alon),(blat,blon),((alat+blat)/2,(alon+blon)/2)) v(la,lo);
  create index on _parikey (ky, kx);

  -- lupien kärkipisteet
  create temp table _vert on commit drop as
  select l.lupa_id, (m[2])::float8 lat, (m[1])::float8 lon
  from luvat_snapshot l, regexp_matches(l.geom->>'coordinates', '\[(-?\d+\.\d+),\s*(-?\d+\.\d+)\]', 'g') m
  where l.snap_date = v_snap and (l.paattyy is null or l.paattyy >= now() - interval '1 day') and l.alkaa < now() + interval '60 days';

  delete from lupa_segmentit;
  insert into lupa_segmentit (lupa_id, from_stop, to_stop, etaisyys_m)
  select v.lupa_id, p.from_stop, p.to_stop, min(etaisyys_janaan(v.lat, v.lon, p.alat, p.alon, p.blat, p.blon))
  from _vert v
  join _parikey k on k.ky between floor(v.lat/0.004)::int-1 and floor(v.lat/0.004)::int+1
                 and k.kx between floor(v.lon/0.004)::int-1 and floor(v.lon/0.004)::int+1
  join _pari p on p.from_stop = k.from_stop and p.to_stop = k.to_stop
  where etaisyys_janaan(v.lat, v.lon, p.alat, p.alon, p.blat, p.blon) < 40
  group by v.lupa_id, p.from_stop, p.to_stop;

  return 'lupia '||(select count(distinct lupa_id) from lupa_segmentit)||', pareja '||(select count(*) from lupa_segmentit);
end $$;
revoke execute on function paivita_lupasegmentit() from public, anon, authenticated;

-- 3) Mittarit luvittain
create table if not exists lupa_tila (
  lupa_id text primary key, segmentteja int, linjat text[], ohitukset_24h int, ajoja_vrk real,
  lisaviive_s real, ajoneuvotunnit_24h real, indeksi_24h real, perustaso_havainnot int, perustaso_ikkunat int,
  paivitetty timestamptz);
create table if not exists lupa_linjat (
  lupa_id text, route text, dir smallint, ohitukset_24h int, lisaviive_s real, primary key (lupa_id, route, dir));
create table if not exists lupa_sarja (
  lupa_id text, bucket timestamptz, n int, lisaviive_s real, indeksi real, primary key (lupa_id, bucket));
create table if not exists lupa_segmentti_tila (
  lupa_id text, from_stop int, to_stop int, linjat text[], n_24h int, lisaviive_s real, indeksi_24h real,
  primary key (lupa_id, from_stop, to_stop));
alter table lupa_tila enable row level security;
alter table lupa_linjat enable row level security;
alter table lupa_sarja enable row level security;
alter table lupa_segmentti_tila enable row level security;

create or replace function paivita_luvat() returns text
language plpgsql security definer set search_path = public as $$
declare v_snap date := (select max(snap_date) from luvat_snapshot);
begin
  -- saman linjan tyypillinen aikataulusta jääminen pysäkkivälillä (koko verkko, sama 2 h ikkuna)
  create temp table _ref on commit drop as
  select bucket, route, dir, sum(sum_ddl)/nullif(sum(n_ddl),0) ref_ddl
  from segment_2h where bucket > now() - interval '14 days' and n_ddl > 0
    and route in (select distinct g.route from segment_2h g join lupa_segmentit ls using (from_stop, to_stop) where g.bucket > now() - interval '14 days')
  group by bucket, route, dir;

  create temp table _h on commit drop as
  with h as (
    select ls.lupa_id, l.alkaa, g.bucket, g.from_stop, g.to_stop, g.route, g.dir, g.n, g.sum_tt, g.sum_ddl, g.n_ddl,
      extract(hour from g.bucket)::int slot,
      case when extract(isodow from g.bucket at time zone 'Europe/Helsinki') in (6,7) then 'vl' else 'ark' end paiva
    from lupa_segmentit ls
    join luvat_snapshot l on l.lupa_id = ls.lupa_id and l.snap_date = v_snap
    join segment_2h g on g.from_stop = ls.from_stop and g.to_stop = ls.to_stop
    where g.bucket > now() - interval '14 days'),
  b as (
    select lupa_id, from_stop, to_stop, route, dir, slot, paiva, sum(sum_tt)::float8/sum(n) base
    from h where bucket < alkaa group by 1,2,3,4,5,6,7)
  select h.*, b.base, r.ref_ddl,
    -- lisäviive: tällä välillä menetetty aika miinus linjan tyypillinen per pysäkkiväli (s/ohitus, summana)
    case when h.n_ddl > 0 and r.ref_ddl is not null then (-h.sum_ddl) - h.n_ddl * (-r.ref_ddl) end lisa_sum
  from h left join b using (lupa_id, from_stop, to_stop, route, dir, slot, paiva)
  left join _ref r on r.bucket = h.bucket and r.route = h.route and r.dir = h.dir;
  create index on _h (lupa_id);

  -- linjoittain: lisäviive koko työmaan läpi = summa pysäkkiväleistä (s / ohitus)
  delete from lupa_linjat;
  insert into lupa_linjat (lupa_id, route, dir, ohitukset_24h, lisaviive_s)
  select lupa_id, route, dir, max(n24), sum(lisa24)
  from (select lupa_id, route, dir, from_stop, to_stop,
          sum(n) filter (where bucket > now()-interval '24 hours') n24,
          sum(lisa_sum) filter (where bucket > now()-interval '24 hours') / nullif(sum(n_ddl) filter (where bucket > now()-interval '24 hours' and lisa_sum is not null),0) lisa24
        from _h group by 1,2,3,4,5) x
  where n24 > 0
  group by lupa_id, route, dir;

  delete from lupa_tila;
  insert into lupa_tila
  select l.lupa_id,
    (select count(*) from lupa_segmentit s where s.lupa_id = l.lupa_id),
    (select array_agg(distinct route order by route) from _h x where x.lupa_id = l.lupa_id),
    (select sum(ohitukset_24h) from lupa_linjat x where x.lupa_id = l.lupa_id),
    (select max(d) from (select sum(n)::real / greatest(1, extract(epoch from (max(bucket)-min(bucket)+interval '2 hours'))/86400) d
                         from _h x where x.lupa_id = l.lupa_id group by from_stop, to_stop) q),
    (select sum(ohitukset_24h*lisaviive_s)/nullif(sum(ohitukset_24h) filter (where lisaviive_s is not null),0) from lupa_linjat x where x.lupa_id = l.lupa_id and lisaviive_s is not null),
    (select sum(ohitukset_24h*lisaviive_s)/3600 from lupa_linjat x where x.lupa_id = l.lupa_id and lisaviive_s is not null),
    (select sum(sum_tt)/nullif(sum(n*base),0) from _h x where x.lupa_id = l.lupa_id and x.base is not null and x.bucket >= x.alkaa and x.bucket > now()-interval '24 hours'),
    (select coalesce(sum(n),0) from _h x where x.lupa_id = l.lupa_id and x.bucket < x.alkaa),
    (select count(distinct (slot, paiva)) from _h x where x.lupa_id = l.lupa_id and x.bucket < x.alkaa),
    now()
  from (select distinct lupa_id from lupa_segmentit) l;

  delete from lupa_sarja;
  insert into lupa_sarja (lupa_id, bucket, n, lisaviive_s, indeksi)
  select coalesce(a.lupa_id, i.lupa_id), coalesce(a.bucket, i.bucket), coalesce(a.n, i.n), a.lisa, i.indeksi
  from (
    -- linjan lisäviive työmaan läpi = pysäkkivälien keskiarvojen summa; painotetaan linjojen ohituksilla
    select lupa_id, bucket, sum(n_r) n, sum(n_r*lisa_r)/nullif(sum(n_r),0) lisa
    from (select lupa_id, bucket, route, dir, max(n) n_r, sum(lisa_sum/nullif(n_ddl,0)) lisa_r
          from _h where lisa_sum is not null group by 1,2,3,4) r
    group by lupa_id, bucket) a
  full join (
    select lupa_id, bucket, sum(n) n, sum(sum_tt)/nullif(sum(n*base),0) indeksi
    from _h where base is not null group by lupa_id, bucket) i
  on i.lupa_id = a.lupa_id and i.bucket = a.bucket;

  delete from lupa_segmentti_tila;
  insert into lupa_segmentti_tila
  select ls.lupa_id, ls.from_stop, ls.to_stop,
    (select array_agg(distinct route order by route) from _h x where x.lupa_id=ls.lupa_id and x.from_stop=ls.from_stop and x.to_stop=ls.to_stop),
    coalesce(sum(h.n) filter (where h.bucket > now()-interval '24 hours'),0),
    sum(h.lisa_sum) filter (where h.bucket > now()-interval '24 hours') / nullif(sum(h.n_ddl) filter (where h.bucket > now()-interval '24 hours' and h.lisa_sum is not null),0),
    sum(h.sum_tt) filter (where h.bucket > now()-interval '24 hours' and h.base is not null and h.bucket >= h.alkaa)
      / nullif(sum(h.n*h.base) filter (where h.bucket > now()-interval '24 hours' and h.base is not null and h.bucket >= h.alkaa),0)
  from lupa_segmentit ls left join _h h on h.lupa_id=ls.lupa_id and h.from_stop=ls.from_stop and h.to_stop=ls.to_stop
  group by ls.lupa_id, ls.from_stop, ls.to_stop;

  return 'lupia mitattu '||(select count(*) from lupa_tila)||', linjarivejä '||(select count(*) from lupa_linjat);
end $$;
revoke execute on function paivita_luvat() from public, anon, authenticated;

-- 4) Julkiset näkymät (vain avointa lupadataa ja koostettuja mittareita; hakijatietoja ei ole tallennettu)
create or replace view v_luvat with (security_invoker = false) as
select l.lupa_id, l.layer, l.osoite, l.tarkoitus, l.kaupunginosa, l.status, l.alkaa, l.paattyy,
  t.segmentteja, t.linjat, t.ohitukset_24h, t.ajoja_vrk, t.lisaviive_s, t.ajoneuvotunnit_24h,
  t.indeksi_24h, t.perustaso_havainnot, t.perustaso_ikkunat, t.paivitetty,
  (select a.cell from seuranta_alueet a where a.lupa_id = l.lupa_id limit 1) pilotti_cell,
  l.geom
from luvat_snapshot l left join lupa_tila t using (lupa_id)
where l.snap_date = (select max(snap_date) from luvat_snapshot)
  and (l.paattyy is null or l.paattyy >= now() - interval '1 day') and l.alkaa < now() + interval '60 days';

create or replace view v_lupa_linjat with (security_invoker = false) as select * from lupa_linjat;
create or replace view v_lupa_sarja with (security_invoker = false) as select * from lupa_sarja;
create or replace view v_lupa_segmentit with (security_invoker = false) as
select s.lupa_id, s.from_stop, s.to_stop, pa.lat from_lat, pa.lon from_lon, pb.lat to_lat, pb.lon to_lon,
  s.linjat, s.n_24h, s.lisaviive_s, s.indeksi_24h
from lupa_segmentti_tila s join pysakit pa on pa.stop = s.from_stop join pysakit pb on pb.stop = s.to_stop;
grant select on v_luvat, v_lupa_linjat, v_lupa_sarja, v_lupa_segmentit to anon, authenticated;

select cron.schedule('lupasegmentit-tunti', '20 * * * *', $$select paivita_lupasegmentit()$$);
select cron.schedule('luvat-10min', '3,13,23,33,43,53 * * * *', $$select paivita_luvat()$$);
select paivita_lupasegmentit();
select paivita_luvat();
