-- 038: Hälytys selkokielellä. Ilmoituksesta näkee heti: mitä tapahtui, miksi, mitä siitä seuraa ja mitä kannattaa tehdä.
--   Syy päätellään virheviestistä kiinteillä säännöillä (ei kielimallia): sama virhe antaa aina saman selityksen.
--   Raaka virheviesti näkyy edelleen vain ilmoituksen kortissa.

alter table halytys add column if not exists syy text;
alter table halytys add column if not exists vaikutus text;
alter table halytys add column if not exists auttaa boolean;   -- auttaako uudelleenajo todennäköisesti

-- Ajastettujen ajojen ja keruufunktioiden selitteet
create table if not exists vahti_selite (nimi text primary key, mita text not null, vaikutus text not null);
alter table vahti_selite enable row level security;
insert into vahti_selite (nimi, mita, vaikutus) values
  ('ai-aikataulu', 'aikatauluagentti', 'Agentin aikataulumuutosehdotukset eivät päivity.'),
  ('ai-katsaus', 'tilannekatsauksen kirjoitus', 'Etusivun tilannekatsaus jää vanhaksi.'),
  ('ai-luokittele', 'lupatekstien luku', 'Uusien katulupien tekstejä ei lueta, joten niiden vaikutusarvio puuttuu.'),
  ('ai-vahti', 'Vahdin aamukatsaus', 'Aamun järjestelmäkatsaus jää kirjoittamatta.'),
  ('ai-viikko', 'viikkokatsaus', 'Viikkokatsaus jää kirjoittamatta.'),
  ('hfp-aggregate-2min', 'ajoneuvodatan koostus', 'Pysäkkivälien ajoajat eivät päivity: kaikki viivemittaukset pysähtyvät.'),
  ('hfp-segmentit', 'ajoneuvodatan keruu', 'Ajoneuvodataa ei tallenneta: viivemittaukset pysähtyvät.'),
  ('hfp-siivous', 'ajoneuvodatan siivous', 'Vanha data jää kantaan ja vie tilaa.'),
  ('hsl-hairiot-15min', 'HSL:n häiriötiedotteiden haku', 'Uudet häiriötiedotteet eivät näy tutkassa.'),
  ('kooste-siivous', 'koosteiden siivous', 'Vanhat koosteet jäävät kantaan ja vievät tilaa.'),
  ('kuormitus-tunti', 'pysäkkivälien kuormituslaskenta', 'Kuormitustiedot eivät päivity.'),
  ('liikenne-hae', 'autoliikenteen mittausten haku', 'Autoliikenteen vertailu (testissä) ei päivity.'),
  ('liikenne-tyo', 'autoliikenteen mittausten käsittely', 'Autoliikenteen vertailu (testissä) ei päivity.'),
  ('liikenne-laskurit-hae', 'liikennelaskurien haku', 'Uudet liikennelaskurit eivät tule mukaan.'),
  ('liikenne-laskurit-kasittele', 'liikennelaskurien käsittely', 'Uudet liikennelaskurit eivät tule mukaan.'),
  ('lupasegmentit-3h', 'työmaiden pysäkkivälien kohdistus', 'Uudet työmaat eivät saa pysäkkivälejä, joten niiden vaikutusta ei mitata ennen seuraavaa onnistunutta ajoa.'),
  ('luvat-10min', 'katulupien tilanne', 'Työmaiden mittarit eivät päivity.'),
  ('mittarit-10min', 'työmaiden mittarit', 'Työmaiden hidastusluvut eivät päivity.'),
  ('paivat-30min', 'päiväkohtaiset luvut', 'Päiväkohtaiset kuvaajat eivät päivity.'),
  ('pysakit-30min', 'pysäkkitiedot', 'Pysäkkitiedot eivät päivity.'),
  ('pysakit-nimet-kk', 'pysäkkien nimet', 'Uusien pysäkkien nimet puuttuvat.'),
  ('reittiviivat-tunti', 'reittiviivat', 'Linjojen reittiviivat kartalla eivät päivity.'),
  ('reittiviivat-viikko', 'reittiviivojen täysi haku', 'Linjojen reittiviivat kartalla eivät päivity.'),
  ('saa-10min', 'säähavainnot', 'Sää jää tutkassa vanhaksi.'),
  ('saavaikutus-tunti', 'sään vaikutuksen laskenta', 'Sääkorjaus ei päivity.'),
  ('segment-siivous', 'pysäkkivälidatan siivous', 'Vanha data jää kantaan ja vie tilaa.'),
  ('snapshot-luvat-paiva', 'katulupien päivittäinen haku', 'Uudet katuluvat eivät tule tutkaan.'),
  ('tila-valimuisti', 'etusivun välimuisti', 'Etusivun yhteenvetoluvut jäävät vanhoiksi ja sivu voi latautua hitaammin.'),
  ('tyomaat-10min', 'tietyötiedot (Digitraffic)', 'Tietyötiedot eivät päivity.'),
  ('vahti-ilmoita', 'Vahdin hälytysajo', 'Uusista vioista ei tule ilmoituksia.'),
  ('vaikutus-30min', 'työmaiden vaikutusarvio', 'Työmaiden ennen/aikana-vertailu ei päivity.'),
  ('vuorot-15min', 'linjojen vuorotiedot', 'Linjanäkymän vuorotiedot eivät päivity.')
on conflict (nimi) do update set mita = excluded.mita, vaikutus = excluded.vaikutus;

-- Virheviestistä syy ja arvio, auttaako uudelleenajo (ensimmäinen osuva sääntö voittaa)
create or replace function vahti_virhe_syy(p text) returns table (syy text, auttaa boolean)
language sql immutable as $$
  select s, a from (values
    (1,  'testivika',                                                         'tahallinen testivika', true),
    (2,  'statement timeout|canceling statement',                             'aikakatkaisu, tietokanta oli todennäköisesti ruuhkainen', true),
    (3,  'job startup timeout',                                               'ajo ei ehtinyt käynnistyä, tietokanta oli ylikuormittunut', true),
    (4,  'terminating connection|server closed|connection (refused|reset)|could not connect|shutting down',
                                                                              'tietokantayhteys katkesi, esimerkiksi uudelleenkäynnistyksen vuoksi', true),
    (5,  'deadlock',                                                          'lukkiutui toisen samanaikaisen ajon kanssa', true),
    (6,  'credit|balance|billing|quota',                                      'kielimallin käyttösaldo on lopussa', false),
    (7,  '\m401\M|unauthori[sz]ed|invalid.{0,12}api.?key|authentication',    'API-avain ei kelpaa', false),
    (8,  'overloaded|\m529\M|rate.?limit|\m429\M',                            'kielimallipalvelu oli ruuhkautunut', true),
    (9,  '<!doctype html|<html|\m50[0234]\M|gateway|timed out|timeout was reached|fetch failed|network',
                                                                              'palvelu ei vastannut ajoissa (HTTP-virhe)', true),
    (10, 'does not exist|syntax error|violates|invalid input|division by zero|null value|permission denied|out of range|cannot cast',
                                                                              'koodivirhe, ajo kaatuu samalla tavalla joka kerta', false),
    (99, '',                                                                  'tunnistamaton virhe, viesti näkyy kortissa', null::boolean)
  ) v (o, re, s, a)
  where coalesce(p, '') ~* re or o = 99
  order by o limit 1;
$$;

-- Hälytyksen sisältö Vahdin tarkistuksesta: otsikko, mitä, syy, vaikutus, suositus
create or replace function vahti_sisalto(p_jarj int, p_tila text, p_arvo text, p_kuvaus text, p_ajot text[], p_virheet jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, cron as $$
declare v_j text := p_ajot[1]; v_sel vahti_selite; v_n int; v_t timestamptz; v_viesti text; v_syy text; v_auttaa boolean;
  v_otsikko text; v_mita text; v_vaik text; v_suos text; v_muut text;
begin
  v_viesti := (select x ->> 'viesti' from jsonb_array_elements(coalesce(p_virheet, '[]')) x
               where v_j is null or x ->> 'mika' = v_j limit 1);
  select s.syy, s.auttaa into v_syy, v_auttaa from vahti_virhe_syy(v_viesti) s;

  if p_jarj = 3 then
    select * into v_sel from vahti_selite where nimi = v_j;
    select count(*), max(d.start_time) into v_n, v_t from cron.job_run_details d join cron.job j using (jobid)
      where j.jobname = v_j and d.status = 'failed' and d.start_time > now() - interval '24 hours';
    v_muut := array_to_string(p_ajot[2:], ', ');
    v_otsikko := case when cardinality(p_ajot) > 1 then cardinality(p_ajot) || ' ajoa kaatui: ' else 'Ajo kaatui: ' end || coalesce(v_sel.mita, v_j);
    v_mita := 'Klo ' || to_char(v_t at time zone 'Europe/Helsinki', 'HH24.MI') || ' ' || v_j || ' epäonnistui'
      || case when v_n > 1 then ' (' || v_n || '. kerta 24 h)' else '' end
      || case when v_muut <> '' then '. Lisäksi rikki: ' || v_muut else '' end || '.';
    v_vaik := coalesce(v_sel.vaikutus, 'Ajon tulokset eivät päivity.');
  elsif p_jarj = 4 then
    v_j := (select x ->> 'mika' from jsonb_array_elements(coalesce(p_virheet, '[]')) x limit 1);
    select * into v_sel from vahti_selite where nimi = v_j;
    v_otsikko := 'Keruu epäonnistuu: ' || coalesce(v_sel.mita, v_j, 'funktio');
    v_mita := initcap(left(p_kuvaus, 1)) || substr(p_kuvaus, 2) || '.';
    v_vaik := coalesce(v_sel.vaikutus, 'Osa datasta jää keräämättä, kunnes keruu onnistuu.');
  elsif p_jarj = 5 then
    v_otsikko := 'Kielimalli ei vastaa';
    v_mita := 'Viimeisistä kutsuista ' || substring(p_kuvaus from '(\d+) kolmesta') || '/3 epäonnistui.';
    v_vaik := 'Lupatekstien luku, katsaukset ja agentin ehdotukset eivät päivity. Mitatut luvut toimivat normaalisti.';
  elsif p_jarj = 1 then
    v_otsikko := case when p_tila = 'virhe' then 'Ajoneuvodata pysähtyi' else 'Ajoneuvodata viivästyy' end;
    v_mita := 'Viimeisin HSL:n ajoneuvodatan käsittely ' || p_arvo || '.';
    v_syy := 'keruu ei ole saanut ajoneuvodataa käsiteltyä'; v_auttaa := true;
    v_vaik := 'Viivemittaukset pysähtyvät: tutkan luvut eivät päivity.';
  elsif p_jarj = 2 then
    v_otsikko := 'Tietokanta täyttymässä';
    v_mita := p_arvo || ', ' || p_kuvaus || '.';
    v_syy := 'data kasvaa nopeammin kuin siivous poistaa'; v_auttaa := true;
    v_vaik := 'Kun tila loppuu, tallennus pysähtyy ja tutka lakkaa päivittymästä.';
  elsif p_jarj = 6 then
    v_otsikko := 'Tilannekatsaus jäi kirjoittamatta';
    v_mita := 'Viimeisin katsaus ' || p_arvo || '.';
    v_syy := 'katsausajo ei ole onnistunut ajallaan'; v_auttaa := null;
    v_vaik := 'Etusivulla näkyy vanha tilannekatsaus.';
  elsif p_jarj = 7 then
    v_otsikko := 'Lähdedata vanhentunut';
    v_mita := initcap(left(p_arvo, 1)) || substr(p_arvo, 2) || '.';
    v_syy := 'lähteen haku ei ole onnistunut'; v_auttaa := null;
    v_vaik := 'Osa taustatiedoista on vanhaa.';
  elsif p_jarj = 8 then
    v_otsikko := 'Epäuskottavia lukuja';
    v_mita := p_arvo || '.';
    v_syy := 'työmaa on todennäköisesti kohdistettu väärään pysäkkiväliin'; v_auttaa := false;
    v_vaik := 'Yksittäisen työmaan luku voi olla väärin.';
  end if;

  v_suos := case
    when p_jarj = 5 and v_syy like '%saldo%' then 'Lisää käyttösaldoa kielimallin konsolissa.'
    when p_jarj = 5 then 'Odota seuraavaa ajoa. Jos jatkuu, tarkista API-avain ja palvelun tila.'
    when p_jarj = 2 then 'Aja siivous uudelleen tai kasvata tietokannan tilaa.'
    when p_jarj = 8 then 'Tarkista työmaan kohdistus kartalta.'
    when p_jarj in (6, 7) then 'Korjautuu yleensä seuraavalla ajolla. Jos jatkuu yli 2 h, tarkista lähteen ajo.'
    when cardinality(coalesce(p_ajot, '{}')) = 0 then 'Keruu yrittää uudelleen seuraavalla ajokerralla. Jos virhe toistuu, katso virheviesti kortista.'
    when v_auttaa then 'Aja uudelleen: tähän auttaa yleensä uusi ajo.'
    when v_auttaa = false then 'Uudelleenajo ei todennäköisesti auta: vika vaatii korjauksen koodiin tai asetuksiin.'
    else 'Katso virheviesti kortista. Uudelleenajoa voi kokeilla.' end;

  return jsonb_build_object('otsikko', v_otsikko, 'mita', v_mita,
    'syy', upper(left(v_syy, 1)) || substr(v_syy, 2) || '.', 'vaikutus', v_vaik, 'suositus', v_suos, 'auttaa', v_auttaa);
end $$;

-- Avaus: uudet kentät mukaan
drop function if exists halytys_avaa(text, text, char, text, text, text, text, jsonb, text, text[]);
create or replace function halytys_avaa(p_avain text, p_lahde text, p_luokka char, p_kohde text, p_otsikko text, p_kuvaus text,
  p_ohje text, p_yks jsonb, p_lupa text, p_linjat text[], p_syy text default null, p_vaikutus text default null, p_auttaa boolean default null) returns bigint
language plpgsql security definer set search_path = public as $$
declare v halytys; v_syy bigint;
begin
  select * into v from halytys where avain = p_avain and poistui is null;
  if found then
    update halytys set luokka = p_luokka, kohde = p_kohde, otsikko = p_otsikko, kuvaus = p_kuvaus, ohje = p_ohje, yksityinen = p_yks,
      linjat = p_linjat, syy = p_syy, vaikutus = p_vaikutus, auttaa = p_auttaa,
      muuttui = case when p_luokka <> v.luokka or p_kuvaus is distinct from v.kuvaus then now() else v.muuttui end
      where id = v.id;
    if p_luokka < v.luokka then
      insert into halytys_tapahtuma (halytys_id, laji, kuvaus) values (v.id, 'nousi', 'Luokka nousi ' || v.luokka || ' → ' || p_luokka);
    elsif p_luokka > v.luokka then
      insert into halytys_tapahtuma (halytys_id, laji, kuvaus) values (v.id, 'laski', 'Luokka laski ' || v.luokka || ' → ' || p_luokka);
    end if;
    return v.id;
  end if;

  select * into v from halytys where avain = p_avain and poistui > now() - interval '30 minutes' order by poistui desc limit 1;
  if found then
    update halytys set poistui = null, kuitattu = null, toistot = toistot + 1, luokka = p_luokka, kohde = p_kohde, otsikko = p_otsikko,
      kuvaus = p_kuvaus, ohje = p_ohje, yksityinen = p_yks, linjat = p_linjat, syy = p_syy, vaikutus = p_vaikutus, auttaa = p_auttaa,
      muuttui = now() where id = v.id;
    insert into halytys_tapahtuma (halytys_id, laji, kuvaus) values (v.id, 'palasi', 'Vika palasi ' ||
      round(extract(epoch from now() - v.poistui) / 60) || ' min poistumisen jälkeen (toistunut ' || (v.toistot + 1) || ' kertaa)');
    return v.id;
  end if;

  if p_lahde = 'jarjestelma' and p_avain <> 'tietokanta' then
    select id into v_syy from halytys where avain = 'tietokanta' and poistui is null and alkoi > now() - interval '30 minutes';
  end if;

  insert into halytys (avain, lahde, luokka, kohde, otsikko, kuvaus, ohje, yksityinen, lupa_id, linjat, syy_id, syy, vaikutus, auttaa)
    values (p_avain, p_lahde, p_luokka, p_kohde, p_otsikko, p_kuvaus, p_ohje, p_yks, p_lupa, p_linjat, v_syy, p_syy, p_vaikutus, p_auttaa)
    returning * into v;
  insert into halytys_tapahtuma (halytys_id, laji, kuvaus) values (v.id, 'alkoi',
    case when v_syy is not null then 'Hälytys alkoi (seurausta tietokannan uudelleenkäynnistyksestä)' else 'Hälytys alkoi' end);
  return v.id;
end $$;

-- Ilmoitus: neljä lyhyttä riviä, napit suosituksen mukaan
create or replace function halytys_ilmoita_rivi(p_id bigint) returns void
language plpgsql security definer set search_path = public as $$
declare h halytys; v_kortti text := halytys_tunniste(); v_url text; v_napit jsonb := '[]'; v_ajot int;
  v_api text := 'https://pdbmxnmeyhifksgivnky.supabase.co/rest/v1/rpc/vahti_toimi';
  v_key text := 'sb_publishable_ZM_StZYcp6QJs5HdlqHbDA_gzQHPqVf';   -- julkinen avain, sama kuin sivulla
  v_t text; v_laji text; v_viesti text;
begin
  select * into h from halytys where id = p_id;
  v_url := 'https://pontuskettunen-cyber.github.io/tyomaatutka/#/halytykset?h=' || h.id || '&t=' || v_kortti;
  insert into vahti_toimenpide (token, laji, k, halytys_id, vanhenee) values (v_kortti, 'kortti', h.avain, h.id, now() + interval '24 hours');
  v_ajot := jsonb_array_length(coalesce(h.yksityinen -> 'ajot', '[]'));

  -- uudelleenajo ensimmäiseksi vain, kun se todennäköisesti auttaa
  foreach v_laji in array case when h.lahde = 'liikenne' then array['kuittaa']
                               when v_ajot > 0 and h.auttaa is distinct from false then array['aja', 'kuittaa']
                               else array['kuittaa', 'hiljenna'] end loop
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

  v_viesti := h.kuvaus
    || coalesce(E'\nSyy: ' || h.syy, '')
    || coalesce(E'\nVaikutus: ' || h.vaikutus, '')
    || coalesce(E'\n→ ' || h.ohje, '');
  perform halytys_laheta(
    '[' || case h.luokka when 'A' then 'KRIITTINEN' when 'B' then 'VAKAVA' else 'HUOMIO' end || '] ' || h.otsikko,
    v_viesti,
    case h.luokka when 'A' then 5 when 'B' then 4 else 3 end,
    case when h.luokka = 'A' then 'rotating_light' when h.luokka = 'B' then 'warning' when h.lahde = 'liikenne' then 'bus' else 'information_source' end,
    v_url, v_napit);
  update halytys set ilmoitettu_luokka = h.luokka where id = h.id;
  insert into halytys_tapahtuma (halytys_id, laji, kuvaus) values (h.id, 'ilmoitettu', 'Ilmoitus puhelimeen, luokka ' || h.luokka);
end $$;

-- Ajo: sisältö selkokielellä
create or replace function halytys_ajo() returns int
language plpgsql security definer set search_path = public, cron as $$
declare r record; u record; h record; v_taso int; n int := 0;
  v_kayn timestamptz := pg_postmaster_start_time(); v_kayn_ed timestamptz;
  v_ajot text[]; v_virheet jsonb; v_s jsonb; v_osoite text; v_linjat text[]; v_uudet bigint[]; v_auki text[] := '{}'; v_id bigint;
  v_hh int := extract(hour from now() at time zone 'Europe/Helsinki');
begin
  if v_hh = 3 and coalesce((select max(paivitetty) from liik_pohja), '-infinity') < now() - interval '20 hours' then
    perform liik_pohja_paivita();
  end if;

  -- 1 tietokanta käynnistyi uudelleen
  select kaynnistyi into v_kayn_ed from vahti_kanava where id = 1;
  if v_kayn_ed is not null and v_kayn > v_kayn_ed + interval '1 minute' then
    perform halytys_avaa('tietokanta', 'jarjestelma', 'A', 'Työmaatutka', 'Tietokanta käynnistyi uudelleen',
      'Tietokanta kaatui ja käynnistyi klo ' || to_char(v_kayn at time zone 'Europe/Helsinki', 'HH24.MI') || '.',
      'Tarkista, mikä raskas ajo oli käynnissä juuri ennen. Seuraavan puolen tunnin järjestelmähälytykset niputetaan tämän alle.',
      jsonb_build_object('kaynnistyi', v_kayn), null, null,
      'Todennäköisesti muisti tai yhteydet loppuivat raskaan ajon aikana.',
      'Käynnissä olleet ajot keskeytyivät. Seuraavat ajot jatkavat normaalisti.', null);
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
      perform halytys_laheta('[EI KORJAANTUNUT] ' || u.jobname,
        'Uudelleenajo epäonnistui samalla tavalla: ' || (select lower(s.syy) from vahti_virhe_syy(u.viesti) s) || E'.\n→ Vika vaatii todennäköisesti korjauksen koodiin tai asetuksiin.',
        4, 'x', 'https://pontuskettunen-cyber.github.io/tyomaatutka/#/halytykset' || coalesce('?h=' || u.halytys_id, ''));
    end if;
    update vahti_uusinta set ilmoitettu = true where id = u.id;
    n := n + 1;
  end loop;

  -- 3 järjestelmä
  for r in select * from vahti_tarkistukset(false) loop
    v_taso := vahti_taso(r.jarj, r.tila);
    if v_taso >= 3 then
      v_ajot := vahti_korjausajot(r.jarj, r.kuvaus);
      v_virheet := vahti_virheet(r.jarj, v_ajot);
      v_s := vahti_sisalto(r.jarj, r.tila, r.arvo, r.kuvaus, v_ajot, v_virheet);
      perform halytys_avaa('vahti:' || r.jarj, 'jarjestelma', case v_taso when 5 then 'A' when 4 then 'B' else 'C' end, 'Työmaatutka',
        coalesce(v_s ->> 'otsikko', r.k), coalesce(v_s ->> 'mita', r.arvo), v_s ->> 'suositus',
        jsonb_build_object('arvo', r.arvo, 'kuvaus', r.kuvaus, 'tarkistus', r.k, 'ajot', coalesce(to_jsonb(v_ajot), '[]'), 'virheet', v_virheet),
        null, null, v_s ->> 'syy', v_s ->> 'vaikutus', (v_s ->> 'auttaa')::boolean);
    else
      perform halytys_sulje('vahti:' || r.jarj, r.arvo || ', ' || r.kuvaus);
    end if;
  end loop;

  -- 4 liikenne (hystereesi: avataan tiukalla, pidetään auki löysemmällä ehdolla)
  for r in select distinct on (x.n, round(x.nyt)) x.*, count(*) over (partition by x.n, round(x.nyt)) - 1 as muut
           from liik_havainnot() x order by x.n, round(x.nyt), x.lupa_id loop
    if (r.z >= 3 and r.ero >= 25 and r.n >= 8)
       or (r.z >= 1.5 and r.ero >= 10 and exists (select 1 from halytys where avain = 'liikenne:' || r.lupa_id and poistui is null)) then
      select osoite into v_osoite from lupa_vaikutus where lupa_vaikutus.lupa_id = r.lupa_id;
      select linjat into v_linjat from lupa_tila where lupa_tila.lupa_id = r.lupa_id;
      perform halytys_avaa('liikenne:' || r.lupa_id, 'liikenne', 'C', coalesce(v_osoite, r.lupa_id),
        'Työmaa hidastaa: ' || coalesce(v_osoite, r.lupa_id),
        'Viimeisen tunnin ' || r.n || ' ohitusta keskimäärin +' || round(r.ero) || ' s / pysäkkiväli verrattuna tavalliseen tähän aikaan.',
        'Katso kartalta, onko alkanut uusi vaihe tai kaistasulku. Jos jatkuu, harkitse tiedotetta tai lisäaikaa aikatauluun.',
        jsonb_build_object('ohitukset', r.n, 'nyt_s', round(r.nyt), 'tavallisesti_s', round(r.pohja), 'z', round(r.z::numeric, 1), 'muut_luvat', r.muut),
        r.lupa_id, v_linjat,
        'Hidastus on selvästi suurempi kuin samaan aikaan edellisinä päivinä.',
        case when v_linjat is not null and cardinality(v_linjat) > 0
             then 'Linjat ' || array_to_string(v_linjat[1:6], ', ') || ' myöhästyvät tällä kohdalla tavallista enemmän.'
             else 'Bussit myöhästyvät tällä kohdalla tavallista enemmän.' end, null);
      v_auki := v_auki || ('liikenne:' || r.lupa_id);
    end if;
  end loop;
  for h in select avain from halytys where lahde = 'liikenne' and poistui is null and not (avain = any (v_auki)) loop
    perform halytys_sulje(h.avain, 'hidastus palasi tavalliselle tasolle');
  end loop;

  -- 5 ilmoitukset
  select array_agg(id order by luokka, alkoi) into v_uudet from halytys
    where poistui is null and syy_id is null and (hiljennetty_asti is null or hiljennetty_asti < now())
      and (ilmoitettu_luokka is null or ilmoitettu_luokka > luokka);
  if cardinality(v_uudet) > 3 then
    perform halytys_laheta('[HÄLYTYSTULVA] ' || cardinality(v_uudet) || ' uutta hälytystä',
      'Useita hälytyksiä samaan aikaan, todennäköisesti yhteinen syy. Ensimmäinen: '
        || (select otsikko from halytys where id = v_uudet[1]) || E'.\n→ Avaa lista ja aloita ylimmästä.',
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

-- Lista: uudet kentät ja seurausten määrä juurisyylle
create or replace function halytykset_lista() returns jsonb
language sql stable security definer set search_path = public as $$
  with r as (
    select h.* from halytys h
    where h.poistui is null or h.poistui > now() - interval '7 days' or (h.kuitattu is null and h.alkoi > now() - interval '30 days'))
  select jsonb_build_object(
    'nyt', now(),
    'rivit', coalesce((select jsonb_agg(jsonb_build_object(
        'id', r.id, 'avain', r.avain, 'lahde', r.lahde, 'luokka', r.luokka, 'kohde', r.kohde, 'otsikko', r.otsikko, 'kuvaus', r.kuvaus,
        'syy', r.syy, 'vaikutus', r.vaikutus, 'auttaa', r.auttaa,
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
          select avain, max(otsikko) otsikko, count(*) + sum(toistot) kertaa
          from halytys where alkoi > now() - interval '7 days' group by avain
          having count(*) + sum(toistot) >= 2 order by 3 desc limit 3) x)));
$$;

revoke all on function vahti_virhe_syy(text), vahti_sisalto(int, text, text, text, text[], jsonb),
  halytys_avaa(text, text, char, text, text, text, text, jsonb, text, text[], text, text, boolean),
  halytys_ilmoita_rivi(bigint), halytys_ajo() from public, anon, authenticated;
grant execute on function halytykset_lista() to anon, authenticated;
