-- Työmaatutka 010: vuorokohtainen kokonaisviive ja linjanauha
-- Jokaiselle vuorolle (linja|suunta|päivä|lähtöaika) lasketaan työmaiden yhteinen lisäaika koko reitiltä.
-- Sama pysäkkiväli lasketaan vuorolle vain kerran, vaikka se osuisi usean luvan alueelle -> ei tuplalaskentaa.
-- linja_tila: vuorojen mediaani ja huonoin kymmenesosa (p90) jaksoittain
-- linja_nauha: työmaat siinä järjestyksessä kuin vuoro ne ohittaa, ja kunkin lisäaika

create table if not exists linja_tila (
  route text, dir smallint, ikkuna text, jakso text, vuoroja int, paivia int,
  med real, p90 real, valeja real, paivitetty timestamptz,
  primary key (route, dir, ikkuna, jakso));
create table if not exists linja_nauha (
  route text, dir smallint, lupa_id text, jarjestys real, lisa real, n int,
  primary key (route, dir, lupa_id));
alter table linja_tila enable row level security;
alter table linja_nauha enable row level security;

create or replace function paivita_vuorot() returns text
language plpgsql security definer set search_path = public as $$
begin
  create temp table _r on commit drop as
  select bucket, route, dir, sum(sum_ddl_ajo)/nullif(sum(n_ajo),0) ref_ajo
  from segment_2h where bucket > now() - interval '9 days' and n_ajo > 0 group by 1,2,3;
  create index on _r (bucket, route, dir);

  -- pysäkkiväli -> lähin lupa (edustaja nauhaa varten)
  create temp table _pari on commit drop as
  select distinct on (from_stop, to_stop) from_stop, to_stop, lupa_id from lupa_segmentit order by from_stop, to_stop, etaisyys_m;

  create temp table _o on commit drop as
  select distinct on (h.vuoro, h.from_stop, h.to_stop)
    h.vuoro, h.route, h.dir, h.t, h.from_stop, h.to_stop, p.lupa_id, -(h.ddl_ajo - r.ref_ajo) lisa
  from seg_havainto h
  join _pari p on p.from_stop = h.from_stop and p.to_stop = h.to_stop
  join _r r on r.bucket = date_bin('2 hours', h.t, timestamptz '2000-01-01') and r.route = h.route and r.dir = h.dir
  where h.vuoro is not null and h.ddl_ajo is not null and h.t > now() - interval '8 days'
  order by h.vuoro, h.from_stop, h.to_stop, h.t;

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

-- aikatauluagentin ehdokkaat: ruuhkajaksot, joissa huonoin kymmenesosa vuoroista menettää työmailla yli 2 min
create or replace view aikataulu_ehdokkaat as
select route, dir, jakso, vuoroja, paivia, med, p90, valeja
from linja_tila
where ikkuna = '7d' and jakso in ('aamu','ilta','paiva') and vuoroja >= 12 and p90 >= 120;

create table if not exists ai_suositus (
  id bigserial primary key, route text, dir smallint, jakso text, sisalto jsonb, perusteet jsonb,
  varmuus text, malli text, luotu timestamptz default now());
alter table ai_suositus enable row level security;

create or replace view v_linja_tila with (security_invoker = false) as select * from linja_tila;
create or replace view v_linja_nauha with (security_invoker = false) as select * from linja_nauha;
create or replace view v_ai_suositus with (security_invoker = false) as
select distinct on (route, dir, jakso) id, route, dir, jakso, sisalto, perusteet, varmuus, malli, luotu
from ai_suositus where luotu > now() - interval '3 days' order by route, dir, jakso, luotu desc;
grant select on v_linja_tila, v_linja_nauha, v_ai_suositus to anon, authenticated;

select cron.schedule('vuorot-15min', '4,19,34,49 * * * *', $$select paivita_vuorot()$$);
select cron.schedule('ai-aikataulu', '35 5,11,17 * * *',
  replace((select command from cron.job where jobname='hfp-aggregate-2min'), 'functions/v1/hfp-segmentit', 'functions/v1/tekoaly?tila=aikataulu'));
