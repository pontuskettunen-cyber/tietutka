-- 034: Vahti erottaa käynnissä olevan vian korjautuneesta ja ilmoittaa ylläpitäjän puhelimeen (ntfy).
-- Aiemmin 24 h:n virhelaskuri pysyi punaisena koko päivän jo korjatuista vioista (4.11.).
-- Nyt: punainen = viimeisin ajo / kutsu epäonnistui. Keltainen = virheitä 24 h:n aikana, mutta viimeisin onnistui.

create or replace function vahti_tarkistukset(p_tallenna boolean default false)
returns table (jarj int, k text, tila text, arvo text, kuvaus text)
language plpgsql security definer set search_path = public, cron as $$
#variable_conflict use_column
declare
  v_mb numeric := round(pg_database_size(current_database()) / 1048576.0);
  v_kap numeric := coalesce((select ta.v::numeric from tutka_asetus ta where ta.k = 'db_kap_mb'), 500);
  v_kasvu numeric; v_paiv numeric; v_t timestamptz; v_n int; v_m int; v_txt text; v_nyt text;
begin
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

  -- 3 ajastetut ajot: punainen vain, jos ajon viimeisin suoritus epäonnistui
  select count(*), string_agg(distinct j.jobname, ', '), max(d.start_time) into v_n, v_txt, v_t
    from cron.job_run_details d join cron.job j using (jobid)
    where d.start_time > now() - interval '24 hours' and d.status = 'failed';
  select string_agg(x.jobname, ', ') into v_nyt from (
    select distinct on (j.jobname) j.jobname, d.status from cron.job_run_details d join cron.job j using (jobid)
    where d.start_time > now() - interval '24 hours' and d.status in ('succeeded', 'failed') order by j.jobname, d.start_time desc) x
    where x.status = 'failed';
  return query select 3, 'Ajastetut ajot',
    case when v_nyt is not null then 'virhe' when v_n > 0 then 'huom' else 'ok' end,
    case when v_nyt is not null then 'epäonnistuu nyt' when v_n > 0 then 'korjautunut · viimeisin virhe ' || to_char(v_t at time zone 'Europe/Helsinki', 'HH24:MI') else '0 epäonnistunutta 24 h' end,
    case when v_nyt is not null then 'viimeisin ajo epäonnistui: ' || v_nyt
         when v_n > 0 then v_n || ' epäonnistumista 24 h (' || v_txt || '), viimeisimmät ajot onnistuivat' else 'kaikki ajot onnistuivat' end;

  -- 4 funktioiden virheet: punainen, jos funktion viimeisin ajo päättyi virheeseen
  select count(*), string_agg(distinct funktio, ', '), max(alkoi) into v_n, v_txt, v_t
    from tallennin_loki where alkoi > now() - interval '24 hours' and virhe is not null and virhe <> ''
      and virhe !~ '^(viestejä|ilman viivaa)';
  select string_agg(x.funktio, ', ') into v_nyt from (
    select distinct on (funktio) funktio, virhe from tallennin_loki where alkoi > now() - interval '24 hours' order by funktio, alkoi desc) x
    where x.virhe is not null and x.virhe <> '' and x.virhe !~ '^(viestejä|ilman viivaa)';
  return query select 4, 'Funktioiden virheet',
    case when v_nyt is not null then 'virhe' when v_n > 0 then 'huom' else 'ok' end,
    case when v_nyt is not null then 'virhe nyt' when v_n > 0 then 'korjautunut · viimeisin virhe ' || to_char(v_t at time zone 'Europe/Helsinki', 'HH24:MI') else '0 virhettä 24 h' end,
    case when v_nyt is not null then 'viimeisin ajo epäonnistui: ' || v_nyt
         when v_n > 0 then v_n || ' virhettä 24 h (' || v_txt || '), viimeisimmät ajot onnistuivat' else 'ei virheitä ajolokissa' end;

  -- 5 kielimalli: punainen, jos jonkin tehtävän viimeisin kutsu epäonnistui
  select count(*), count(*) filter (where not ok or katkesi), max(t) filter (where not ok or katkesi) into v_n, v_m, v_t
    from ai_kaytto where t > now() - interval '24 hours';
  select string_agg(x.tila, ', ') into v_nyt from (
    select distinct on (a.tila) a.tila, a.ok, a.katkesi from ai_kaytto a where a.t > now() - interval '24 hours' order by a.tila, a.t desc) x
    where not x.ok or x.katkesi;
  return query select 5, 'Kielimalli',
    case when v_nyt is not null then 'virhe' when v_m > 0 then 'huom' else 'ok' end,
    case when v_nyt is not null then 'epäonnistuu nyt' when v_m > 0 then 'korjautunut · viimeisin virhe ' || to_char(v_t at time zone 'Europe/Helsinki', 'HH24:MI') else '0 / ' || v_n || ' epäonnistui' end,
    case when v_nyt is not null then 'viimeisin kutsu epäonnistui: ' || v_nyt
         when v_m > 0 then v_m || ' / ' || v_n || ' kutsua epäonnistui 24 h, viimeisimmät onnistuivat' else 'käyttöloki, 24 h' end;

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

-- Ilmoitukset ylläpitäjän puhelimeen (ntfy). Kanavan nimi on salainen: oma taulu, ei näkymää eikä oikeuksia.
create table if not exists vahti_ilmoitus_asetus (k text primary key, v text not null);
alter table vahti_ilmoitus_asetus enable row level security;
revoke all on vahti_ilmoitus_asetus from anon, authenticated;
-- kanava asetetaan erikseen: insert into vahti_ilmoitus_asetus values ('ntfy_kanava', '<salainen>');

create table if not exists vahti_ilmoitus_tila (k text primary key, tila text not null, muuttui timestamptz not null default now());
alter table vahti_ilmoitus_tila enable row level security;
revoke all on vahti_ilmoitus_tila from anon, authenticated;

-- 5 min välein: ilmoita kun tarkistus muuttuu punaiseksi (ajoneuvodata jo keltaisena) ja kun se korjautuu.
-- Lisäksi tietokannan uudelleenkäynnistys (kaatuminen) ilmoitetaan aina.
create or replace function vahti_ilmoita() returns int language plpgsql security definer set search_path = public as $$
declare
  v_kanava text := (select v from vahti_ilmoitus_asetus where k = 'ntfy_kanava');
  r record; v_vanha text; v_halyttaa boolean; v_oli boolean; n int := 0;
  v_kaynnistyi text := to_char(pg_postmaster_start_time(), 'YYYY-MM-DD"T"HH24:MI:SS');
begin
  if v_kanava is null then return 0; end if;
  -- kaatuminen: käynnistysaika vaihtui
  select tila into v_vanha from vahti_ilmoitus_tila where k = '_kaynnistyi';
  if v_vanha is distinct from v_kaynnistyi then
    if v_vanha is not null then
      perform net.http_post(url := 'https://ntfy.sh/', body := jsonb_build_object('topic', v_kanava, 'priority', 5, 'tags', jsonb_build_array('rotating_light'),
        'title', 'Työmaatutka: tietokanta käynnistyi uudelleen',
        'message', 'Kanta kaatui ja käynnistyi ' || to_char(pg_postmaster_start_time() at time zone 'Europe/Helsinki', 'DD.MM. HH24:MI') || '. Tarkista Vahti.'));
      n := n + 1;
    end if;
    insert into vahti_ilmoitus_tila (k, tila) values ('_kaynnistyi', v_kaynnistyi) on conflict (k) do update set tila = excluded.tila, muuttui = now();
  end if;

  for r in select * from vahti_tarkistukset(false) loop
    v_halyttaa := r.tila = 'virhe' or (r.k = 'Ajoneuvodata' and r.tila = 'huom');
    select tila = 'halyttaa' into v_oli from vahti_ilmoitus_tila where k = r.k;
    if v_halyttaa and not coalesce(v_oli, false) then
      perform net.http_post(url := 'https://ntfy.sh/', body := jsonb_build_object('topic', v_kanava, 'priority', 4, 'tags', jsonb_build_array('warning'),
        'title', 'Työmaatutka: ' || r.k, 'message', r.arvo || ' – ' || r.kuvaus));
      n := n + 1;
    elsif not v_halyttaa and coalesce(v_oli, false) then
      perform net.http_post(url := 'https://ntfy.sh/', body := jsonb_build_object('topic', v_kanava, 'priority', 2, 'tags', jsonb_build_array('white_check_mark'),
        'title', 'Korjautui: ' || r.k, 'message', r.arvo));
      n := n + 1;
    end if;
    insert into vahti_ilmoitus_tila (k, tila) values (r.k, case when v_halyttaa then 'halyttaa' else 'ok' end)
      on conflict (k) do update set tila = excluded.tila, muuttui = case when vahti_ilmoitus_tila.tila <> excluded.tila then now() else vahti_ilmoitus_tila.muuttui end;
  end loop;
  return n;
end $$;
revoke all on function vahti_ilmoita() from public, anon, authenticated;

select cron.schedule('vahti-ilmoitus', '*/5 * * * *', $$select vahti_ilmoita()$$);
