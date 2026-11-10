-- 036: Ilmoituksen napit. Vika hoidetaan suoraan puhelimesta avaamatta tutkaa.
--   ↻ Aja uudelleen  – vain ennalta hyväksytyt toimenpiteet: epäonnistunut ajo, pysähtynyt datankeruu, tietokannan siivous
--   ✓ Kuittaa        – kirjaa, että joku hoitaa (näkyy Vahdissa)
--   Avaa Vahti       – kun vika pitää tutkia
-- Jokaisella napilla on kertakäyttöinen tunniste, joka kelpaa yhteen toimenpiteeseen tunnin ajan.
-- Vahti ei aja mitään itse: ihminen hyväksyy toimenpiteen napautuksella, ja kaikki kirjataan.

create table if not exists vahti_toimenpide (
  token text primary key, laji text not null check (laji in ('aja', 'kuittaa')), k text not null, jobit text[],
  luotu timestamptz not null default now(), vanhenee timestamptz not null default now() + interval '1 hour', kaytetty timestamptz);
create table if not exists vahti_uusinta (
  id bigint generated always as identity primary key, jobname text not null, pyydetty timestamptz not null default now(),
  valmis timestamptz, ok boolean, viesti text, ilmoitettu boolean not null default false);
alter table vahti_toimenpide enable row level security;
alter table vahti_uusinta enable row level security;
alter table vahti_ilmoitus add column if not exists kuitattu timestamptz;

-- Mitkä ajot ovat ennalta hyväksyttyjä korjauksia kullekin tarkistukselle
create or replace function vahti_korjausajot(p_jarj int, p_kuvaus text) returns text[]
language sql stable security definer set search_path = public, cron as $$
  select array_agg(distinct jobname) from cron.job j where
    (p_jarj = 3 and p_kuvaus like 'rikki nyt:%' and j.jobname = any (string_to_array(substr(p_kuvaus, 12), ', ')))
    or (p_jarj = 1 and j.command like '%hfp-segmentit%')
    or (p_jarj = 2 and j.jobname = 'kooste-siivous');
$$;

-- Ajetaan erillisenä kertaluonteisena ajona (ei puhelimen pyynnön sisällä, jotta pitkäkin ajo onnistuu)
create or replace function vahti_aja_kerran(p_id bigint, p_job text) returns void
language plpgsql security definer set search_path = public, cron as $$
declare v_cmd text := (select command from cron.job where jobname = p_job);
begin
  perform cron.unschedule('vahti-uusinta-' || p_id);
  begin
    perform set_config('vahti.uusinta', '1', true);
    if v_cmd is null then raise exception 'ajoa % ei löydy', p_job; end if;
    execute v_cmd;
    update vahti_uusinta set valmis = now(), ok = true,
      viesti = case when v_cmd like '%net.http_post%' then 'käynnistetty, tulos näkyy ajolokissa' else 'onnistui' end where id = p_id;
  exception when others then
    update vahti_uusinta set valmis = now(), ok = false, viesti = left(sqlerrm, 160) where id = p_id;
  end;
end $$;

-- Puhelimen nappi kutsuu tätä (julkinen avain + kertakäyttöinen tunniste)
create or replace function vahti_toimi(p_token text) returns text
language plpgsql security definer set search_path = public, cron as $$
declare t vahti_toimenpide; v_id bigint; j text; v_jobit text := '';
begin
  update vahti_toimenpide set kaytetty = now()
    where token = p_token and kaytetty is null and vanhenee > now() returning * into t;
  if t.token is null then return 'Tunniste on jo käytetty tai vanhentunut.'; end if;

  if t.laji = 'kuittaa' then
    update vahti_ilmoitus set kuitattu = now() where k = t.k;
    perform vahti_laheta('[KUITATTU] ' || t.k, 'Hoidossa klo ' || to_char(now() at time zone 'Europe/Helsinki', 'HH24.MI') || '. Kuittaus näkyy Vahdissa.', 2, 'ok_hand');
    return 'Kuitattu';
  end if;

  foreach j in array coalesce(t.jobit, '{}') loop
    insert into vahti_uusinta (jobname) values (j) returning id into v_id;
    perform cron.schedule('vahti-uusinta-' || v_id, '* * * * *', format('select vahti_aja_kerran(%s, %L)', v_id, j));
    v_jobit := v_jobit || j || ' ';
  end loop;
  perform vahti_laheta('[AJETAAN] ' || t.k, 'Uudelleenajo käynnistyy minuutin sisällä: ' || trim(v_jobit) || '. Tuloksesta tulee ilmoitus.', 2, 'arrows_counterclockwise');
  return 'Uudelleenajo käynnistetty';
end $$;
revoke all on function vahti_toimi(text) from public;
grant execute on function vahti_toimi(text) to anon, authenticated;
revoke all on function vahti_aja_kerran(bigint, text), vahti_korjausajot(int, text) from public, anon, authenticated;

-- Lähetys napeilla
create or replace function vahti_laheta_napit(p_otsikko text, p_viesti text, p_prioriteetti int, p_tagi text, p_k text, p_jobit text[])
returns void language plpgsql security definer set search_path = public as $$
declare v_topic text := (select topic from vahti_kanava where id = 1);
  v_url text := 'https://pdbmxnmeyhifksgivnky.supabase.co/rest/v1/rpc/vahti_toimi';
  v_key text := 'sb_publishable_ZM_StZYcp6QJs5HdlqHbDA_gzQHPqVf';   -- julkinen avain, sama kuin sivulla
  v_t1 text := replace(gen_random_uuid()::text, '-', ''); v_t2 text := replace(gen_random_uuid()::text, '-', '');
  v_napit jsonb := '[]';
begin
  if v_topic is null then return; end if;
  if p_jobit is not null and cardinality(p_jobit) > 0 then
    insert into vahti_toimenpide (token, laji, k, jobit) values (v_t1, 'aja', p_k, p_jobit);
    v_napit := v_napit || jsonb_build_object('action', 'http', 'label', '↻ Aja uudelleen', 'url', v_url, 'method', 'POST',
      'headers', jsonb_build_object('apikey', v_key, 'Authorization', 'Bearer ' || v_key, 'Content-Type', 'application/json'),
      'body', jsonb_build_object('p_token', v_t1)::text, 'clear', true);
  end if;
  insert into vahti_toimenpide (token, laji, k) values (v_t2, 'kuittaa', p_k);
  v_napit := v_napit || jsonb_build_object('action', 'http', 'label', '✓ Kuittaa', 'url', v_url, 'method', 'POST',
      'headers', jsonb_build_object('apikey', v_key, 'Authorization', 'Bearer ' || v_key, 'Content-Type', 'application/json'),
      'body', jsonb_build_object('p_token', v_t2)::text, 'clear', true)
    || jsonb_build_object('action', 'view', 'label', 'Avaa Vahti', 'url', 'https://pontuskettunen-cyber.github.io/tyomaatutka/#/kehitys?l=vahti');
  perform net.http_post(url := 'https://ntfy.sh',
    body := jsonb_build_object('topic', v_topic, 'title', p_otsikko, 'message', p_viesti, 'priority', p_prioriteetti,
      'tags', jsonb_build_array(p_tagi), 'click', 'https://pontuskettunen-cyber.github.io/tyomaatutka/#/kehitys?l=vahti', 'actions', v_napit));
end $$;
revoke all on function vahti_laheta_napit(text, text, int, text, text, text[]) from public, anon, authenticated;

-- Ilmoittaja: napit hälytyksiin, uudelleenajojen tulokset, vanhat tunnisteet pois
create or replace function vahti_ilmoita() returns int language plpgsql security definer set search_path = public as $$
declare r record; u record; v_taso int; v_ed int; n int := 0; v_kayn timestamptz := pg_postmaster_start_time(); v_kayn_ed timestamptz;
  v_nimi text[] := array['', '', 'HUOMIO', 'VAKAVA', 'KRIITTINEN'];
  v_tagi text[] := array['', '', 'information_source', 'warning', 'rotating_light'];
  v_rikki text;
begin
  select kaynnistyi into v_kayn_ed from vahti_kanava where id = 1;
  if v_kayn_ed is not null and v_kayn > v_kayn_ed + interval '1 minute' then
    perform vahti_laheta_napit('[KRIITTINEN] Tietokanta käynnistyi uudelleen',
      'Kaatui ja käynnistyi klo ' || to_char(v_kayn at time zone 'Europe/Helsinki', 'HH24.MI') || '. Tarkista Vahdista, mikä ajo oli käynnissä juuri ennen.',
      5, 'rotating_light', 'Tietokanta', null);
    n := n + 1;
  end if;
  update vahti_kanava set kaynnistyi = v_kayn where id = 1;

  -- uudelleenajojen tulokset
  for u in select * from vahti_uusinta where valmis is not null and not ilmoitettu loop
    if u.ok then
      perform vahti_laheta('[AJETTU] ' || u.jobname, 'Uudelleenajo klo ' || to_char(u.valmis at time zone 'Europe/Helsinki', 'HH24.MI') || ': ' || u.viesti || '.', 2, 'white_check_mark');
    else
      perform vahti_laheta('[EI KORJAANTUNUT] ' || u.jobname, 'Uudelleenajo epäonnistui samalla tavalla: ' || u.viesti || ' Vika vaatii todennäköisesti korjauksen koodiin.', 4, 'x');
    end if;
    update vahti_uusinta set ilmoitettu = true where id = u.id; n := n + 1;
  end loop;

  for r in select * from vahti_tarkistukset(false) loop
    v_taso := vahti_taso(r.jarj, r.tila);
    select taso into v_ed from vahti_ilmoitus where k = r.k;
    v_ed := coalesce(v_ed, 0);
    v_rikki := case when r.kuvaus like 'rikki nyt:%' then initcap(substr(r.kuvaus, 1, 1)) || substr(r.kuvaus, 2) || '. (' || r.arvo || ', osa jo korjautunut.)'
                    else r.arvo || '. ' || r.kuvaus || '.' end;
    if v_taso > v_ed and v_taso >= 3 then
      perform vahti_laheta_napit('[' || v_nimi[v_taso] || '] ' || r.k, v_rikki || ' ' || vahti_ohje(r.jarj), v_taso, v_tagi[v_taso], r.k, vahti_korjausajot(r.jarj, r.kuvaus));
      n := n + 1;
    elsif v_taso = 0 and v_ed >= 3 then
      perform vahti_laheta('[KORJAUTUNUT] ' || r.k, r.arvo || '. ' || upper(left(r.kuvaus, 1)) || substr(r.kuvaus, 2) || '.', 2, 'white_check_mark'); n := n + 1;
    end if;
    insert into vahti_ilmoitus (k, tila, vakava, taso, muuttui) values (r.k, r.tila, v_taso >= 4, v_taso, now())
      on conflict (k) do update set tila = excluded.tila, vakava = excluded.vakava, taso = excluded.taso,
        muuttui = case when vahti_ilmoitus.taso is distinct from excluded.taso then now() else vahti_ilmoitus.muuttui end;
  end loop;
  delete from vahti_toimenpide where vanhenee < now() - interval '7 days';
  return n;
end $$;
revoke all on function vahti_ilmoita() from public, anon, authenticated;

-- Tarkistukset: onnistunut uudelleenajo kumoaa "rikki nyt" -tilan
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
  -- rikki = viimeisin ajastettu suoritus epäonnistui eikä sen jälkeen ole onnistunutta uudelleenajoa (036)
  select string_agg(jobname, ', ') into v_txt from (
    select distinct on (j.jobname) j.jobname, d.status, d.start_time from cron.job_run_details d join cron.job j using (jobid)
    where d.start_time > now() - interval '24 hours' and d.status in ('failed', 'succeeded') and j.jobname not like 'vahti-uusinta-%'
    order by j.jobname, d.start_time desc) x
    where status = 'failed' and not exists (select 1 from vahti_uusinta u where u.jobname = x.jobname and u.ok and u.valmis > x.start_time);
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

-- Sivulle: kuittaus näkyy tarkistuksen kuvauksessa
create or replace function vahti_nyt() returns table (jarj int, k text, tila text, arvo text, kuvaus text)
language sql stable security definer set search_path = public as $$
  select t.jarj, t.k, t.tila, t.arvo,
    t.kuvaus || case when i.kuitattu > i.muuttui and t.tila in ('virhe', 'huom')
                     then ' · kuitattu hoitoon klo ' || to_char(i.kuitattu at time zone 'Europe/Helsinki', 'HH24.MI') else '' end
  from vahti_tarkistukset(false) t left join vahti_ilmoitus i on i.k = t.k;
$$;
grant execute on function vahti_nyt() to anon, authenticated;
