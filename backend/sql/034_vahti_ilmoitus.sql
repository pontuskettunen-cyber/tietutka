-- 034: Vahti erottaa käynnissä olevan vian korjautuneesta, ja vakavista vioista tulee ilmoitus puhelimeen (ntfy).
-- Vahti ei edelleenkään korjaa itse: se havaitsee, ilmoittaa ja ehdottaa. Ihminen korjaa.

create or replace function vahti_tarkistukset(p_tallenna boolean default false)
returns table (jarj int, k text, tila text, arvo text, kuvaus text)
language plpgsql security definer set search_path = public, cron as $$
#variable_conflict use_column
declare
  v_mb numeric := round(pg_database_size(current_database()) / 1048576.0);
  v_kap numeric := coalesce((select ta.v::numeric from tutka_asetus ta where ta.k = 'db_kap_mb'), 500);
  v_kasvu numeric; v_paiv numeric; v_t timestamptz; v_n int; v_m int; v_k int; v_txt text;
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

  -- 3 ajastetut ajot (vain ajon nimi, ei komentoa). Rikki = ajon viimeisin suoritus epäonnistui; korjautunut = epäonnistui 24 h aikana, mutta viimeisin onnistui.
  select count(*), max(d.start_time) into v_n, v_t
    from cron.job_run_details d where d.start_time > now() - interval '24 hours' and d.status = 'failed';
  select string_agg(jobname, ', ') into v_txt from (
    select distinct on (j.jobname) j.jobname, d.status from cron.job_run_details d join cron.job j using (jobid)
    where d.start_time > now() - interval '24 hours' and d.status in ('failed', 'succeeded')
    order by j.jobname, d.start_time desc) x where status = 'failed';
  return query select 3, 'Ajastetut ajot', case when v_txt is not null then 'virhe' when v_n > 0 then 'korjautunut' else 'ok' end,
    v_n || ' epäonnistunutta 24 h',
    case when v_txt is not null then 'rikki nyt: ' || v_txt
         when v_n > 0 then 'viimeisin klo ' || to_char(v_t at time zone 'Europe/Helsinki', 'HH24.MI') || ', ajot onnistuneet sen jälkeen'
         else 'kaikki ajot onnistuivat' end;

  -- 4 funktioiden virheet. Rikki = funktion viimeisin ajo päättyi virheeseen (keruufunktiot kirjaavat virhe-kenttään myös tilastoja).
  select count(*), max(alkoi) into v_n, v_t
    from tallennin_loki where alkoi > now() - interval '24 hours' and virhe is not null and virhe <> '' and virhe !~ '^(viestejä|ilman viivaa)';
  select string_agg(funktio, ', ') into v_txt from (
    select distinct on (funktio) funktio, virhe from tallennin_loki where alkoi > now() - interval '24 hours'
    order by funktio, alkoi desc) x
    where virhe is not null and virhe <> '' and virhe !~ '^(viestejä|ilman viivaa)';
  return query select 4, 'Funktioiden virheet', case when v_txt is not null then 'virhe' when v_n > 0 then 'korjautunut' else 'ok' end,
    v_n || ' virhettä 24 h',
    case when v_txt is not null then 'rikki nyt: ' || v_txt
         when v_n > 0 then 'viimeisin klo ' || to_char(v_t at time zone 'Europe/Helsinki', 'HH24.MI') || ', ajot onnistuneet sen jälkeen'
         else 'ei virheitä ajolokissa' end;

  -- 5 kielimalli. Rikki = jokin kolmesta viimeisimmästä kutsusta epäonnistui.
  select count(*), count(*) filter (where not ok or katkesi), max(t) filter (where not ok or katkesi) into v_n, v_m, v_t
    from ai_kaytto where t > now() - interval '24 hours';
  select count(*) filter (where not ok or katkesi) into v_k from (select ok, katkesi from ai_kaytto order by t desc limit 3) x;
  return query select 5, 'Kielimalli', case when v_k > 0 then 'virhe' when v_m > 0 then 'korjautunut' else 'ok' end,
    v_m || ' / ' || v_n || ' kutsua epäonnistui tai katkesi',
    case when v_k > 0 then 'rikki nyt: ' || v_k || ' kolmesta viimeisestä kutsusta epäonnistui'
         when v_m > 0 then 'viimeisin klo ' || to_char(v_t at time zone 'Europe/Helsinki', 'HH24.MI') || ', kutsut onnistuneet sen jälkeen'
         else 'käyttöloki, 24 h' end;

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

-- Ilmoituskanava: ntfy-topikin nimi on salainen (kuka tahansa nimen tietävä voisi lukea ilmoitukset), siksi oma taulu ilman oikeuksia.
create table if not exists vahti_kanava (id int primary key default 1 check (id = 1), topic text not null, kaynnistyi timestamptz);
alter table vahti_kanava enable row level security;
create table if not exists vahti_ilmoitus (k text primary key, tila text, vakava boolean, muuttui timestamptz default now());
alter table vahti_ilmoitus enable row level security;

create or replace function vahti_laheta(p_otsikko text, p_viesti text, p_prioriteetti int, p_tagi text)
returns void language plpgsql security definer set search_path = public as $$
declare v_topic text := (select topic from vahti_kanava where id = 1);
begin
  if v_topic is null then return; end if;
  perform net.http_post(url := 'https://ntfy.sh',
    body := jsonb_build_object('topic', v_topic, 'title', p_otsikko, 'message', p_viesti, 'priority', p_prioriteetti,
      'tags', jsonb_build_array(p_tagi), 'click', 'https://pontuskettunen-cyber.github.io/tyomaatutka/#/kehitys?l=vahti'));
end $$;

-- Ajetaan 5 min välein: ilmoitus kun tarkistus muuttuu vakavaksi ja kun se korjautuu, sekä kun tietokanta on käynnistynyt uudelleen.
create or replace function vahti_ilmoita() returns int language plpgsql security definer set search_path = public as $$
declare r record; v_vakava boolean; v_ed boolean; n int := 0; v_kayn timestamptz := pg_postmaster_start_time(); v_kayn_ed timestamptz;
begin
  select kaynnistyi into v_kayn_ed from vahti_kanava where id = 1;
  if v_kayn_ed is not null and v_kayn > v_kayn_ed + interval '1 minute' then
    perform vahti_laheta('Työmaatutka: tietokanta käynnistyi uudelleen',
      'Klo ' || to_char(v_kayn at time zone 'Europe/Helsinki', 'HH24.MI') || '. Tarkista Vahdista, mikä ajo oli käynnissä.', 4, 'warning');
    n := n + 1;
  end if;
  update vahti_kanava set kaynnistyi = v_kayn where id = 1;

  for r in select * from vahti_tarkistukset(false) loop
    v_vakava := r.tila = 'virhe' or (r.jarj in (1, 2) and r.tila = 'huom');
    select vakava into v_ed from vahti_ilmoitus where k = r.k;
    if v_vakava and not coalesce(v_ed, false) then
      perform vahti_laheta('Työmaatutka: ' || r.k, r.arvo || '. ' || r.kuvaus, 4, 'warning'); n := n + 1;
    elsif not v_vakava and coalesce(v_ed, false) then
      perform vahti_laheta('Korjautunut: ' || r.k, r.arvo || '. ' || r.kuvaus, 2, 'white_check_mark'); n := n + 1;
    end if;
    insert into vahti_ilmoitus (k, tila, vakava, muuttui) values (r.k, r.tila, v_vakava, now())
      on conflict (k) do update set tila = excluded.tila, vakava = excluded.vakava,
        muuttui = case when vahti_ilmoitus.vakava is distinct from excluded.vakava then now() else vahti_ilmoitus.muuttui end;
  end loop;
  return n;
end $$;
revoke all on function vahti_ilmoita(), vahti_laheta(text, text, int, text) from public, anon, authenticated;

do $$ begin
  perform cron.unschedule('vahti-ilmoita') where exists (select 1 from cron.job where jobname = 'vahti-ilmoita');
  perform cron.schedule('vahti-ilmoita', '2-59/5 * * * *', $c$select vahti_ilmoita()$c$);
end $$;
