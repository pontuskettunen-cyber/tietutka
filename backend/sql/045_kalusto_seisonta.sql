-- Tietutka 045: kaluston seisonnat erikseen
-- HFP:ssä auton lähtö voi jäädä auki, kun auto seisoo päätepysäkillä, varikolla tai rikki. Silloin dl (poikkeama aikataulusta)
-- kasvaa satoihin minuutteihin. Se ei ole myöhästymistä, joten se pidetään erillään mittauksesta ja kerätään omaan tauluunsa:
--   kaanto  = auto saapui lähdön viimeiselle pysäkille ja aloitti seuraavan lähdön (todellinen kääntöaika päätepysäkillä)
--   pysakki = saman lähdön aikana seisonta pysäkillä ≥ 5 min (ajantasaus on yleensä alle 3 min; pidempi = häiriö)
--   valilla = saman lähdön aikana kahden pysäkin välillä kului yli 20 min (jumissa, rikki tai lähtö jäi auki)
-- Ajoneuvon tunniste (oper/veh) on HSL:n avointa dataa; kuljettaja- tai henkilötietoja ei ole.

create table if not exists kalusto_seisonta (
  id bigserial primary key,
  veh text not null,
  tyyppi text not null check (tyyppi in ('kaanto','pysakki','valilla')),
  route text, dir smallint, mode text,
  stop integer,            -- pysäkki, jolla seisottiin (valilla: pysäkki, jolta lähdettiin)
  stop2 integer,           -- valilla: seuraava pysäkki
  alku timestamptz not null,
  loppu timestamptz not null,
  kesto_s integer not null,
  dl_alku integer, dl_loppu integer,
  vuoro text,              -- valilla/pysakki: lähdön tunniste; kaanto: uusi lähtö
  vuoro_ed text,           -- kaanto: edellinen lähtö
  unique (veh, alku, tyyppi)
);
create index if not exists kalusto_seisonta_alku_idx on kalusto_seisonta (alku);
create index if not exists kalusto_seisonta_route_idx on kalusto_seisonta (route, tyyppi, alku);
alter table kalusto_seisonta enable row level security;

-- Kooste julkiseen käyttöön: ei yksittäisiä ajoneuvoja, vain linja- ja tyyppitason luvut
create or replace function kalusto_seisonta_kooste(p_paivia integer default 7)
returns jsonb language sql stable security definer set search_path = public as $$
  with d as (
    select * from kalusto_seisonta
    where alku > now() - make_interval(days => greatest(1, least(coalesce(p_paivia, 7), 60)))
  ),
  tyypit as (
    select tyyppi, count(*) n,
      percentile_cont(0.5) within group (order by kesto_s) med_s,
      percentile_cont(0.9) within group (order by kesto_s) p90_s
    from d group by tyyppi
  ),
  kaanto as (
    select route, mode, count(*) n,
      percentile_cont(0.1) within group (order by kesto_s) p10_s,
      percentile_cont(0.5) within group (order by kesto_s) med_s,
      percentile_cont(0.9) within group (order by kesto_s) p90_s
    from d where tyyppi = 'kaanto' and kesto_s <= 5400
    group by route, mode having count(*) >= 5
  ),
  hairiot as (
    select route, mode, count(*) n, sum(kesto_s) summa_s, max(kesto_s) max_s
    from d where tyyppi in ('pysakki','valilla')
    group by route, mode
  )
  select jsonb_build_object(
    'paivia', greatest(1, least(coalesce(p_paivia, 7), 60)),
    'tyypit', coalesce((select jsonb_agg(to_jsonb(t)) from tyypit t), '[]'::jsonb),
    'kaanto', coalesce((select jsonb_agg(to_jsonb(k) order by k.med_s) from kaanto k), '[]'::jsonb),
    'hairiot', coalesce((select jsonb_agg(to_jsonb(h) order by h.summa_s desc) from (select * from hairiot order by summa_s desc limit 50) h), '[]'::jsonb)
  );
$$;
revoke all on function kalusto_seisonta_kooste(integer) from public;
grant execute on function kalusto_seisonta_kooste(integer) to anon, authenticated;

-- 60 vrk riittää kääntöaikojen ja häiriöiden seurantaan
select cron.unschedule('kalusto-seisonta-siivous') where exists (select 1 from cron.job where jobname = 'kalusto-seisonta-siivous');
select cron.schedule('kalusto-seisonta-siivous', '40 2 * * *', $$delete from kalusto_seisonta where alku < now() - interval '60 days'$$);

-- Kääntö voi alkaa yhdellä keruujaksolla ja päättyä seuraavalla: sen alku säilytetään ajoneuvon tilassa
alter table hfp_tila add column if not exists k_alku timestamptz;
alter table hfp_tila add column if not exists k_trip text;
alter table hfp_tila add column if not exists k_dl integer;
create index if not exists hfp_tila_t_idx on hfp_tila (t);
