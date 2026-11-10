-- Työmaatutka 007: mittarit v2
-- Yksittäisistä havainnoista (seg_havainto) lasketaan jokaiselle luvalle, linjalle ja kellonaikajaksolle:
--   lisa_ajo  = mediaani: paljonko enemmän aikaa menetetään AJOSSA työmaan pysäkkivälillä kuin saman linjan välillä keskimäärin
--   lisa_seis = mediaani: paljonko pidempään seistään pysäkillä kuin linjalla keskimäärin
-- Ikkunat: 24h, 7d (viimeiset 7 vrk) ja ed7d (sitä edeltävät 7 vrk, trendiä varten).
-- Jaksot (Helsingin aikaa): aamu 7–9, paiva 9–15, ilta 15–18, muu, sekä kaikki.

create table if not exists lupa_mitta_linja (
  lupa_id text, ikkuna text, jakso text, route text, dir smallint,
  ohitukset int, lisa_ajo real, lisa_seis real, primary key (lupa_id, ikkuna, jakso, route, dir));
create table if not exists lupa_mitta (
  lupa_id text, ikkuna text, jakso text, n int, ohitukset int,
  lisa_ajo real, lisa_seis real, ajoneuvotunnit real, ajoneuvotunnit_vrk real, paivitetty timestamptz,
  primary key (lupa_id, ikkuna, jakso));
alter table lupa_mitta_linja enable row level security;
alter table lupa_mitta enable row level security;

create or replace function paivita_mittarit() returns text
language plpgsql security definer set search_path = public as $$
begin
  -- linjan tyypillinen ajon aikataulumuutos ja seisonta per pysäkkiväli samassa 2 h ikkunassa (koko verkko)
  create temp table _ref on commit drop as
  select bucket, route, dir,
    sum(sum_ddl_ajo)/nullif(sum(n_ajo),0) ref_ajo, sum(sum_seis)/nullif(sum(n_seis),0) ref_seis
  from segment_2h where bucket > now() - interval '15 days' and (n_ajo > 0 or n_seis > 0)
  group by bucket, route, dir;
  create index on _ref (bucket, route, dir);

  create temp table _o on commit drop as
  select ls.lupa_id, h.route, h.dir, h.from_stop, h.to_stop, h.t,
    case when extract(isodow from h.t at time zone 'Europe/Helsinki') in (6,7) then 'muu'
         when extract(hour from h.t at time zone 'Europe/Helsinki') between 7 and 8 then 'aamu'
         when extract(hour from h.t at time zone 'Europe/Helsinki') between 9 and 14 then 'paiva'
         when extract(hour from h.t at time zone 'Europe/Helsinki') between 15 and 17 then 'ilta'
         else 'muu' end jakso,
    -- ddl negatiivinen = aikaa menetetty -> lisäaika = -(ddl_ajo - ref_ajo)
    case when h.ddl_ajo is not null and r.ref_ajo is not null then -(h.ddl_ajo - r.ref_ajo) end lisa_ajo,
    case when h.seis is not null and r.ref_seis is not null then h.seis - r.ref_seis end lisa_seis
  from seg_havainto h
  join lupa_segmentit ls on ls.from_stop = h.from_stop and ls.to_stop = h.to_stop
  left join _ref r on r.bucket = date_bin('2 hours', h.t, timestamptz '2000-01-01') and r.route = h.route and r.dir = h.dir
  where h.t > now() - interval '14 days';

  create temp table _w on commit drop as
  select o.*, w.ikkuna from _o o
  cross join lateral (values ('24h', o.t > now() - interval '24 hours'), ('7d', o.t > now() - interval '7 days'),
                             ('ed7d', o.t <= now() - interval '7 days')) w(ikkuna, ok)
  where w.ok;

  -- pysäkkiväli -> linja: linjan lisäaika työmaan läpi = välien mediaanien summa
  create temp table _seg on commit drop as
  select lupa_id, ikkuna, j.jakso, route, dir, from_stop, to_stop, count(*) n,
    percentile_cont(0.5) within group (order by lisa_ajo) lisa_ajo,
    percentile_cont(0.5) within group (order by lisa_seis) lisa_seis
  from _w cross join lateral (values (_w.jakso), ('kaikki')) j(jakso)
  group by 1,2,3,4,5,6,7;

  delete from lupa_mitta_linja;
  insert into lupa_mitta_linja
  select lupa_id, ikkuna, jakso, route, dir, max(n), sum(lisa_ajo), sum(lisa_seis)
  from _seg group by 1,2,3,4,5;

  delete from lupa_mitta;
  insert into lupa_mitta
  select lupa_id, ikkuna, jakso, sum(ohitukset)::int, sum(ohitukset)::int,
    sum(ohitukset*lisa_ajo) filter (where lisa_ajo is not null)/nullif(sum(ohitukset) filter (where lisa_ajo is not null),0),
    sum(ohitukset*lisa_seis) filter (where lisa_seis is not null)/nullif(sum(ohitukset) filter (where lisa_seis is not null),0),
    sum(ohitukset*greatest(lisa_ajo,0))/3600.0,
    sum(ohitukset*greatest(lisa_ajo,0))/3600.0 / case ikkuna when '24h' then 1 else
      greatest(1, least(7, extract(epoch from (now() - (select min(t) from seg_havainto)))/86400)) end,
    now()
  from lupa_mitta_linja group by 1,2,3;

  return 'lupia '||(select count(distinct lupa_id) from lupa_mitta)||', havaintoja 14 vrk '||(select count(*) from _o);
end $$;
revoke execute on function paivita_mittarit() from public, anon, authenticated;

create or replace view v_lupa_mitta with (security_invoker = false) as select * from lupa_mitta;
create or replace view v_lupa_mitta_linja with (security_invoker = false) as select * from lupa_mitta_linja where jakso = 'kaikki' or ikkuna = '7d';
grant select on v_lupa_mitta, v_lupa_mitta_linja to anon, authenticated;

select cron.schedule('mittarit-10min', '6,16,26,36,46,56 * * * *', $$select paivita_mittarit()$$);
select paivita_mittarit();

-- viikkokatsaus maanantaisin klo 6.50 Helsingin aikaa (talviaika UTC+2)
select cron.schedule('ai-viikko', '50 4 * * 1',
  replace((select command from cron.job where jobname='hfp-aggregate-2min'), 'functions/v1/hfp-segmentit', 'functions/v1/tekoaly?tila=viikko'));
