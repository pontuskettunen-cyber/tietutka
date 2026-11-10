-- 044: esittelypyynnön ilmoitus käyttää Vahdin kanavataulua (vahti_kanava)
create or replace function tietutka_pyyda_esittely(p_nimi text, p_yritys text, p_yhteys text, p_viesti text, p_arvio_id text default null)
returns json language plpgsql security definer set search_path = public as $$
declare v_kanava text := (select topic from vahti_kanava where id = 1);
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

