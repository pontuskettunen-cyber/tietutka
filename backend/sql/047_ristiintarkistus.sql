-- Tietutka 047: ristiintarkistuksen korjaukset (11.11.2026)
-- 1) Lupakohtaiset luvut (lupa_tila) samalla periaatteella kuin v_luvat (046): jokaiselta tasolta sen oma uusin tilannekuva
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
    join luvat_snapshot l on l.lupa_id = ls.lupa_id and (l.layer, l.snap_date) in (select layer, max(snap_date) from luvat_snapshot where snap_date > current_date - 7 group by layer)
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

-- 2) Osoitekohtainen raja: asiakkaan IP on Cloudflaren otsakkeessa tai X-Forwarded-For-listan viimeisenä (ensimmäisen voi asiakas asettaa itse)
create or replace function tietutka_lahde() returns text language sql stable as $$
  select md5(coalesce(
    nullif(current_setting('request.headers', true), '')::json->>'cf-connecting-ip',
    nullif(trim(reverse(split_part(reverse(nullif(current_setting('request.headers', true), '')::json->>'x-forwarded-for'), ',', 1))), ''),
    'tuntematon') || 'tietutka')
$$;

-- 3) Pilottimittaus: välit 30 vrk ajalta, ettei kiertoreitin takia ajamatta jäänyt väli katoa (046 rajasi 2 vrk:een)
create or replace function paivita_tyomaat() returns text
language plpgsql security definer set search_path = public as $$
declare
  v_snap date := (select max(snap_date) from luvat_snapshot);
  v_vertailu_alku timestamptz;
begin
  -- pysäkit päivittää pysakit-kerays (hfp_events ei enää päivity, joten sitä ei käytetä)
  -- työmaiden pysäkkivälit: jana kulkee alle 60 m päästä lupa-alueen kärkipisteestä
  delete from tyomaa_segmentit;
  insert into tyomaa_segmentit (cell, from_stop, to_stop, etaisyys_m)
  select a.cell, s.from_stop, s.to_stop, min(etaisyys_janaan(v.lat, v.lon, pa.lat, pa.lon, pb.lat, pb.lon))
  from seuranta_alueet a
  join luvat_snapshot l on l.lupa_id = a.lupa_id and l.snap_date = v_snap
  cross join lateral (select (m[2])::float8 lat, (m[1])::float8 lon
                      from regexp_matches(l.geom->>'coordinates' , '\[(-?\d+\.\d+),\s*(-?\d+\.\d+)\]', 'g') m) v
  join (select distinct from_stop, to_stop from segment_2h where bucket > now() - interval '30 days') s on true
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
  join (select distinct from_stop, to_stop from segment_2h where bucket > now() - interval '30 days') s on true
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
