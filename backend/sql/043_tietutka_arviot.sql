-- 043: Tietutka – lukitut haitta-arviot ja esittelypyynnöt.
-- Arvio tallennetaan palvelimelle ennen työn alkua, eikä sitä voi muuttaa jälkikäteen.
-- Myöhemmin arviota verrataan mitattuun toteumaan (tarkkuuden todentaminen).
-- Tauluihin ei ole suoraa pääsyä: kirjoitus ja luku vain funktioiden kautta.

create table if not exists tietutka_arviot (
  id text primary key,
  luotu timestamptz not null default now(),
  osoite text,
  lupa_id text,
  alkaa date,
  paattyy date,
  haitta text,
  lisaaika_s numeric,
  ohitukset int,
  lisaaika_h_vrk numeric,
  laskelma jsonb not null,
  alue jsonb
);
alter table tietutka_arviot enable row level security;
revoke all on tietutka_arviot from anon, authenticated;
create index if not exists tietutka_arviot_luotu on tietutka_arviot (luotu);

-- Lukitus: arviota ei voi muuttaa eikä poistaa (koskee myös ylläpitäjää; poisto vain tämän triggerin poistolla)
create or replace function tietutka_arvio_lukko() returns trigger language plpgsql as $$
begin
  raise exception 'Tietutkan haitta-arvio % on lukittu, eikä sitä voi muuttaa', old.id;
end $$;
drop trigger if exists tietutka_arvio_lukko on tietutka_arviot;
create trigger tietutka_arvio_lukko before update or delete on tietutka_arviot
  for each row execute function tietutka_arvio_lukko();

create or replace function tietutka_lukitse(p_laskelma jsonb, p_alue jsonb default null)
returns json language plpgsql security definer set search_path = public as $$
declare v_id text; v_luotu timestamptz;
begin
  if p_laskelma is null or jsonb_typeof(p_laskelma) <> 'object' then raise exception 'laskelma puuttuu'; end if;
  if octet_length(p_laskelma::text) + coalesce(octet_length(p_alue::text), 0) > 200000 then raise exception 'arvio on liian suuri'; end if;
  if (select count(*) from tietutka_arviot where luotu > now() - interval '1 hour') >= 300 then raise exception 'liikaa arvioita juuri nyt, yritä hetken päästä'; end if;
  loop
    v_id := 'TT-' || to_char(now() at time zone 'Europe/Helsinki', 'YYYYMMDD') || '-' || upper(substr(md5(gen_random_uuid()::text), 1, 5));
    exit when not exists (select 1 from tietutka_arviot where id = v_id);
  end loop;
  insert into tietutka_arviot (id, osoite, lupa_id, alkaa, paattyy, haitta, lisaaika_s, ohitukset, lisaaika_h_vrk, laskelma, alue)
  values (v_id, left(p_laskelma->>'osoite', 300), left(p_laskelma->>'lupa_id', 100),
          nullif(p_laskelma->>'alkaa', '')::date, nullif(p_laskelma->>'paattyy', '')::date, left(p_laskelma->>'haitta', 30),
          nullif(p_laskelma->>'s', '')::numeric, nullif(p_laskelma->>'ohitukset_arkipaiva', '')::numeric::int,
          nullif(p_laskelma->>'lisaaika_h_vrk', '')::numeric, p_laskelma, p_alue)
  returning luotu into v_luotu;
  return json_build_object('id', v_id, 'luotu', v_luotu);
end $$;

create or replace function tietutka_hae_arvio(p_id text)
returns json language sql stable security definer set search_path = public as $$
  select json_build_object('id', id, 'luotu', luotu, 'osoite', osoite, 'alkaa', alkaa, 'paattyy', paattyy, 'haitta', haitta,
                           'lisaaika_s', lisaaika_s, 'ohitukset', ohitukset, 'lisaaika_h_vrk', lisaaika_h_vrk)
  from tietutka_arviot where id = upper(trim(p_id));
$$;

-- Esittelypyynnöt: tallennus ja ilmoitus ylläpitäjän puhelimeen (sama ntfy-kanava kuin Vahdilla)
create table if not exists tietutka_yhteydenotot (
  id bigint generated always as identity primary key,
  luotu timestamptz not null default now(),
  nimi text not null,
  yritys text,
  yhteys text not null,
  viesti text,
  arvio_id text
);
alter table tietutka_yhteydenotot enable row level security;
revoke all on tietutka_yhteydenotot from anon, authenticated;

create or replace function tietutka_pyyda_esittely(p_nimi text, p_yritys text, p_yhteys text, p_viesti text, p_arvio_id text default null)
returns json language plpgsql security definer set search_path = public as $$
declare v_kanava text := (select v from vahti_ilmoitus_asetus where k = 'ntfy_kanava');
begin
  if coalesce(trim(p_nimi), '') = '' or coalesce(trim(p_yhteys), '') = '' then raise exception 'nimi ja yhteystieto tarvitaan'; end if;
  if length(p_nimi) > 120 or length(coalesce(p_yritys, '')) > 160 or length(p_yhteys) > 160 or length(coalesce(p_viesti, '')) > 2000 then raise exception 'liian pitkä'; end if;
  if (select count(*) from tietutka_yhteydenotot where luotu > now() - interval '1 hour') >= 30 then raise exception 'liikaa pyyntöjä juuri nyt, yritä hetken päästä'; end if;
  insert into tietutka_yhteydenotot (nimi, yritys, yhteys, viesti, arvio_id)
  values (trim(p_nimi), nullif(trim(p_yritys), ''), trim(p_yhteys), nullif(trim(p_viesti), ''), nullif(trim(p_arvio_id), ''));
  if v_kanava is not null then
    perform net.http_post(url := 'https://ntfy.sh/', body := jsonb_build_object('topic', v_kanava, 'priority', 4, 'tags', jsonb_build_array('handshake'),
      'title', 'Tietutka: esittelypyyntö',
      'message', trim(p_nimi) || coalesce(' · ' || nullif(trim(p_yritys), ''), '') || E'\n' || trim(p_yhteys) || coalesce(E'\n' || nullif(trim(p_viesti), ''), '')));
  end if;
  return json_build_object('ok', true);
end $$;

revoke all on function tietutka_lukitse(jsonb, jsonb) from public;
revoke all on function tietutka_hae_arvio(text) from public;
revoke all on function tietutka_pyyda_esittely(text, text, text, text, text) from public;
grant execute on function tietutka_lukitse(jsonb, jsonb) to anon, authenticated;
grant execute on function tietutka_hae_arvio(text) to anon, authenticated;
grant execute on function tietutka_pyyda_esittely(text, text, text, text, text) to anon, authenticated;
