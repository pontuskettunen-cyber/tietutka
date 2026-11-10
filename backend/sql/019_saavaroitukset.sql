-- 019: Ilmatieteen laitoksen varoitukset, jotka koskevat Helsinkiä (liikennesää, jalankulkusää eli liukkaus, sade, tulva, tuuli).
-- CAP-syöte sisältää vain voimassa olevat varoitukset, joten historia kertyy tästä alkaen (saa-haku tallentaa 10 min välein).
create table if not exists saa_varoitus (
  id text primary key,
  tapahtuma text, otsikko text, vakavuus text,
  alkaa timestamptz, paattyy timestamptz, alueet text,
  paivitetty timestamptz default now()
);
alter table saa_varoitus enable row level security;
create or replace view v_saa_varoitukset with (security_invoker = false) as
select id, tapahtuma, otsikko, vakavuus, alkaa, paattyy from saa_varoitus
where coalesce(paattyy, alkaa) > now() - interval '60 days';
grant select on v_saa_varoitukset to anon, authenticated;
