-- 042: Ennakkoarvio kohdistaa työalueen pysäkkiväleihin katuviivaa pitkin, kuten tilannekuva (014, 017).
-- Löydös 5.11.2026: ennakkoarvio käytti yhä suoraa janaa pysäkiltä toiselle. Pitkät välit (pysäkkejä välistä puuttuu)
-- vetivät kartalle kilometrien mittaisia viivoja korttelien yli, esim. Kanervakuja 3 (Tapanila).
-- Nyt: ehdokkaat suoran janan perusteella väljällä 150 m rajalla, ratkaisu katuviivan osajanoista (< 40 m).
-- Suoraa janaa käytetään varalla vain alle 300 m väleillä, joilta katuviiva puuttuu.
create or replace function ennakko_valit(pts jsonb)
returns table (from_stop int, to_stop int, route text, dir smallint, mode text, jakso text, ohit_vrk real,
               from_nimi text, to_nimi text, from_lat float8, from_lon float8, to_lat float8, to_lon float8, viiva jsonb)
language sql stable security definer set search_path = public as $$
  with p as (select (e->>0)::float8 lat, (e->>1)::float8 lon from (select e from jsonb_array_elements(pts) e limit 400) z),
  bb as (select min(lat)-0.004 la0, max(lat)+0.004 la1, min(lon)-0.008 lo0, max(lon)+0.008 lo1 from p),
  ps as (select s.stop, s.lat, s.lon from pysakit s, bb where s.lat between la0 and la1 and s.lon between lo0 and lo1),
  pari as (select distinct k.from_stop, k.to_stop, a.lat alat, a.lon alon, b.lat blat, b.lon blon,
                  etaisyys_m(a.lat, a.lon, b.lat, b.lon, b.lat, b.lon) pituus
           from vali_kuormitus k join ps a on a.stop = k.from_stop join pysakit b on b.stop = k.to_stop
           where abs(a.lat-b.lat) < 0.02 and abs(a.lon-b.lon) < 0.04),
  ehd as (select pr.* from pari pr
          where exists (select 1 from p where etaisyys_m(p.lat, p.lon, pr.alat, pr.alon, pr.blat, pr.blon) < 150)),
  jana as (select vv.from_stop, vv.to_stop, (a.v->>0)::float8 alat, (a.v->>1)::float8 alon, (b.v->>0)::float8 blat, (b.v->>1)::float8 blon
           from vali_viiva vv join ehd e on e.from_stop = vv.from_stop and e.to_stop = vv.to_stop
           cross join lateral jsonb_array_elements(vv.coords) with ordinality a(v, i)
           cross join lateral (select vv.coords->(a.i::int) v) b
           where jsonb_array_length(vv.coords) > 1 and a.i < jsonb_array_length(vv.coords)),
  osuu as (select e.* from ehd e
           where exists (select 1 from jana j, p where j.from_stop = e.from_stop and j.to_stop = e.to_stop
                           and etaisyys_m(p.lat, p.lon, j.alat, j.alon, j.blat, j.blon) < 40)
              or (not exists (select 1 from jana j where j.from_stop = e.from_stop and j.to_stop = e.to_stop)
                  and e.pituus < 300
                  and exists (select 1 from p where etaisyys_m(p.lat, p.lon, e.alat, e.alon, e.blat, e.blon) < 40)))
  select k.from_stop, k.to_stop, k.route, k.dir, k.mode, k.jakso, k.ohit_vrk,
    na.nimi, nb.nimi, o.alat, o.alon, o.blat, o.blon, vv.coords
  from osuu o join vali_kuormitus k on k.from_stop = o.from_stop and k.to_stop = o.to_stop
  left join pysakki_nimet na on na.stop = o.from_stop left join pysakki_nimet nb on nb.stop = o.to_stop
  left join vali_viiva vv on vv.from_stop = o.from_stop and vv.to_stop = o.to_stop;
$$;
grant execute on function ennakko_valit(jsonb) to anon, authenticated;
