-- 037: Hälytyslista rakennusautomaation mallilla (Fidelix, Ouman, Desigo) ja ISA-18.2 / EEMUA 191 -periaatteilla.
--
--   Luokat       A kriittinen · B vakava · C huomio. Ilmoitus puhelimeen vain, kun luokka nousee.
--   Elinkaari    aktiivinen -> kuitattu -> poistunut. Poistunut mutta kuittaamaton jää listalle.
--   Aikajana     jokainen muutos kirjataan (alkoi, ilmoitettu, kuitattu, ajettu uudelleen, poistui).
--   Hiljennys    tunnettu vika 4 h ilman ilmoituksia (ISA-18.2 "shelving").
--   Värinänesto  sama vika 30 min sisällä avaa saman rivin uudelleen, ei uutta ilmoitusta.
--   Juurisyy     tietokannan kaatumisen jälkeiset järjestelmähälytykset niputetaan sen alle (first-out).
--   Tulvasuoja   yli 3 uutta hälytystä kerralla -> yksi koosteilmoitus.
--   Lähteet      järjestelmä (Vahdin tarkistukset) ja liikenne (työmaa hidastaa nyt tavallista enemmän).
--   Julkisuus    lista on julkinen; virheviestit näkyvät vain ilmoituksen tunnisteella avattavassa kortissa.

create table if not exists halytys (
  id bigint generated always as identity primary key,
  avain text not null,
  lahde text not null check (lahde in ('jarjestelma', 'liikenne')),
  luokka char(1) not null check (luokka in ('A', 'B', 'C')),
  kohde text not null, otsikko text not null, kuvaus text, ohje text,
  yksityinen jsonb not null default '{}',
  lupa_id text, linjat text[],
  alkoi timestamptz not null default now(), poistui timestamptz, kuitattu timestamptz,
  hiljennetty_asti timestamptz, toistot int not null default 0,
  ilmoitettu_luokka char(1), syy_id bigint references halytys (id) on delete set null,
  muuttui timestamptz not null default now());
create unique index if not exists halytys_avain_auki on halytys (avain) where poistui is null;
create index if not exists halytys_alkoi on halytys (alkoi desc);

create table if not exists halytys_tapahtuma (
  id bigint generated always as identity primary key,
  halytys_id bigint not null references halytys (id) on delete cascade,
  t timestamptz not null default now(), laji text not null, kuvaus text, yksityinen text);
create index if not exists halytys_tapahtuma_h on halytys_tapahtuma (halytys_id, t);

-- liikenteen vertailutaso: työmaan pysäkkivälien tavallinen hidastuma kullakin tunnilla (14 vrk)
create table if not exists liik_pohja (
  lupa_id text, hh int, n int, ka real, sd real, paivitetty timestamptz not null default now(), primary key (lupa_id, hh));

alter table halytys enable row level security;
alter table halytys_tapahtuma enable row level security;
alter table liik_pohja enable row level security;

alter table vahti_toimenpide add column if not exists halytys_id bigint;
alter table vahti_toimenpide drop constraint if exists vahti_toimenpide_laji_check;
alter table vahti_toimenpide add constraint vahti_toimenpide_laji_check check (laji in ('aja', 'kuittaa', 'hiljenna', 'kortti'));
alter table vahti_uusinta add column if not exists halytys_id bigint;

-- ---------------------------------------------------------------- lähetys
create or replace function halytys_laheta(p_otsikko text, p_viesti text, p_prio int, p_tagi text, p_click text, p_napit jsonb default null)
returns void language plpgsql security definer set search_path = public as $$
declare v_topic text := (select topic from vahti_kanava where id = 1);
begin
  if v_topic is null then return; end if;
  perform net.http_post(url := 'https://ntfy.sh',
    body := jsonb_build_object('topic', v_topic, 'title', p_otsikko, 'message', p_viesti, 'priority', p_prio,
      'tags', jsonb_build_array(p_tagi), 'click', coalesce(p_click, 'https://pontuskettunen-cyber.github.io/tyomaatutka/#/halytykset'))
      || case when p_napit is not null and jsonb_array_length(p_napit) > 0 then jsonb_build_object('actions', p_napit) else '{}' end);
end $$;

create or replace function halytys_tunniste() returns text language sql volatile as $$
  select replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '');
$$;

-- Ilmoitus yhdestä hälytyksestä: napautus avaa kortin, napit hoitavat asian puhelimesta
create or replace function halytys_ilmoita_rivi(p_id bigint) returns void
language plpgsql security definer set search_path = public as $$
declare h halytys; v_kortti text := halytys_tunniste(); v_url text; v_napit jsonb := '[]'; v_ajot int;
  v_api text := 'https://pdbmxnmeyhifksgivnky.supabase.co/rest/v1/rpc/vahti_toimi';
  v_key text := 'sb_publishable_ZM_StZYcp6QJs5HdlqHbDA_gzQHPqVf';   -- julkinen avain, sama kuin sivulla
  v_t text; v_laji text;
begin
  select * into h from halytys where id = p_id;
  v_url := 'https://pontuskettunen-cyber.github.io/tyomaatutka/#/halytykset?h=' || h.id || '&t=' || v_kortti;
  insert into vahti_toimenpide (token, laji, k, halytys_id, vanhenee) values (v_kortti, 'kortti', h.avain, h.id, now() + interval '24 hours');
  v_ajot := jsonb_array_length(coalesce(h.yksityinen -> 'ajot', '[]'));

  foreach v_laji in array case when h.lahde = 'liikenne' then array['kuittaa']
                               when v_ajot > 0 then array['aja', 'kuittaa'] else array['kuittaa', 'hiljenna'] end loop
    v_t := halytys_tunniste();
    insert into vahti_toimenpide (token, laji, k, halytys_id) values (v_t, v_laji, h.avain, h.id);
    v_napit := v_napit || jsonb_build_object('action', 'http',
      'label', case v_laji when 'aja' then '↻ Aja uudelleen' when 'kuittaa' then '✓ Kuittaa' else 'Hiljennä 4 h' end,
      'url', v_api, 'method', 'POST',
      'headers', jsonb_build_object('apikey', v_key, 'Authorization', 'Bearer ' || v_key, 'Content-Type', 'application/json'),
      'body', jsonb_build_object('p_token', v_t)::text, 'clear', true);
  end loop;
  v_napit := v_napit || jsonb_build_object('action', 'view', 'label', 'Avaa kortti', 'url', v_url);
  if h.lahde = 'liikenne' and h.lupa_id is not null then
    v_napit := v_napit || jsonb_build_object('action', 'view', 'label', 'Kartalla',
      'url', 'https://pontuskettunen-cyber.github.io/tyomaatutka/#/?l=' || h.lupa_id);
  end if;

  perform halytys_laheta(
    '[' || case h.luokka when 'A' then 'KRIITTINEN' when 'B' then 'VAKAVA' else 'HUOMIO' end || '] ' || h.otsikko,
    h.kuvaus || coalesce(' ' || h.ohje, ''),
    case h.luokka when 'A' then 5 when 'B' then 4 else 3 end,
    case when h.luokka = 'A' then 'rotating_light' when h.luokka = 'B' then 'warning' when h.lahde = 'liikenne' then 'bus' else 'information_source' end,
    v_url, v_napit);
  update halytys set ilmoitettu_luokka = h.luokka where id = h.id;
  insert into halytys_tapahtuma (halytys_id, laji, kuvaus) values (h.id, 'ilmoitettu', 'Ilmoitus puhelimeen, luokka ' || h.luokka);
end $$;

-- ---------------------------------------------------------------- avaus ja sulkeminen
create or replace function halytys_avaa(p_avain text, p_lahde text, p_luokka char, p_kohde text, p_otsikko text, p_kuvaus text,
  p_ohje text, p_yks jsonb, p_lupa text, p_linjat text[]) returns bigint
language plpgsql security definer set search_path = public as $$
declare v halytys; v_syy bigint;
begin
  select * into v from halytys where avain = p_avain and poistui is null;
  if found then
    update halytys set luokka = p_luokka, kohde = p_kohde, otsikko = p_otsikko, kuvaus = p_kuvaus, ohje = p_ohje, yksityinen = p_yks,
      linjat = p_linjat, muuttui = case when p_luokka <> v.luokka or p_kuvaus is distinct from v.kuvaus then now() else v.muuttui end
      where id = v.id;
    if p_luokka < v.luokka then
      insert into halytys_tapahtuma (halytys_id, laji, kuvaus) values (v.id, 'nousi', 'Luokka nousi ' || v.luokka || ' → ' || p_luokka);
    elsif p_luokka > v.luokka then
      insert into halytys_tapahtuma (halytys_id, laji, kuvaus) values (v.id, 'laski', 'Luokka laski ' || v.luokka || ' → ' || p_luokka);
    end if;
    return v.id;
  end if;

  -- värinänesto: sama vika palasi 30 min sisällä -> sama rivi takaisin auki
  select * into v from halytys where avain = p_avain and poistui > now() - interval '30 minutes' order by poistui desc limit 1;
  if found then
    update halytys set poistui = null, kuitattu = null, toistot = toistot + 1, luokka = p_luokka, kohde = p_kohde, otsikko = p_otsikko,
      kuvaus = p_kuvaus, ohje = p_ohje, yksityinen = p_yks, linjat = p_linjat, muuttui = now() where id = v.id;
    insert into halytys_tapahtuma (halytys_id, laji, kuvaus) values (v.id, 'palasi', 'Vika palasi ' ||
      round(extract(epoch from now() - v.poistui) / 60) || ' min poistumisen jälkeen (toistunut ' || (v.toistot + 1) || ' kertaa)');
    return v.id;
  end if;

  -- juurisyy: tietokannan kaatumisen jälkeiset järjestelmähälytykset ovat sen seurauksia
  if p_lahde = 'jarjestelma' and p_avain <> 'tietokanta' then
    select id into v_syy from halytys where avain = 'tietokanta' and poistui is null and alkoi > now() - interval '30 minutes';
  end if;

  insert into halytys (avain, lahde, luokka, kohde, otsikko, kuvaus, ohje, yksityinen, lupa_id, linjat, syy_id)
    values (p_avain, p_lahde, p_luokka, p_kohde, p_otsikko, p_kuvaus, p_ohje, p_yks, p_lupa, p_linjat, v_syy)
    returning * into v;
  insert into halytys_tapahtuma (halytys_id, laji, kuvaus) values (v.id, 'alkoi',
    case when v_syy is not null then 'Hälytys alkoi (seurausta tietokannan uudelleenkäynnistyksestä)' else 'Hälytys alkoi' end);
  return v.id;
end $$;

create or replace function halytys_sulje(p_avain text, p_syy text) returns void
language plpgsql security definer set search_path = public as $$
declare h halytys;
begin
  for h in update halytys set poistui = now(), muuttui = now() where avain = p_avain and poistui is null returning * loop
    insert into halytys_tapahtuma (halytys_id, laji, kuvaus) values (h.id, 'poistui', 'Poistui: ' || p_syy);
    if h.lahde = 'jarjestelma' and h.ilmoitettu_luokka in ('A', 'B') and h.syy_id is null then
      perform halytys_laheta('[KORJAUTUNUT] ' || h.otsikko, upper(left(p_syy, 1)) || substr(p_syy, 2) || '.', 2, 'white_check_mark',
        'https://pontuskettunen-cyber.github.io/tyomaatutka/#/halytykset?h=' || h.id);
    end if;
  end loop;
end $$;

-- ---------------------------------------------------------------- toimenpiteet
create or replace function halytys_tee(p_id bigint, p_toimi text, p_mista text) returns text
language plpgsql security definer set search_path = public, cron as $$
declare h halytys; v_ajot text[]; j text; v_id bigint; v_lista text := '';
  v_klo text := to_char(now() at time zone 'Europe/Helsinki', 'HH24.MI');
begin
  select * into h from halytys where id = p_id;
  if not found then return 'Hälytystä ei löydy.'; end if;

  if p_toimi = 'kuittaa' then
    if h.kuitattu is not null then return 'Oli jo kuitattu klo ' || to_char(h.kuitattu at time zone 'Europe/Helsinki', 'HH24.MI') || '.'; end if;
    update halytys set kuitattu = now(), muuttui = now() where id = p_id;
    insert into halytys_tapahtuma (halytys_id, laji, kuvaus) values (p_id, 'kuitattu', 'Kuitattu hoitoon ' || p_mista);
    perform halytys_laheta('[KUITATTU] ' || h.otsikko, 'Hoidossa klo ' || v_klo || '. Kuittaus näkyy hälytyslistalla.', 2, 'ok_hand',
      'https://pontuskettunen-cyber.github.io/tyomaatutka/#/halytykset?h=' || p_id);
    return 'Kuitattu klo ' || v_klo;

  elsif p_toimi = 'hiljenna' then
    update halytys set hiljennetty_asti = now() + interval '4 hours', kuitattu = coalesce(kuitattu, now()), muuttui = now() where id = p_id;
    insert into halytys_tapahtuma (halytys_id, laji, kuvaus) values (p_id, 'hiljennetty',
      'Hiljennetty 4 tunniksi ' || p_mista || ' (klo ' || to_char((now() + interval '4 hours') at time zone 'Europe/Helsinki', 'HH24.MI') || ' asti)');
    return 'Hiljennetty klo ' || to_char((now() + interval '4 hours') at time zone 'Europe/Helsinki', 'HH24.MI') || ' asti';

  elsif p_toimi = 'aja' then
    v_ajot := array(select jsonb_array_elements_text(coalesce(h.yksityinen -> 'ajot', '[]')));
    if cardinality(v_ajot) = 0 then return 'Tälle hälytykselle ei ole ennalta hyväksyttyä uudelleenajoa.'; end if;
    if exists (select 1 from vahti_uusinta where halytys_id = p_id and valmis is null) then return 'Uudelleenajo on jo käynnissä.'; end if;
    foreach j in array v_ajot loop
      insert into vahti_uusinta (jobname, halytys_id) values (j, p_id) returning id into v_id;
      perform cron.schedule('vahti-uusinta-' || v_id, '* * * * *', format('select vahti_aja_kerran(%s, %L)', v_id, j));
      v_lista := v_lista || j || ', ';
    end loop;
    v_lista := rtrim(v_lista, ', ');
    insert into halytys_tapahtuma (halytys_id, laji, kuvaus) values (p_id, 'uudelleenajo', 'Uudelleenajo pyydetty ' || p_mista || ': ' || v_lista);
    perform halytys_laheta('[AJETAAN] ' || h.otsikko, 'Uudelleenajo käynnistyy minuutin sisällä: ' || v_lista || '. Tuloksesta tulee ilmoitus.',
      2, 'arrows_counterclockwise', 'https://pontuskettunen-cyber.github.io/tyomaatutka/#/halytykset?h=' || p_id);
    return 'Uudelleenajo käynnistetty: ' || v_lista;
  end if;
  return 'Tuntematon toimenpide.';
end $$;

-- Puhelimen napit (kertakäyttöinen tunniste, 1 h)
create or replace function vahti_toimi(p_token text) returns text
language plpgsql security definer set search_path = public as $$
declare t vahti_toimenpide;
begin
  update vahti_toimenpide set kaytetty = now()
    where token = p_token and laji <> 'kortti' and kaytetty is null and vanhenee > now() returning * into t;
  if t.token is null or t.halytys_id is null then return 'Tunniste on jo käytetty tai vanhentunut.'; end if;
  return halytys_tee(t.halytys_id, t.laji, 'ilmoituksesta');
end $$;

-- Kortti (ilmoituksen linkki, tunniste voimassa 24 h)
create or replace function halytys_kortti(p_id bigint, p_t text) returns jsonb
language sql stable security definer set search_path = public as $$
  select to_jsonb(h)
    || jsonb_build_object(
      'tapahtumat', (select jsonb_agg(jsonb_build_object('t', e.t, 'laji', e.laji, 'kuvaus', e.kuvaus, 'yksityinen', e.yksityinen) order by e.t)
                     from halytys_tapahtuma e where e.halytys_id = h.id),
      'aiemmat', (select jsonb_agg(jsonb_build_object('alkoi', o.alkoi, 'poistui', o.poistui, 'luokka', o.luokka, 'toistot', o.toistot) order by o.alkoi desc)
                  from (select * from halytys o where o.avain = h.avain and o.id <> h.id and o.alkoi > now() - interval '30 days' order by o.alkoi desc limit 10) o),
      'uusinta_kaynnissa', exists (select 1 from vahti_uusinta u where u.halytys_id = h.id and u.valmis is null),
      'voimassa', t.vanhenee)
  from halytys h join vahti_toimenpide t on t.halytys_id = h.id and t.token = p_t and t.laji = 'kortti' and t.vanhenee > now()
  where h.id = p_id;
$$;

create or replace function halytys_toimi(p_id bigint, p_t text, p_toimi text) returns text
language plpgsql security definer set search_path = public as $$
begin
  if p_toimi not in ('kuittaa', 'aja', 'hiljenna') then return 'Tuntematon toimenpide.'; end if;
  if not exists (select 1 from vahti_toimenpide where token = p_t and laji = 'kortti' and halytys_id = p_id and vanhenee > now()) then
    return 'Kortin tunniste on vanhentunut. Avaa uusin ilmoitus.';
  end if;
  return halytys_tee(p_id, p_toimi, 'kortista');
end $$;

-- Julkinen lista: ei virheviestejä eikä tunnisteita
create or replace function halytykset_lista() returns jsonb
language sql stable security definer set search_path = public as $$
  with r as (
    select h.* from halytys h
    where h.poistui is null or h.poistui > now() - interval '7 days' or (h.kuitattu is null and h.alkoi > now() - interval '30 days'))
  select jsonb_build_object(
    'nyt', now(),
    'rivit', coalesce((select jsonb_agg(jsonb_build_object(
        'id', r.id, 'avain', r.avain, 'lahde', r.lahde, 'luokka', r.luokka, 'kohde', r.kohde, 'otsikko', r.otsikko, 'kuvaus', r.kuvaus,
        'ohje', r.ohje, 'lupa_id', r.lupa_id, 'linjat', r.linjat, 'alkoi', r.alkoi, 'poistui', r.poistui, 'kuitattu', r.kuitattu,
        'hiljennetty_asti', r.hiljennetty_asti, 'toistot', r.toistot, 'syy_id', r.syy_id, 'ilmoitettu', r.ilmoitettu_luokka is not null,
        'ajettavissa', jsonb_array_length(coalesce(r.yksityinen -> 'ajot', '[]')) > 0,
        'kertaa7', (select count(*) + coalesce(sum(o.toistot), 0) from halytys o where o.avain = r.avain and o.alkoi > now() - interval '7 days'),
        'tapahtumat', (select jsonb_agg(jsonb_build_object('t', e.t, 'laji', e.laji, 'kuvaus', e.kuvaus) order by e.t)
                       from halytys_tapahtuma e where e.halytys_id = r.id))
      order by (r.poistui is null) desc, r.luokka, r.alkoi desc) from r), '[]'),
    'mittarit', jsonb_build_object(
      'vrk', (select count(*) from halytys where alkoi > now() - interval '24 hours'),
      'vrk7', (select count(*) from halytys where alkoi > now() - interval '7 days'),
      'kuittaus_min', (select round(extract(epoch from percentile_cont(0.5) within group (order by kuitattu - alkoi)) / 60)
                       from halytys where kuitattu is not null and alkoi > now() - interval '7 days'),
      'pitkaaikaiset', (select count(*) from halytys where poistui is null and alkoi < now() - interval '24 hours'),
      'tulvat7', (select count(*) from halytys_tapahtuma where laji = 'tulva' and t > now() - interval '7 days'),
      'toistuvat', (select jsonb_agg(x) from (
          select avain, max(kohde) kohde, max(otsikko) otsikko, count(*) + sum(toistot) kertaa
          from halytys where alkoi > now() - interval '7 days' group by avain
          having count(*) + sum(toistot) >= 2 order by 4 desc limit 3) x)));
$$;

-- ---------------------------------------------------------------- lähteet
create or replace function vahti_virheet(p_jarj int, p_ajot text[]) returns jsonb
language sql stable security definer set search_path = public, cron as $$
  select case p_jarj
    when 3 then (select jsonb_agg(jsonb_build_object('mika', x.jobname, 'klo', to_char(x.start_time at time zone 'Europe/Helsinki', 'DD.MM. HH24.MI'),
                   'viesti', left(coalesce(x.return_message, ''), 400)))
                 from (select distinct on (j.jobname) j.jobname, d.start_time, d.return_message from cron.job_run_details d join cron.job j using (jobid)
                       where d.status = 'failed' and d.start_time > now() - interval '24 hours' and j.jobname = any (coalesce(p_ajot, '{}'))
                       order by j.jobname, d.start_time desc) x)
    when 4 then (select jsonb_agg(jsonb_build_object('mika', x.funktio, 'klo', to_char(x.alkoi at time zone 'Europe/Helsinki', 'DD.MM. HH24.MI'),
                   'viesti', left(x.virhe, 400)))
                 from (select distinct on (funktio) funktio, alkoi, virhe from tallennin_loki where alkoi > now() - interval '24 hours'
                       order by funktio, alkoi desc) x
                 where x.virhe is not null and x.virhe <> '' and x.virhe !~ '^(viestejä|ilman viivaa)')
    when 5 then (select jsonb_agg(jsonb_build_object('mika', coalesce(x.tila, '') || ' · ' || coalesce(x.malli, ''),
                   'klo', to_char(x.t at time zone 'Europe/Helsinki', 'DD.MM. HH24.MI'),
                   'viesti', left(coalesce(x.virhe, case when x.katkesi then 'vastaus katkesi' else '' end), 400)))
                 from (select * from ai_kaytto where not ok or katkesi order by t desc limit 3) x)
  end;
$$;

create or replace function liik_pohja_paivita() returns int
language plpgsql security definer set search_path = public as $$
begin
  delete from liik_pohja;
  insert into liik_pohja (lupa_id, hh, n, ka, sd)
  select lupa_id, hh, sum(n), sum(s) / sum(n), sqrt(greatest(sum(s2) / sum(n) - power(sum(s) / sum(n), 2), 1))
  from (select ls.lupa_id, extract(hour from h.t at time zone 'Europe/Helsinki')::int hh, count(*) n, sum(h.ddl) s, sum(h.ddl * h.ddl) s2
        from lupa_segmentit ls join seg_havainto h on h.from_stop = ls.from_stop and h.to_stop = ls.to_stop
        where h.t > now() - interval '14 days' and h.t < now() - interval '1 hour' and h.ddl is not null
        group by 1, 2) x
  group by 1, 2 having sum(n) >= 30;
  return (select count(*) from liik_pohja);
end $$;

-- Työmaan pysäkkivälit viimeisen tunnin aikana verrattuna samaan kellonaikaan tavallisesti
create or replace function liik_havainnot() returns table (lupa_id text, n int, nyt real, pohja real, z real, ero real)
language sql stable security definer set search_path = public as $$
  select p.lupa_id, x.n, x.ka, p.ka, ((x.ka - p.ka) / (p.sd / sqrt(x.n)))::real, (x.ka - p.ka)::real
  from (select ls.lupa_id, count(*)::int n, avg(h.ddl)::real ka
        from lupa_segmentit ls join seg_havainto h on h.from_stop = ls.from_stop and h.to_stop = ls.to_stop
        where h.t > now() - interval '60 minutes' and h.ddl is not null group by 1) x
  join liik_pohja p on p.lupa_id = x.lupa_id and p.hh = extract(hour from now() at time zone 'Europe/Helsinki')::int
  where x.n >= 4;
$$;

-- ---------------------------------------------------------------- ajo (5 min välein Vahdin ajastuksella)
create or replace function halytys_ajo() returns int
language plpgsql security definer set search_path = public, cron as $$
declare r record; u record; h record; v_taso int; n int := 0;
  v_kayn timestamptz := pg_postmaster_start_time(); v_kayn_ed timestamptz;
  v_ajot text[]; v_osoite text; v_linjat text[]; v_uudet bigint[]; v_auki text[] := '{}'; v_id bigint;
  v_hh int := extract(hour from now() at time zone 'Europe/Helsinki');
begin
  -- liikenteen vertailutaso kerran yössä
  if v_hh = 3 and coalesce((select max(paivitetty) from liik_pohja), '-infinity') < now() - interval '20 hours' then
    perform liik_pohja_paivita();
  end if;

  -- 1 tietokanta käynnistyi uudelleen: A-luokka ja juurisyy muille
  select kaynnistyi into v_kayn_ed from vahti_kanava where id = 1;
  if v_kayn_ed is not null and v_kayn > v_kayn_ed + interval '1 minute' then
    perform halytys_avaa('tietokanta', 'jarjestelma', 'A', 'Työmaatutka', 'Tietokanta käynnistyi uudelleen',
      'Tietokanta kaatui ja käynnistyi klo ' || to_char(v_kayn at time zone 'Europe/Helsinki', 'HH24.MI') || '.',
      'Tarkista ajolokista, mikä raskas ajo oli käynnissä juuri ennen. Seuraavan puolen tunnin järjestelmähälytykset niputetaan tämän alle.',
      jsonb_build_object('kaynnistyi', v_kayn), null, null);
  end if;
  update vahti_kanava set kaynnistyi = v_kayn where id = 1;
  if exists (select 1 from halytys where avain = 'tietokanta' and poistui is null and alkoi < now() - interval '30 minutes') then
    perform halytys_sulje('tietokanta', 'kertaluonteinen tapahtuma, suljettu automaattisesti 30 min kuluttua');
  end if;

  -- 2 uudelleenajojen tulokset
  for u in select * from vahti_uusinta where valmis is not null and not ilmoitettu loop
    if u.halytys_id is not null then
      insert into halytys_tapahtuma (halytys_id, laji, kuvaus, yksityinen) values (u.halytys_id,
        case when u.ok then 'ajettu' else 'ei_korjaantunut' end,
        case when u.ok then 'Uudelleenajo ' || u.jobname || ': ' || u.viesti
             else 'Uudelleenajo ' || u.jobname || ' epäonnistui. Vika vaatii todennäköisesti korjauksen koodiin.' end,
        case when u.ok then null else u.viesti end);
    end if;
    if u.ok then
      perform halytys_laheta('[AJETTU] ' || u.jobname, 'Uudelleenajo klo ' || to_char(u.valmis at time zone 'Europe/Helsinki', 'HH24.MI') || ': ' || u.viesti || '.',
        2, 'white_check_mark', 'https://pontuskettunen-cyber.github.io/tyomaatutka/#/halytykset' || coalesce('?h=' || u.halytys_id, ''));
    else
      perform halytys_laheta('[EI KORJAANTUNUT] ' || u.jobname, 'Uudelleenajo epäonnistui samalla tavalla. Vika vaatii todennäköisesti korjauksen koodiin.',
        4, 'x', 'https://pontuskettunen-cyber.github.io/tyomaatutka/#/halytykset' || coalesce('?h=' || u.halytys_id, ''));
    end if;
    update vahti_uusinta set ilmoitettu = true where id = u.id;
    n := n + 1;
  end loop;

  -- 3 järjestelmä: Vahdin tarkistukset
  for r in select * from vahti_tarkistukset(false) loop
    v_taso := vahti_taso(r.jarj, r.tila);
    if v_taso >= 3 then
      v_ajot := vahti_korjausajot(r.jarj, r.kuvaus);
      perform halytys_avaa('vahti:' || r.jarj, 'jarjestelma', case v_taso when 5 then 'A' when 4 then 'B' else 'C' end, 'Työmaatutka', r.k,
        case when r.kuvaus like 'rikki nyt:%' then upper(left(r.kuvaus, 1)) || substr(r.kuvaus, 2) || ' (' || r.arvo || ').'
             else r.arvo || '. ' || upper(left(r.kuvaus, 1)) || substr(r.kuvaus, 2) || '.' end,
        vahti_ohje(r.jarj),
        jsonb_build_object('arvo', r.arvo, 'kuvaus', r.kuvaus, 'ajot', coalesce(to_jsonb(v_ajot), '[]'), 'virheet', vahti_virheet(r.jarj, v_ajot)),
        null, null);
    else
      perform halytys_sulje('vahti:' || r.jarj, r.arvo || ', ' || r.kuvaus);
    end if;
  end loop;

  -- 4 liikenne: avataan tiukalla ehdolla, pidetään auki löysemmällä (hystereesi estää värinää)
  for r in select distinct on (x.n, round(x.nyt)) x.*, count(*) over (partition by x.n, round(x.nyt)) - 1 as muut
           from liik_havainnot() x order by x.n, round(x.nyt), x.lupa_id loop
    if (r.z >= 3 and r.ero >= 25 and r.n >= 8)
       or (r.z >= 1.5 and r.ero >= 10 and exists (select 1 from halytys where avain = 'liikenne:' || r.lupa_id and poistui is null)) then
      select osoite into v_osoite from lupa_vaikutus where lupa_vaikutus.lupa_id = r.lupa_id;
      select linjat into v_linjat from lupa_tila where lupa_tila.lupa_id = r.lupa_id;
      perform halytys_avaa('liikenne:' || r.lupa_id, 'liikenne', 'C', coalesce(v_osoite, r.lupa_id),
        'Työmaa hidastaa tavallista enemmän: ' || coalesce(v_osoite, r.lupa_id),
        'Viimeisen tunnin ' || r.n || ' pysäkkivälin ohitusta olivat keskimäärin ' || round(r.ero) || ' s hitaampia kuin tavallisesti tähän aikaan'
          || case when v_linjat is not null and cardinality(v_linjat) > 0 then '. Linjat ' || array_to_string(v_linjat[1:6], ', ') else '' end || '.',
        'Katso kartalta, onko työmaalla alkanut uusi vaihe tai kaistasulku. Jos hidastus jatkuu, harkitse tiedotetta tai lisäaikaa aikatauluun.',
        jsonb_build_object('ohitukset', r.n, 'nyt_s', round(r.nyt), 'tavallisesti_s', round(r.pohja), 'z', round(r.z::numeric, 1), 'muut_luvat', r.muut),
        r.lupa_id, v_linjat);
      v_auki := v_auki || ('liikenne:' || r.lupa_id);
    end if;
  end loop;
  for h in select avain from halytys where lahde = 'liikenne' and poistui is null and not (avain = any (v_auki)) loop
    perform halytys_sulje(h.avain, 'hidastus palasi tavalliselle tasolle');
  end loop;

  -- 5 ilmoitukset: uudet ja luokaltaan nousseet; ei hiljennettyjä eikä juurisyyn seurauksia
  select array_agg(id order by luokka, alkoi) into v_uudet from halytys
    where poistui is null and syy_id is null and (hiljennetty_asti is null or hiljennetty_asti < now())
      and (ilmoitettu_luokka is null or ilmoitettu_luokka > luokka);
  if cardinality(v_uudet) > 3 then
    perform halytys_laheta('[HÄLYTYSTULVA] ' || cardinality(v_uudet) || ' uutta hälytystä',
      'Useita hälytyksiä samaan aikaan, todennäköisesti yhteinen syy. Avaa lista ja aloita ylimmästä.',
      case (select min(luokka) from halytys where id = any (v_uudet)) when 'A' then 5 when 'B' then 4 else 3 end, 'rotating_light', null);
    update halytys set ilmoitettu_luokka = luokka where id = any (v_uudet);
    insert into halytys_tapahtuma (halytys_id, laji, kuvaus) select id, 'ilmoitettu', 'Mukana koosteilmoituksessa (hälytystulva)' from unnest(v_uudet) id;
    insert into halytys_tapahtuma (halytys_id, laji, kuvaus) values (v_uudet[1], 'tulva', cardinality(v_uudet) || ' hälytystä samaan aikaan');
    n := n + 1;
  elsif v_uudet is not null then
    foreach v_id in array v_uudet loop perform halytys_ilmoita_rivi(v_id); n := n + 1; end loop;
  end if;

  delete from vahti_toimenpide where vanhenee < now() - interval '7 days';
  delete from halytys where poistui < now() - interval '90 days';
  return n;
end $$;

-- Vahdin sivu: kuittaus näkyy tarkistuksen kuvauksessa
create or replace function vahti_nyt() returns table (jarj int, k text, tila text, arvo text, kuvaus text)
language sql stable security definer set search_path = public as $$
  select t.jarj, t.k, t.tila, t.arvo,
    t.kuvaus || case when h.kuitattu is not null and t.tila in ('virhe', 'huom')
                     then ' · kuitattu hoitoon klo ' || to_char(h.kuitattu at time zone 'Europe/Helsinki', 'HH24.MI') else '' end
  from vahti_tarkistukset(false) t left join halytys h on h.avain = 'vahti:' || t.jarj and h.poistui is null;
$$;

revoke all on function halytys_laheta(text, text, int, text, text, jsonb), halytys_tunniste(), halytys_ilmoita_rivi(bigint),
  halytys_avaa(text, text, char, text, text, text, text, jsonb, text, text[]), halytys_sulje(text, text), halytys_tee(bigint, text, text),
  vahti_virheet(int, text[]), liik_pohja_paivita(), liik_havainnot(), halytys_ajo() from public, anon, authenticated;
revoke all on function vahti_toimi(text), halytys_kortti(bigint, text), halytys_toimi(bigint, text, text), halytykset_lista() from public;
grant execute on function vahti_toimi(text), halytys_kortti(bigint, text), halytys_toimi(bigint, text, text), halytykset_lista() to anon, authenticated;
grant execute on function vahti_nyt() to anon, authenticated;

select liik_pohja_paivita();

-- Käyttöönotto: Vahdin 5 min ajo (cron vahti-ilmoita) siirtyy hälytyslistaan
create or replace function vahti_ilmoita() returns int language sql security definer set search_path = public as $f$ select halytys_ajo() $f$;
revoke all on function vahti_ilmoita() from public, anon, authenticated;
