-- 027: Vahti – tutkan sisäinen valvoja.
-- Tarkistukset ovat SQL:ää (toistettavia). Kielimalli vain kirjoittaa niistä päivittäisen tilannekatsauksen.
-- Vahti ei korjaa mitään itse: se havaitsee ja ehdottaa, ihminen korjaa.

-- Asetukset, joita sekä tarkistukset että sivu lukevat (tietokannan kapasiteetti vaihtuu, kun Supabase-taso vaihtuu)
create table if not exists tutka_asetus (k text primary key, v text not null);
alter table tutka_asetus enable row level security;
insert into tutka_asetus (k, v) values ('db_kap_mb', '500') on conflict (k) do nothing;
create or replace view v_tutka_asetus with (security_invoker = false) as select k, v from tutka_asetus;
grant select on v_tutka_asetus to anon, authenticated;

-- Tietokannan koko kerran päivässä: kasvuvauhti ja arvio täyttymisestä
create table if not exists vahti_koko (pv date primary key, mb numeric not null);
alter table vahti_koko enable row level security;

create or replace function vahti_tarkistukset(p_tallenna boolean default false)
returns table (jarj int, k text, tila text, arvo text, kuvaus text)
language plpgsql security definer set search_path = public, cron as $$
#variable_conflict use_column
declare
  v_mb numeric := round(pg_database_size(current_database()) / 1048576.0);
  v_kap numeric := coalesce((select ta.v::numeric from tutka_asetus ta where ta.k = 'db_kap_mb'), 500);
  v_kasvu numeric; v_paiv numeric; v_t timestamptz; v_n int; v_m int; v_txt text;
begin
  -- koko tallennetaan vain päivittäisessä ajossa (sivun haku on vain luku)
  if p_tallenna then
    insert into vahti_koko (pv, mb) values ((now() at time zone 'Europe/Helsinki')::date, v_mb)
      on conflict (pv) do update set mb = excluded.mb;
  end if;

  -- 1 ajoneuvodata
  select max(paivitetty) into v_t from hfp_tila;
  return query select 1, 'Ajoneuvodata', case when v_t > now() - interval '15 min' then 'ok' when v_t > now() - interval '2 hours' then 'huom' else 'virhe' end,
    coalesce(round(extract(epoch from now() - v_t) / 60) || ' min sitten', 'ei dataa'), 'Viimeisin HSL:n ajoneuvodatan käsittely';

  -- 2 tietokanta
  select (v_mb - mb) / greatest(1, (now() at time zone 'Europe/Helsinki')::date - pv) into v_kasvu
    from vahti_koko where pv <= (now() at time zone 'Europe/Helsinki')::date - 1 order by pv desc limit 1;
  v_paiv := case when v_kasvu > 0 then floor((v_kap - v_mb) / v_kasvu) end;
  return query select 2, 'Tietokanta',
    case when v_mb >= v_kap * 0.9 or v_paiv < 7 then 'virhe' when v_mb >= v_kap * 0.7 or v_paiv < 21 then 'huom' else 'ok' end,
    v_mb || ' / ' || v_kap || ' Mt (' || round(v_mb / v_kap * 100) || ' %)',
    coalesce('kasvu ' || round(v_kasvu) || ' Mt/vrk, täynnä noin ' || v_paiv || ' vrk päästä', 'kasvuvauhti selviää huomenna');

  -- 3 ajastetut ajot (vain ajon nimi, ei komentoa)
  select count(*), string_agg(distinct j.jobname, ', ') into v_n, v_txt
    from cron.job_run_details d join cron.job j using (jobid)
    where d.start_time > now() - interval '24 hours' and d.status = 'failed';
  return query select 3, 'Ajastetut ajot', case when v_n = 0 then 'ok' when v_n < 5 then 'huom' else 'virhe' end,
    v_n || ' epäonnistunutta 24 h', coalesce('epäonnistuneet: ' || v_txt, 'kaikki ajot onnistuivat');

  -- 4 funktioiden virheet
  select count(*), string_agg(distinct funktio, ', ') into v_n, v_txt
    from tallennin_loki where alkoi > now() - interval '24 hours' and virhe is not null and virhe <> ''
      and virhe !~ '^(viestejä|ilman viivaa)';   -- keruufunktiot kirjaavat tähän myös ajon tilastot
  return query select 4, 'Funktioiden virheet', case when v_n = 0 then 'ok' when v_n < 5 then 'huom' else 'virhe' end,
    v_n || ' virhettä 24 h', coalesce('funktiot: ' || v_txt, 'ei virheitä ajolokissa');

  -- 5 kielimalli
  select count(*), count(*) filter (where not ok or katkesi) into v_n, v_m from ai_kaytto where t > now() - interval '24 hours';
  return query select 5, 'Kielimalli', case when v_m = 0 then 'ok' when v_m * 5 < greatest(v_n, 1) then 'huom' else 'virhe' end,
    v_m || ' / ' || v_n || ' kutsua epäonnistui tai katkesi', 'käyttöloki, 24 h';

  -- 6 tilannekatsaus kirjoitettu
  select max(luotu) into v_t from ai_katsaus where rooli in ('hsl','kaupunki');
  return query select 6, 'Tilannekatsaus', case when v_t > now() - interval '8 hours' then 'ok' when v_t > now() - interval '24 hours' then 'huom' else 'virhe' end,
    coalesce('kirjoitettu ' || to_char(v_t at time zone 'Europe/Helsinki', 'DD.MM. HH24:MI'), 'ei koskaan'), 'ajastettu 6 kertaa päivässä';

  -- 7 lähdedatan tuoreus
  select (case when (select max(paivitetty) from hsl_hairiot) < now() - interval '2 hours' then 'häiriötiedotteet, ' else '' end)
      || (case when (select max(t) from saa_havainto) < now() - interval '2 hours' then 'sää, ' else '' end)
      || (case when (select max(snap_date) from luvat_snapshot) < (now() at time zone 'Europe/Helsinki')::date - 1 then 'katuluvat, ' else '' end)
    into v_txt;
  return query select 7, 'Lähdedata', case when v_txt = '' then 'ok' else 'huom' end,
    case when v_txt = '' then 'tuoretta' else 'vanhentunut: ' || rtrim(v_txt, ', ') end, 'häiriötiedotteet 2 h, sää 2 h, katuluvat 1 vrk';

  -- 8 epäuskottavat luvut
  select count(*) into v_n from lupa_mitta where ikkuna = '7d' and jakso = 'kaikki' and n >= 10 and abs(lisa_ajo) > 300;
  return query select 8, 'Epäuskottavat luvut', case when v_n = 0 then 'ok' else 'huom' end,
    v_n || ' työmaata yli ±5 min / ohitus', 'yksittäinen ohitus harvoin hidastuu työmaalla yli 5 min: tarkista kohdistus';
end $$;
revoke all on function vahti_tarkistukset(boolean) from public, anon, authenticated;
grant execute on function vahti_tarkistukset(boolean) to service_role;

select count(*) from vahti_tarkistukset(true);

-- Päivittäiset raportit: tarkistukset + kielimallin kirjoittama katsaus
create table if not exists vahti_raportti (
  id bigint generated always as identity primary key,
  t timestamptz not null default now(),
  tarkistukset jsonb not null,
  katsaus jsonb,
  malli text
);
alter table vahti_raportti enable row level security;

-- Sivulle: tuoreet tarkistukset (ajetaan joka haulla) ja viimeisin katsaus
create or replace view v_vahti_nyt with (security_invoker = false) as select * from vahti_tarkistukset(false) order by jarj;
create or replace view v_vahti_raportti with (security_invoker = false) as
  select id, t, tarkistukset, katsaus, malli from vahti_raportti order by t desc limit 7;
grant select on v_vahti_nyt, v_vahti_raportti to anon, authenticated;

-- Ajastus: joka aamu klo 7.20 Helsingin aikaa (talviaika UTC+2)
do $$ begin
  perform cron.unschedule('ai-vahti') where exists (select 1 from cron.job where jobname = 'ai-vahti');
  perform cron.schedule('ai-vahti', '20 5 * * *',
    replace((select command from cron.job where jobname = 'ai-katsaus'), 'tila=katsaus', 'tila=vahti'));
end $$;
select jobname, schedule, position('tila=vahti' in command) > 0 ok from cron.job where jobname = 'ai-vahti';
