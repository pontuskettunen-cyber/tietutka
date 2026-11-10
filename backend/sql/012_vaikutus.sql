-- Työmaatutka 012: todennettu vaikutus = sama pysäkkiväli työn aikana vs. ilman työtä
--
-- Menetelmä (erotusten erotus):
--   1) Jokaiselle ohitukselle lasketaan lisäaika suhteessa saman linjan muihin väleihin samassa 2 h jaksossa
--      (sama kuin arviossa) -> poistaa ruuhkan, sään ja muun koko verkkoa koskevan vaihtelun.
--   2) Verrataan samaa väliä ja samaa vuorokaudenjaksoa: työn aikana vs. ennen työtä (tai työn päätyttyä).
--      Ero = työmaan oma vaikutus. Välin pysyvä hitaus (valot, keskustan ruuhka) kumoutuu.
--   Väli lasketaan mukaan, kun molemmilta puolilta on vähintään 3 ohitusta; linja, kun molemmilta vähintään 10.

-- 1) Päättyneitäkin töitä seurataan 14 vrk, jotta niille saadaan jälkeen-vertailu.
--    Lupa haetaan viimeisimmästä tilannekuvasta, jossa se esiintyi (kaupungin rajapinta pudottaa päättyneet).
create or replace function paivita_lupasegmentit() returns text
language plpgsql security definer set search_path = public as $$
begin
  create temp table _pari on commit drop as
  select p.from_stop, p.to_stop, pa.lat alat, pa.lon alon, pb.lat blat, pb.lon blon
  from (select distinct from_stop, to_stop from segment_2h) p
  join pysakit pa on pa.stop = p.from_stop join pysakit pb on pb.stop = p.to_stop
  where abs(pa.lat-pb.lat) < 0.02 and abs(pa.lon-pb.lon) < 0.04;
  create temp table _parikey on commit drop as
  select distinct from_stop, to_stop, floor(la/0.004)::int ky, floor(lo/0.004)::int kx
  from _pari, lateral (values (alat,alon),(blat,blon),((alat+blat)/2,(alon+blon)/2)) v(la,lo);
  create index on _parikey (ky, kx);

  create temp table _lupa on commit drop as
  select distinct on (lupa_id) lupa_id, geom, alkaa, paattyy
  from luvat_snapshot where snap_date > current_date - 45
  order by lupa_id, snap_date desc;

  create temp table _vert on commit drop as
  select l.lupa_id, (m[2])::float8 lat, (m[1])::float8 lon
  from _lupa l, regexp_matches(l.geom->>'coordinates', '\[(-?\d+\.\d+),\s*(-?\d+\.\d+)\]', 'g') m
  where (l.paattyy is null or l.paattyy >= now() - interval '14 days') and l.alkaa < now() + interval '60 days';

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

-- 2) Tulos per lupa
create table if not exists lupa_vaikutus (
  lupa_id text primary key,
  tila text,            -- pohjaa_kertyy | todennettu | odottaa_paattymista | ei_pohjaa
  vertailu text,        -- ennen | jalkeen
  alkaa timestamptz, paattyy timestamptz, osoite text,
  pohja_n int, aikana_n int,
  vaikutus_s real, vaikutus_seis real, ajoneuvotunnit_vrk real,
  linjat jsonb, jaksot jsonb, paivitetty timestamptz);
alter table lupa_vaikutus enable row level security;

create or replace function paivita_vaikutus() returns text
language plpgsql security definer set search_path = public as $$
declare v_alku timestamptz := (select min(t) from seg_havainto);
begin
  create temp table _l on commit drop as
  select distinct on (lupa_id) lupa_id, alkaa, paattyy, osoite
  from luvat_snapshot where snap_date > current_date - 45
  order by lupa_id, snap_date desc;

  create temp table _ref on commit drop as
  select bucket, route, dir, sum(sum_ddl_ajo)/nullif(sum(n_ajo),0) ref_ajo, sum(sum_seis)/nullif(sum(n_seis),0) ref_seis
  from segment_2h where bucket > now() - interval '22 days' and (n_ajo > 0 or n_seis > 0)
  group by bucket, route, dir;
  create index on _ref (bucket, route, dir);

  create temp table _o on commit drop as
  select ls.lupa_id, h.route, h.dir, h.from_stop, h.to_stop,
    case when extract(isodow from h.t at time zone 'Europe/Helsinki') in (6,7) then 'muu'
         when extract(hour from h.t at time zone 'Europe/Helsinki') between 7 and 8 then 'aamu'
         when extract(hour from h.t at time zone 'Europe/Helsinki') between 9 and 14 then 'paiva'
         when extract(hour from h.t at time zone 'Europe/Helsinki') between 15 and 17 then 'ilta'
         else 'muu' end jakso,
    case when h.t < l.alkaa then 'ennen'
         when l.paattyy is not null and h.t > l.paattyy + interval '12 hours' then 'jalkeen'
         else 'aikana' end vaihe,
    -(h.ddl_ajo - r.ref_ajo) lisa_ajo, h.seis - r.ref_seis lisa_seis
  from seg_havainto h
  join lupa_segmentit ls on ls.from_stop = h.from_stop and ls.to_stop = h.to_stop
  join _l l on l.lupa_id = ls.lupa_id
  join _ref r on r.bucket = date_bin('2 hours', h.t, timestamptz '2000-01-01') and r.route = h.route and r.dir = h.dir
  where h.ddl_ajo is not null and r.ref_ajo is not null and l.alkaa is not null
    and (h.t >= l.alkaa - interval '14 days')
    and (h.t > now() - interval '21 days');

  -- välin mediaanit vaiheittain
  create temp table _s on commit drop as
  select lupa_id, route, dir, from_stop, to_stop, jakso, vaihe, count(*) n,
    percentile_cont(0.5) within group (order by lisa_ajo) a,
    percentile_cont(0.5) within group (order by lisa_seis) s
  from _o group by 1,2,3,4,5,6,7;

  -- vertailukohta: ennen jos on, muuten jälkeen
  create temp table _p on commit drop as
  select x.lupa_id, x.route, x.dir, x.from_stop, x.to_stop, x.jakso,
    x.n n_a, x.a a_a, x.s s_a,
    coalesce(e.n, j.n) n_b, coalesce(e.a, j.a) a_b, coalesce(e.s, j.s) s_b,
    case when e.n >= 3 then 'ennen' else 'jalkeen' end vert
  from _s x
  left join _s e on e.lupa_id=x.lupa_id and e.route=x.route and e.dir=x.dir and e.from_stop=x.from_stop and e.to_stop=x.to_stop and e.jakso=x.jakso and e.vaihe='ennen' and e.n >= 3
  left join _s j on j.lupa_id=x.lupa_id and j.route=x.route and j.dir=x.dir and j.from_stop=x.from_stop and j.to_stop=x.to_stop and j.jakso=x.jakso and j.vaihe='jalkeen' and j.n >= 3
  where x.vaihe = 'aikana' and x.n >= 3 and coalesce(e.n, j.n) is not null;

  -- linja × jakso: välien erotusten summa (linja ajaa kaikki työmaan välit)
  create temp table _lj on commit drop as
  select lupa_id, route, dir, jakso, max(vert) vert, max(n_a) n_a, max(n_b) n_b,
    sum(a_a - a_b) ero, sum(s_a - s_b) ero_seis
  from _p group by 1,2,3,4 having max(n_a) >= 10 and max(n_b) >= 10;

  -- linja: jaksojen painotettu keskiarvo (paino = ohituksia työn aikana)
  create temp table _ln on commit drop as
  select lupa_id, route, dir, max(vert) vert, sum(n_a) n_a, sum(n_b) n_b,
    sum(n_a*ero)/sum(n_a) ero, sum(n_a*ero_seis)/sum(n_a) ero_seis
  from _lj group by 1,2,3;

  -- ohitukset vuorokaudessa linjoittain (viimeiset 24 h)
  create temp table _oh on commit drop as
  select lupa_id, route, dir, ohitukset from lupa_mitta_linja where ikkuna = '24h' and jakso = 'kaikki';

  delete from lupa_vaikutus;
  insert into lupa_vaikutus
  select l.lupa_id,
    case when now() < l.alkaa then 'pohjaa_kertyy'
         when v.lupa_id is not null then 'todennettu'
         when l.alkaa < v_alku then 'odottaa_paattymista'
         else 'ei_pohjaa' end,
    v.vert, l.alkaa, l.paattyy, l.osoite,
    coalesce(v.n_b, pk.n), v.n_a, v.vaikutus_s, v.vaikutus_seis, v.vehh, v.linjat, jk.jaksot, now()
  from _l l
  left join (
    select n.lupa_id, max(n.vert) vert, sum(n.n_b)::int n_b, sum(n.n_a)::int n_a,
      sum(n.n_a*n.ero)/sum(n.n_a) vaikutus_s, sum(n.n_a*n.ero_seis)/sum(n.n_a) vaikutus_seis,
      sum(coalesce(o.ohitukset,0)*n.ero)/3600.0 vehh,
      jsonb_agg(jsonb_build_object('route',n.route,'dir',n.dir,'ero',round(n.ero::numeric,1),'n_a',n.n_a,'n_b',n.n_b,'ohit_vrk',o.ohitukset) order by n.n_a desc) linjat
    from _ln n left join _oh o on o.lupa_id=n.lupa_id and o.route=n.route and o.dir=n.dir
    group by n.lupa_id) v on v.lupa_id = l.lupa_id
  left join (select lupa_id, jsonb_object_agg(jakso, jsonb_build_object('ero',round(e::numeric,1),'n_a',na,'n_b',nb)) jaksot
             from (select lupa_id, jakso, sum(n_a*ero)/sum(n_a) e, sum(n_a) na, sum(n_b) nb from _lj group by 1,2) z group by 1) jk on jk.lupa_id = l.lupa_id
  left join (select lupa_id, count(*)::int n from _o where vaihe = 'ennen' group by 1) pk on pk.lupa_id = l.lupa_id
  where l.lupa_id in (select lupa_id from lupa_segmentit);

  return 'todennettu '||(select count(*) from lupa_vaikutus where tila='todennettu')
    ||', pohjaa kertyy '||(select count(*) from lupa_vaikutus where tila='pohjaa_kertyy')
    ||', odottaa päättymistä '||(select count(*) from lupa_vaikutus where tila='odottaa_paattymista');
end $$;
revoke execute on function paivita_vaikutus() from public, anon, authenticated;

create or replace view v_lupa_vaikutus with (security_invoker = false) as select * from lupa_vaikutus;
grant select on v_lupa_vaikutus to anon, authenticated;

select cron.schedule('vaikutus-30min', '12,42 * * * *', $$select paivita_vaikutus()$$);
select paivita_lupasegmentit();
select paivita_vaikutus();
