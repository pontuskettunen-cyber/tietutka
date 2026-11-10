-- Tietutka 046: katselmuksen korjaukset (11.11.2026)
-- 1) Liikennehälytys: etumerkki. HFP:n dl on negatiivinen kun auto on myöhässä, joten ajassa menetetty aika = -ddl.
--    Aiemmin "Työmaa hidastaa" laukesi, kun bussit olivat tavallista NOPEAMPIA.
create or replace function liik_pohja_paivita() returns int
language plpgsql security definer set search_path = public as $$
begin
  delete from liik_pohja;
  insert into liik_pohja (lupa_id, hh, n, ka, sd)
  select lupa_id, hh, sum(n), sum(s) / sum(n), sqrt(greatest(sum(s2) / sum(n) - power(sum(s) / sum(n), 2), 1))
  from (select ls.lupa_id, extract(hour from h.t at time zone 'Europe/Helsinki')::int hh, count(*) n, sum(-h.ddl) s, sum(h.ddl * h.ddl) s2
        from lupa_segmentit ls join seg_havainto h on h.from_stop = ls.from_stop and h.to_stop = ls.to_stop
        where h.t > now() - interval '14 days' and h.t < now() - interval '1 hour' and h.ddl is not null and abs(h.ddl) < 900
        group by 1, 2) x
  group by 1, 2 having sum(n) >= 30;
  return (select count(*) from liik_pohja);
end $$;

create or replace function liik_havainnot() returns table (lupa_id text, n int, nyt real, pohja real, z real, ero real)
language sql stable security definer set search_path = public as $$
  select p.lupa_id, x.n, x.ka, p.ka, ((x.ka - p.ka) / (p.sd / sqrt(x.n)))::real, (x.ka - p.ka)::real
  from (select ls.lupa_id, count(*)::int n, avg(-h.ddl)::real ka
        from lupa_segmentit ls join seg_havainto h on h.from_stop = ls.from_stop and h.to_stop = ls.to_stop
        where h.t > now() - interval '60 minutes' and h.ddl is not null and abs(h.ddl) < 900 group by 1) x
  join liik_pohja p on p.lupa_id = x.lupa_id and p.hh = extract(hour from now() at time zone 'Europe/Helsinki')::int
  where x.n >= 4;
$$;
revoke all on function liik_pohja_paivita(), liik_havainnot() from public, anon, authenticated;
select liik_pohja_paivita();

-- 2) Ennakkoarvion vuorokaudenjaksot myös kesäaikana. 2 h koosteet alkavat UTC:n parillisina tunteina, jolloin kesäaikana
--    Helsingin tunnit ovat parittomia ja kaikki menivät jaksoon 'muu'. Luokitellaan tuntivälin mukaan.
create or replace function paivita_kuormitus() returns text
language plpgsql security definer set search_path = public as $$
begin
  create temp table _b on commit drop as
  select s.*, case when h between 6 and 9 then 'aamu' when h between 10 and 13 then 'paiva' when h between 14 and 17 then 'ilta' else 'muu' end jakso
  from (select s.*, extract(hour from s.bucket at time zone 'Europe/Helsinki')::int h from segment_2h s
        where s.bucket > now() - interval '8 days' and s.bucket < now() - interval '2 hours'
          and extract(isodow from s.bucket at time zone 'Europe/Helsinki') < 6) s;
  create temp table _bn on commit drop as
  select jakso, count(distinct bucket) b from _b group by jakso;

  delete from vali_kuormitus;
  insert into vali_kuormitus
  select x.from_stop, x.to_stop, x.route, x.dir, max(x.mode), x.jakso,
    sum(x.n)::real / bn.b * case x.jakso when 'aamu' then 2 when 'paiva' then 2 when 'ilta' then 2 else 6 end
  from _b x join _bn bn using (jakso)
  group by x.from_stop, x.to_stop, x.route, x.dir, x.jakso, bn.b;
  return 'rivejä '||(select count(*) from vali_kuormitus);
end $$;
revoke execute on function paivita_kuormitus() from public, anon, authenticated;
select paivita_kuormitus();

-- 3) Ennakkoarvio löytää myös pitkät pysäkkivälit: ehdokkaaksi kelpaa väli, jonka rajauslaatikko osuu työalueeseen
--    (aiemmin vain lähtöpysäkin piti olla lähellä, jolloin yli ~450 m välit putosivat pois).
create or replace function ennakko_valit(pts jsonb)
returns table (from_stop int, to_stop int, route text, dir smallint, mode text, jakso text, ohit_vrk real,
               from_nimi text, to_nimi text, from_lat float8, from_lon float8, to_lat float8, to_lon float8, viiva jsonb)
language sql stable security definer set search_path = public as $$
  with p as (select (e->>0)::float8 lat, (e->>1)::float8 lon from (select e from jsonb_array_elements(pts) e limit 400) z),
  bb as (select min(lat)-0.0015 la0, max(lat)+0.0015 la1, min(lon)-0.003 lo0, max(lon)+0.003 lo1 from p),
  ps as (select s.stop, s.lat, s.lon from pysakit s, bb where s.lat between la0 - 0.02 and la1 + 0.02 and s.lon between lo0 - 0.04 and lo1 + 0.04),
  pari as (select distinct k.from_stop, k.to_stop, a.lat alat, a.lon alon, b.lat blat, b.lon blon,
                  etaisyys_m(a.lat, a.lon, b.lat, b.lon, b.lat, b.lon) pituus
           from vali_kuormitus k join ps a on a.stop = k.from_stop join ps b on b.stop = k.to_stop, bb
           where abs(a.lat-b.lat) < 0.02 and abs(a.lon-b.lon) < 0.04
             and least(a.lat,b.lat) <= bb.la1 and greatest(a.lat,b.lat) >= bb.la0
             and least(a.lon,b.lon) <= bb.lo1 and greatest(a.lon,b.lon) >= bb.lo0),
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

-- 4) Linjan vuoroluvut (mediaani, huonoin 10 %) ja linjanauha vain voimassa olevien töiden kohdalta
create or replace function paivita_vuorot() returns text
language plpgsql security definer set search_path = public as $$
begin
  create temp table _r on commit drop as
  select bucket, route, dir, sum(sum_ddl_ajo)/nullif(sum(n_ajo),0) ref_ajo
  from segment_2h where bucket > now() - interval '9 days' and n_ajo > 0 group by 1,2,3;
  create index on _r (bucket, route, dir);

  -- pysäkkiväli -> luvat ja niiden voimassaolo. Havainto lasketaan työmaan lisäajaksi vain, jos jokin välin luvista
  -- oli havaintohetkellä voimassa (046): alkamattomien ja päättyneiden töiden välit ovat kadun tavallista hitautta.
  create temp table _pari on commit drop as
  select ls.from_stop, ls.to_stop, ls.lupa_id, ls.etaisyys_m, l.alkaa, coalesce(l.paattyy + interval '1 day', 'infinity'::timestamptz) loppu
  from lupa_segmentit ls
  join (select distinct on (lupa_id) lupa_id, alkaa, paattyy from luvat_snapshot where snap_date > current_date - 45
        order by lupa_id, snap_date desc) l using (lupa_id)
  where l.alkaa is not null;
  create index on _pari (from_stop, to_stop);

  create temp table _o on commit drop as
  select distinct on (h.vuoro, h.from_stop, h.to_stop)
    h.vuoro, h.route, h.dir, h.t, h.from_stop, h.to_stop, p.lupa_id, -(h.ddl_ajo - r.ref_ajo) lisa
  from seg_havainto h
  join _pari p on p.from_stop = h.from_stop and p.to_stop = h.to_stop and h.t >= p.alkaa and h.t < p.loppu
  join _r r on r.bucket = date_bin('2 hours', h.t, timestamptz '2000-01-01') and r.route = h.route and r.dir = h.dir
  where h.vuoro is not null and h.ddl_ajo is not null and abs(h.ddl_ajo) < 900 and h.t > now() - interval '8 days'
  order by h.vuoro, h.from_stop, h.to_stop, h.t, p.etaisyys_m;

  create temp table _v on commit drop as
  select vuoro, min(route) route, min(dir) dir, min(t) t0, count(*) valeja, sum(lisa) lisa_sum
  from _o group by vuoro;

  delete from linja_tila;
  insert into linja_tila
  select route, dir, ikkuna, j.jakso, count(*), count(distinct (v.t0 at time zone 'Europe/Helsinki')::date),
    percentile_cont(0.5) within group (order by lisa_sum), percentile_cont(0.9) within group (order by lisa_sum),
    avg(valeja), now()
  from _v v
  cross join lateral (values ('24h', v.t0 > now() - interval '24 hours'), ('7d', true)) w(ikkuna, ok)
  cross join lateral (values (
    case when extract(isodow from v.t0 at time zone 'Europe/Helsinki') in (6,7) then 'muu'
         when extract(hour from v.t0 at time zone 'Europe/Helsinki') between 7 and 8 then 'aamu'
         when extract(hour from v.t0 at time zone 'Europe/Helsinki') between 9 and 14 then 'paiva'
         when extract(hour from v.t0 at time zone 'Europe/Helsinki') between 15 and 17 then 'ilta'
         else 'muu' end), ('kaikki')) j(jakso)
  where w.ok
  group by route, dir, ikkuna, j.jakso;

  delete from linja_nauha;
  insert into linja_nauha
  select route, dir, lupa_id, min(off), sum(lisa), max(n)
  from (
    select o.route, o.dir, o.lupa_id, o.from_stop, o.to_stop,
      percentile_cont(0.5) within group (order by extract(epoch from (o.t - v.t0))) off,
      percentile_cont(0.5) within group (order by o.lisa) lisa, count(*) n
    from _o o join _v v using (vuoro)
    group by 1,2,3,4,5
  ) p
  group by route, dir, lupa_id;

  return 'vuoroja '||(select count(*) from _v)||', linjasuuntia '||(select count(*) from linja_tila where ikkuna='7d' and jakso='kaikki');
end $$;
revoke execute on function paivita_vuorot() from public, anon, authenticated;
select paivita_vuorot();

-- 5) Vanha pilottimittaus: ei kirjoita enää pysäkkien sijainteja vanhentuneesta hfp_events-taulusta, eikä lue koko segment_2h:ta
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
  join (select distinct from_stop, to_stop from segment_2h where bucket > now() - interval '2 days') s on true
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
  join (select distinct from_stop, to_stop from segment_2h where bucket > now() - interval '2 days') s on true
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

-- 6) Kevyempi ylläpito: tilannekuvan kokonaisluvut kerran tunnissa (lukee koko segment_2h:n)
select cron.unschedule('tila-valimuisti') where exists (select 1 from cron.job where jobname = 'tila-valimuisti');
select cron.schedule('tila-valimuisti', '4 * * * *', $$select paivita_tila_valimuisti()$$);

-- 7) Julkiselta avaimelta pois sisäiset ylläpitofunktiot
do $$ declare f text; begin
  foreach f in array array['paivita_tila_valimuisti()','lido_hae()','lido_tyo()','lido_laskurit_hae()','lido_laskurit_kasittele()'] loop
    begin execute 'revoke all on function ' || f || ' from public, anon, authenticated'; exception when undefined_function then null; end;
  end loop; end $$;

-- 8) Sama hälytysajo oli ajastettu kahdesti (vahti-ilmoitus ja vahti-ilmoita)
select cron.unschedule('vahti-ilmoitus') where exists (select 1 from cron.job where jobname = 'vahti-ilmoitus')
  and exists (select 1 from cron.job where jobname = 'vahti-ilmoita');

-- 9) Rajatta kasvavat taulut ja puuttuvat indeksit
create index if not exists tallennin_loki_funktio_alkoi on tallennin_loki (funktio, alkoi desc);
select cron.unschedule('yllapito-siivous') where exists (select 1 from cron.job where jobname = 'yllapito-siivous');
select cron.schedule('yllapito-siivous', '50 2 * * *', $$
  delete from cron.job_run_details where end_time < now() - interval '7 days';
  delete from tallennin_loki where alkoi < now() - interval '30 days';
$$);

-- 10) Lupalista: jokaiselta tasolta sen oma uusin tilannekuva. Jos yhden tason haku epäonnistui, sen työt eivät katoa päiväksi.
create or replace view v_luvat with (security_invoker = false) as
select l.lupa_id, l.layer, l.osoite, l.tarkoitus, l.kaupunginosa, l.status, l.alkaa, l.paattyy,
  t.segmentteja, t.linjat, t.ohitukset_24h, t.ajoja_vrk, t.lisaviive_s, t.ajoneuvotunnit_24h,
  t.indeksi_24h, t.perustaso_havainnot, t.perustaso_ikkunat, t.paivitetty,
  (select a.cell from seuranta_alueet a where a.lupa_id = l.lupa_id limit 1) pilotti_cell,
  l.geom,
  ai.sijainti ai_sijainti, ai.vaikutus ai_vaikutus, ai.sulkee ai_sulkee, ai.perustelu ai_perustelu
from luvat_snapshot l
left join lupa_tila t using (lupa_id)
left join lupa_ai ai using (lupa_id)
where (l.layer, l.snap_date) in (select layer, max(snap_date) from luvat_snapshot where snap_date > current_date - 7 group by layer)
  and (l.paattyy is null or l.paattyy >= now() - interval '1 day') and l.alkaa < now() + interval '60 days';
grant select on v_luvat to anon, authenticated;

-- 11) Julkiset kirjoitukset: rajat myös osoitekohtaisesti, ettei yksi käyttäjä voi täyttää kantaa tai estää muita
alter table tietutka_arviot add column if not exists lahde text;
alter table tietutka_yhteydenotot add column if not exists lahde text;
create or replace function tietutka_lahde() returns text language sql stable as $$
  select md5(coalesce(split_part(current_setting('request.headers', true)::json->>'x-forwarded-for', ',', 1), 'tuntematon') || 'tietutka')
$$;
create or replace function tietutka_lukitse(p_laskelma jsonb, p_alue jsonb default null)
returns json language plpgsql security definer set search_path = public as $$
declare v_id text; v_luotu timestamptz; v_lahde text := tietutka_lahde();
begin
  if p_laskelma is null or jsonb_typeof(p_laskelma) <> 'object' then raise exception 'laskelma puuttuu'; end if;
  if octet_length(p_laskelma::text) + coalesce(octet_length(p_alue::text), 0) > 60000 then raise exception 'arvio on liian suuri'; end if;
  if (select count(*) from tietutka_arviot where luotu > now() - interval '1 hour' and lahde = v_lahde) >= 30 then raise exception 'liikaa arvioita juuri nyt, yritä hetken päästä'; end if;
  if (select count(*) from tietutka_arviot where luotu > now() - interval '1 hour') >= 300 then raise exception 'liikaa arvioita juuri nyt, yritä hetken päästä'; end if;
  loop
    v_id := 'TT-' || to_char(now() at time zone 'Europe/Helsinki', 'YYYYMMDD') || '-' || upper(substr(md5(gen_random_uuid()::text), 1, 8));
    exit when not exists (select 1 from tietutka_arviot where id = v_id);
  end loop;
  insert into tietutka_arviot (id, osoite, lupa_id, alkaa, paattyy, haitta, lisaaika_s, ohitukset, lisaaika_h_vrk, laskelma, alue, lahde)
  values (v_id, left(p_laskelma->>'osoite', 300), left(p_laskelma->>'lupa_id', 100),
          nullif(p_laskelma->>'alkaa', '')::date, nullif(p_laskelma->>'paattyy', '')::date, left(p_laskelma->>'haitta', 30),
          nullif(p_laskelma->>'s', '')::numeric, nullif(p_laskelma->>'ohitukset_arkipaiva', '')::numeric::int,
          nullif(p_laskelma->>'lisaaika_h_vrk', '')::numeric, p_laskelma, p_alue, v_lahde)
  returning luotu into v_luotu;
  return json_build_object('id', v_id, 'luotu', v_luotu);
end $$;
grant execute on function tietutka_lukitse(jsonb, jsonb) to anon, authenticated;

create or replace function tietutka_pyyda_esittely(p_nimi text, p_yritys text, p_yhteys text, p_viesti text, p_arvio_id text default null)
returns json language plpgsql security definer set search_path = public as $$
declare v_kanava text := (select topic from vahti_kanava where id = 1); v_lahde text := tietutka_lahde();
begin
  if coalesce(trim(p_nimi), '') = '' or coalesce(trim(p_yhteys), '') = '' then raise exception 'nimi ja yhteystieto tarvitaan'; end if;
  if length(p_nimi) > 120 or length(coalesce(p_yritys, '')) > 160 or length(p_yhteys) > 160 or length(coalesce(p_viesti, '')) > 2000
     or length(coalesce(p_arvio_id, '')) > 40 then raise exception 'liian pitkä'; end if;
  if (select count(*) from tietutka_yhteydenotot where luotu > now() - interval '1 hour' and lahde = v_lahde) >= 5 then raise exception 'liikaa pyyntöjä juuri nyt, yritä hetken päästä'; end if;
  if (select count(*) from tietutka_yhteydenotot where luotu > now() - interval '1 hour') >= 60 then raise exception 'liikaa pyyntöjä juuri nyt, yritä hetken päästä'; end if;
  insert into tietutka_yhteydenotot (nimi, yritys, yhteys, viesti, arvio_id, lahde)
  values (trim(p_nimi), nullif(trim(p_yritys), ''), trim(p_yhteys), nullif(trim(p_viesti), ''), nullif(trim(p_arvio_id), ''), v_lahde);
  if v_kanava is not null then
    perform net.http_post(url := 'https://ntfy.sh/', body := jsonb_build_object('topic', v_kanava, 'priority', 4, 'tags', jsonb_build_array('handshake'),
      'title', 'Tietutka: esittelypyyntö',
      'message', trim(p_nimi) || coalesce(' · ' || nullif(trim(p_yritys), ''), '') || E'\n' || trim(p_yhteys) || coalesce(E'\n' || nullif(trim(p_viesti), ''), '')));
  end if;
  return json_build_object('ok', true);
end $$;
grant execute on function tietutka_pyyda_esittely(text, text, text, text, text) to anon, authenticated;
-- Yhteydenotot säilytetään 12 kk
select cron.unschedule('tietutka-yhteydenotot-siivous') where exists (select 1 from cron.job where jobname = 'tietutka-yhteydenotot-siivous');
select cron.schedule('tietutka-yhteydenotot-siivous', '55 2 * * *', $$delete from tietutka_yhteydenotot where luotu < now() - interval '12 months'$$);
