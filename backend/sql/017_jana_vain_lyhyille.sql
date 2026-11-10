-- 017: suoran janan varakäyttö vain alle 300 m pysäkkiväleillä.
-- Löydös 2.11.2026: 531 lupa–väli-liitosta perustui yli 400 m pitkän välin suoraan janaan, koska välin katuviiva puuttui.
-- Esim. Karamzininranta (Töölönlahden puisto) liitettiin linjaan 300 välillä Elielinaukio → Mannerheimintie, vaikka reitti kulkee 117 m päässä.
create or replace function paivita_lupasegmentit() returns text
language plpgsql security definer set search_path = public as $$
begin
  create temp table _pari on commit drop as
  select p.from_stop, p.to_stop, pa.lat alat, pa.lon alon, pb.lat blat, pb.lon blon
  from (select distinct from_stop, to_stop from segment_2h where bucket > now() - interval '7 days') p
  join pysakit pa on pa.stop = p.from_stop join pysakit pb on pb.stop = p.to_stop
  where abs(pa.lat-pb.lat) < 0.02 and abs(pa.lon-pb.lon) < 0.04;
  -- rajauslaatikko (+~150 m) ja GiST-indeksi: piste löytää vain ne välit, joiden laatikkoon se osuu
  alter table _pari add column bx box;
  -- suoran janan varakäyttö vain lyhyillä väleillä (alle 300 m): pitkällä välillä jana oikaisee korttelien ja puistojen yli
  alter table _pari add column pituus float8;
  update _pari set pituus = etaisyys_m(alat, alon, blat, blon, blat, blon);
  update _pari set bx = box(point(least(alon,blon)-0.0028, least(alat,blat)-0.0014), point(greatest(alon,blon)+0.0028, greatest(alat,blat)+0.0014));
  create index on _pari using gist (bx);
  analyze _pari;

  create temp table _lupa on commit drop as
  select distinct on (lupa_id) lupa_id, geom, alkaa, paattyy
  from luvat_snapshot where snap_date > current_date - 45
  order by lupa_id, snap_date desc;

  create temp table _vert on commit drop as
  select distinct l.lupa_id, (m[2])::float8 lat, (m[1])::float8 lon
  from _lupa l, regexp_matches(l.geom->>'coordinates', '\[(-?\d+\.\d+),\s*(-?\d+\.\d+)\]', 'g') m
  where (l.paattyy is null or l.paattyy >= now() - interval '14 days') and l.alkaa < now() + interval '60 days';

  -- 1) ehdokkaat kuten ennen, mutta väljällä rajalla suoraan janaan (katu voi kaartaa janasta sivuun)
  create temp table _ehd on commit drop as
  select v.lupa_id, v.lat, v.lon, p.from_stop, p.to_stop, etaisyys_m(v.lat, v.lon, p.alat, p.alon, p.blat, p.blon) d_jana
  from _vert v
  join _pari p on p.bx @> point(v.lon, v.lat)
  where etaisyys_m(v.lat, v.lon, p.alat, p.alon, p.blat, p.blon) < 150;

  -- 2) katuviivan osajanat vain ehdokkaiden pysäkkiväleille
  create temp table _jana on commit drop as
  select vv.from_stop, vv.to_stop, (a.v->>0)::float8 alat, (a.v->>1)::float8 alon, (b.v->>0)::float8 blat, (b.v->>1)::float8 blon
  from vali_viiva vv
  join (select distinct from_stop, to_stop from _ehd) e on e.from_stop = vv.from_stop and e.to_stop = vv.to_stop
  cross join lateral jsonb_array_elements(vv.coords) with ordinality a(v, i)
  cross join lateral (select vv.coords->(a.i::int) v) b
  where jsonb_array_length(vv.coords) > 1 and a.i < jsonb_array_length(vv.coords);
  create index on _jana (from_stop, to_stop);

  -- 3) etäisyys: katuviivasta jos se on, muuten suorasta janasta
  delete from lupa_segmentit;
  insert into lupa_segmentit (lupa_id, from_stop, to_stop, etaisyys_m)
  select lupa_id, from_stop, to_stop, min(d) from (
    select e.lupa_id, e.from_stop, e.to_stop,
      coalesce((select min(etaisyys_m(e.lat, e.lon, j.alat, j.alon, j.blat, j.blon)) from _jana j where j.from_stop = e.from_stop and j.to_stop = e.to_stop),
               case when p.pituus < 300 then e.d_jana end) d
    from _ehd e join _pari p on p.from_stop = e.from_stop and p.to_stop = e.to_stop) x
  where d < 40
  group by lupa_id, from_stop, to_stop;

  return 'lupia '||(select count(distinct lupa_id) from lupa_segmentit)||', pareja '||(select count(*) from lupa_segmentit);
end $$;
revoke execute on function paivita_lupasegmentit() from public, anon, authenticated;
