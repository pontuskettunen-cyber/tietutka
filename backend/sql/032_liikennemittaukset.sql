-- Helsingin liikennemittaukset (lidotiku.api.hel.fi, CC BY 4.0) työmaiden kohdalla.
-- Suppea versio: vain työmaat, joiden alle 150 m:n päässä on toimiva laskuri (noin 14 % työmaista, nopeus noin 3 %).
-- Rajapinta on hidas (4-25 s/haku), joten data haetaan kerran yössä pg_netillä ja sivu lukee valmiin vertailun.
-- Vertailu: arkipäivien keskiarvo työn aikana (enintään 14 pv) vs. 4 viikkoa ennen työn alkua.

create table if not exists lido_laskuri(id int primary key, nimi text, lahde text, lat float8, lon float8, lisatty timestamptz default now());
create table if not exists lido_pyynto(req_id bigint primary key, laskuri int, mittaus text, pyydetty timestamptz default now());
create table if not exists lido_paiva(laskuri int, paiva date, mittaus text, arvo float8, suuntia int, primary key (laskuri, paiva, mittaus));
alter table lido_laskuri enable row level security;
alter table lido_pyynto enable row level security;
alter table lido_paiva enable row level security;

-- GeoJSON-geometrian keskipiste: kaikkien koordinaattiparien keskiarvo
create or replace function lido_keskipiste(g jsonb, out lat float8, out lon float8) language sql immutable set search_path = public as $$
  select avg(m[2]::float8), avg(m[1]::float8)
  from regexp_matches(g->>'coordinates', '\[\s*(-?[0-9.]+)\s*,\s*(-?[0-9.]+)\s*\]', 'g') m;
$$;

create or replace function lido_lupa_laskurit() returns table(lupa_id text, laskuri int, nimi text, lahde text, etaisyys int, alkaa timestamptz)
language sql stable security definer set search_path = public as $$
  select l.lupa_id, k.id, k.nimi, k.lahde,
         round(sqrt(power((k.lon - c.lon) * 111320 * cos(radians(c.lat)), 2) + power((k.lat - c.lat) * 110574, 2)))::int,
         l.alkaa
  from v_luvat l
  cross join lateral lido_keskipiste(l.geom) c
  join lido_laskuri k on abs(k.lat - c.lat) < 0.0015 and abs(k.lon - c.lon) < 0.003
  where l.geom is not null and coalesce(l.segmentteja, 0) > 0
    and l.alkaa <= now() and coalesce(l.paattyy, now()) >= now()
    and sqrt(power((k.lon - c.lon) * 111320 * cos(radians(c.lat)), 2) + power((k.lat - c.lat) * 110574, 2)) <= 150;
$$;

-- Rajapinta ei kestä rinnakkaisia hakuja (100 kerralla = 504), joten haut jonotetaan ja ajetaan 4 kerrallaan minuutin välein.
create table if not exists lido_jono(laskuri int, mittaus text, tila text default 'odottaa', yritykset int default 0, req_id bigint,
  paivitetty timestamptz default now(), primary key (laskuri, mittaus));
alter table lido_jono enable row level security;

-- Yöllinen täyttö: enintään 3 laskuria työmaata kohden (nopeutta mittaavat ensin, sitten lähimmät)
create or replace function lido_hae() returns int language plpgsql security definer set search_path = public as $$
declare n int;
begin
  insert into lido_jono(laskuri, mittaus)
  select distinct x.laskuri, m.m
  from (select *, row_number() over (partition by lupa_id order by (lahde <> 'LIVA') desc, etaisyys) rn from lido_lupa_laskurit()) x
  cross join (values ('count'), ('speed')) m(m)
  where x.rn <= 3 and (m.m = 'count' or x.lahde in ('HEL LAM', 'SmartJunction', 'Fintraffic'))
  on conflict (laskuri, mittaus) do update set tila = 'odottaa', yritykset = 0, req_id = null, paivitetty = now();
  get diagnostics n = row_count;
  return n;
end $$;

-- Minuutin välein: käsittele valmiit vastaukset ja lähetä uusia, kun kesken on alle 4
create or replace function lido_tyo() returns int language plpgsql security definer set search_path = public as $$
declare n int := 0; r record;
begin
  for r in select j.laskuri, j.mittaus, h.status_code, h.content from lido_jono j join net._http_response h on h.id = j.req_id where j.tila = 'pyydetty' loop
    if r.status_code = 200 then
      insert into lido_paiva(laskuri, paiva, mittaus, arvo, suuntia)
      select r.laskuri, (e->>'startTime')::timestamptz at time zone 'Europe/Helsinki', r.mittaus,
             case when r.mittaus = 'count' then sum((e->>'aggregatedValue')::float8) else avg((e->>'aggregatedValue')::float8) end, count(*)
      from jsonb_array_elements(r.content::jsonb -> 'results') e
      where e->>'aggregatedValue' is not null
      group by 1, 2, 3
      on conflict (laskuri, paiva, mittaus) do update set arvo = excluded.arvo, suuntia = excluded.suuntia;
      update lido_jono set tila = 'valmis', paivitetty = now() where laskuri = r.laskuri and mittaus = r.mittaus;
    else
      update lido_jono set tila = case when yritykset >= 3 then 'virhe' else 'odottaa' end, paivitetty = now() where laskuri = r.laskuri and mittaus = r.mittaus;
    end if;
    n := n + 1;
  end loop;
  -- vastaus kadonnut (pg_net siivoaa vanhat): uudestaan
  update lido_jono set tila = 'odottaa' where tila = 'pyydetty' and paivitetty < now() - interval '10 minutes';
  for r in select laskuri, mittaus from lido_jono where tila = 'odottaa' order by yritykset, laskuri
           limit greatest(0, 4 - (select count(*) from lido_jono where tila = 'pyydetty')) loop
    update lido_jono set tila = 'pyydetty', yritykset = yritykset + 1, paivitetty = now(),
      req_id = net.http_get(
        url := format('https://lidotiku.api.hel.fi/api/observations/aggregate/?counter=%s&period=day&measurementType=%s&page_size=400&format=json', r.laskuri, r.mittaus),
        timeout_milliseconds := 60000)
    where laskuri = r.laskuri and mittaus = r.mittaus;
  end loop;
  delete from lido_paiva where paiva < current_date - 420;
  return n;
end $$;

-- Vertailu työmaittain: paras laskuri (nopeus ensin, sitten lähin), vain luotettavat (vertailutaso ≥ 200 autoa/pv, päiviä riittävästi).
-- Vertailutaso: arkipäivät 4 viikkoa ennen työn alkua. Jos niiltä ajoilta ei ole dataa (kaupungin mittauksissa oli katko 3-10/2026),
-- käytetään samoja päiviä vuotta aiemmin (364 pv, sama viikonpäivä), kunhan ne ovat ennen työn alkua.
create or replace function lido_ka(p_laskuri int, p_mittaus text, p_alku date, p_loppu date, out ka float8, out n int)
language sql stable set search_path = public as $$
  select avg(arvo), count(*) filter (where arvo > 0)::int from lido_paiva
  where laskuri = p_laskuri and mittaus = p_mittaus and extract(isodow from paiva) <= 5 and paiva between p_alku and p_loppu;
$$;
drop view if exists v_lupa_liikenne;
drop function if exists lido_vertailu();
create or replace function lido_vertailu() returns table(lupa_id text, laskuri text, lahde text, etaisyys int, vertailu text,
  autoja_ennen int, autoja_nyt int, muutos_pct int, nopeus_ennen numeric, nopeus_nyt numeric, paivia_ennen int, paivia_nyt int)
language sql stable security definer set search_path = public as $$
  with x as (
    select ll.*, greatest(ll.alkaa::date + 1, current_date - 14) n_alku, current_date - 1 n_loppu from lido_lupa_laskurit() ll
  ), y as (
    select x.*, nyt.ka a_n, nyt.n n_n, ennen.ka a_e1, ennen.n n_e1, vuosi.ka a_e2, vuosi.n n_e2,
      vnyt.ka v_n, vennen.ka v_e1, vvuosi.ka v_e2
    from x
    cross join lateral lido_ka(x.laskuri, 'count', x.n_alku, x.n_loppu) nyt
    cross join lateral lido_ka(x.laskuri, 'count', x.alkaa::date - 28, x.alkaa::date - 1) ennen
    cross join lateral lido_ka(x.laskuri, 'count', x.n_alku - 364, x.n_loppu - 364) vuosi
    cross join lateral lido_ka(x.laskuri, 'speed', x.n_alku, x.n_loppu) vnyt
    cross join lateral lido_ka(x.laskuri, 'speed', x.alkaa::date - 28, x.alkaa::date - 1) vennen
    cross join lateral lido_ka(x.laskuri, 'speed', x.n_alku - 364, x.n_loppu - 364) vvuosi
  ), z as (
    select y.*,
      case when a_e1 >= 200 and n_e1 >= 5 then 'ennen' when a_e2 >= 200 and n_e2 >= 5 and n_loppu - 364 < alkaa::date then 'vuosi' end vert
    from y where a_n > 0 and n_n >= 3
  )
  select distinct on (lupa_id) lupa_id, nimi, lahde, etaisyys, vert,
    round(case vert when 'ennen' then a_e1 else a_e2 end)::int, round(a_n)::int,
    round((a_n / case vert when 'ennen' then a_e1 else a_e2 end - 1) * 100)::int,
    round((case vert when 'ennen' then v_e1 else v_e2 end)::numeric, 1), round(v_n::numeric, 1),
    case vert when 'ennen' then n_e1 else n_e2 end, n_n
  from z where vert is not null
  order by lupa_id, (v_n is not null and (case vert when 'ennen' then v_e1 else v_e2 end) is not null) desc, (vert = 'ennen') desc, etaisyys;
$$;
grant execute on function lido_vertailu() to anon, authenticated;
drop view if exists v_lupa_liikenne;
create view v_lupa_liikenne with (security_invoker = false) as select * from lido_vertailu();
grant select on v_lupa_liikenne to anon, authenticated;

select cron.schedule('liikenne-hae', '15 3 * * *', $$select lido_hae()$$);
select cron.schedule('liikenne-tyo', '* * * * *', $$select lido_tyo()$$);

-- Laskurilista (viikoittain): sivut pg_netillä, vain toimivat laskurit, joissa on sijainti
create or replace function lido_laskurit_hae() returns int language plpgsql security definer set search_path = public as $$
begin
  for p in 1..5 loop
    insert into lido_pyynto(req_id, laskuri, mittaus)
    values (net.http_get(url := format('https://lidotiku.api.hel.fi/api/counters/?format=json&page_size=1000&page=%s', p), timeout_milliseconds := 60000), p, 'laskurit');
  end loop;
  return 5;
end $$;
create or replace function lido_laskurit_kasittele() returns int language plpgsql security definer set search_path = public as $$
declare n int;
begin
  insert into lido_laskuri(id, nimi, lahde, lat, lon)
  select (f->'properties'->>'id')::int, f->'properties'->>'name', f->'properties'->>'source',
         (f->'geometry'->'coordinates'->>1)::float8, (f->'geometry'->'coordinates'->>0)::float8
  from lido_pyynto p
  join net._http_response h on h.id = p.req_id and h.status_code = 200
  cross join lateral jsonb_array_elements(h.content::jsonb -> 'results' -> 'features') f
  where p.mittaus = 'laskurit' and f->'geometry' is not null
    and f->'properties'->>'source' in ('LIVA', 'HEL LAM', 'SmartJunction', 'Fintraffic')
    and (f->'properties'->>'lastStoredObservation')::timestamptz > now() - interval '7 days'
  on conflict (id) do update set nimi = excluded.nimi, lahde = excluded.lahde, lat = excluded.lat, lon = excluded.lon;
  get diagnostics n = row_count;
  delete from lido_pyynto p where p.mittaus = 'laskurit' and exists (select 1 from net._http_response h where h.id = p.req_id);
  return n;
end $$;
select cron.schedule('liikenne-laskurit-hae', '50 2 * * 1', $$select lido_laskurit_hae()$$);
select cron.schedule('liikenne-laskurit-kasittele', '5 3 * * 1', $$select lido_laskurit_kasittele()$$);
