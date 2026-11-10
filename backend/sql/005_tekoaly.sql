-- Työmaatutka 005: tekoälykerros
-- Periaate: luvut lasketaan aina SQL:llä (toistettavat). Kielimalli tekee vain sen, mihin sääntö ei pysty:
--  1) tulkitsee lupien vapaan tekstin (sulkeeko työ kaistan, raitiotien tai pysäkin)
--  2) kirjoittaa katsauksen lukijalle valmiiksi lasketuista luvuista ja viittaa niihin
--  3) vastaa kysymyksiin samojen lukujen pohjalta
-- Kaikki tekoälyn tuotokset merkitään (malli, aika) ja näytetään erillään mitatuista luvuista.

create table if not exists lupa_ai (
  lupa_id     text primary key,
  sijainti    text,      -- ajorata | kaista | raitiotie | pysakki | jalkakaytava | piha | muu
  vaikutus    text,      -- suuri | kohtalainen | pieni | ei
  sulkee      text[],    -- esim. {kaista, pysakki}
  perustelu   text,
  malli       text,
  luotu       timestamptz default now()
);
create table if not exists ai_katsaus (
  id      bigserial primary key,
  rooli   text not null,           -- hsl | kaupunki
  sisalto jsonb not null,          -- {otsikko, kohdat:[{teksti, lupa_id}], suositus}
  malli   text,
  luotu   timestamptz default now()
);
create table if not exists ai_kysely (
  id      bigserial primary key,
  pv      date not null default (now() at time zone 'Europe/Helsinki')::date,
  tyyppi  text,
  luotu   timestamptz default now()
);
create index if not exists ai_kysely_pv on ai_kysely (pv);
alter table lupa_ai enable row level security;
alter table ai_katsaus enable row level security;
alter table ai_kysely enable row level security;

-- v_luvat + tekoälyn tulkinta (uudet sarakkeet lisätään loppuun, jotta näkymä voidaan korvata)
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
where l.snap_date = (select max(snap_date) from luvat_snapshot)
  and (l.paattyy is null or l.paattyy >= now() - interval '1 day') and l.alkaa < now() + interval '60 days';

create or replace view v_ai_katsaus with (security_invoker = false) as
select distinct on (rooli) rooli, sisalto, malli, luotu from ai_katsaus order by rooli, luotu desc;
grant select on v_luvat, v_ai_katsaus to anon, authenticated;

-- Ajastukset: tulkinta uusille luville tunnin välein, katsaus 3 h välein päiväsaikaan (Helsingin aikaa 6–21)
select cron.schedule('ai-luokittele', '40 * * * *',
  replace((select command from cron.job where jobname='hfp-aggregate-2min'), 'functions/v1/hfp-segmentit', 'functions/v1/tekoaly?tila=luokittele'));
select cron.schedule('ai-katsaus', '45 4,7,10,13,16,19 * * *',
  replace((select command from cron.job where jobname='hfp-aggregate-2min'), 'functions/v1/hfp-segmentit', 'functions/v1/tekoaly?tila=katsaus'));
select jobname, schedule, position('tekoaly' in command) > 0 ok, position('tila=' in command) > 0 tila_ok from cron.job where jobname like 'ai-%';
