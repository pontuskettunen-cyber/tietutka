-- 035: Vahdin ilmoituksiin vakavuusasteikko ja selkeämpi viesti (ensin mikä on rikki nyt, sitten mitä tehdä).
--   5 KRIITTINEN  palvelu ei toimi: ajoneuvodata pysähtynyt yli 2 h, tietokanta yli 90 % tai kaatui ja käynnistyi uudelleen
--   4 VAKAVA      osa rikki nyt: ajo, funktio tai kielimalli epäonnistuu, ajoneuvodata viivästynyt
--   3 HUOMIO      tarkista pian: tietokanta yli 70 %, lähdedata vanhentunut
--   ✅ KORJAUTUNUT  kun aiemmin ilmoitettu taso palaa nollaan
-- Ilmoitus lähtee, kun taso nousee; laskusta ei ilmoiteta ennen kuin vika on kokonaan poissa.
alter table vahti_ilmoitus add column if not exists taso int not null default 0;
update vahti_ilmoitus set taso = case when vakava then 4 else 0 end;

create or replace function vahti_taso(p_jarj int, p_tila text) returns int language sql immutable as $$
  select case
    when p_tila = 'virhe' and p_jarj in (1, 2) then 5
    when p_tila = 'virhe' then 4
    when p_tila = 'huom' and p_jarj = 1 then 4
    when p_tila = 'huom' and p_jarj in (2, 7) then 3
    else 0 end;
$$;

create or replace function vahti_ohje(p_jarj int) returns text language sql immutable as $$
  select case p_jarj
    when 1 then 'Tarkista hfp-segmentit-funktion loki ja onko HSL:n rajapinta auki.'
    when 2 then 'Aja siivous tai nosta tietokannan tasoa.'
    when 3 then 'Katso ajon virheviesti ajastettujen ajojen lokista.'
    when 4 then 'Katso funktion virhe ajolokista.'
    when 5 then 'Tarkista Anthropicin krediitit ja kielimallin virheviesti.'
    when 7 then 'Tarkista lähdedatan keruufunktiot.'
    else '' end;
$$;

create or replace function vahti_ilmoita() returns int language plpgsql security definer set search_path = public as $$
declare r record; v_taso int; v_ed int; n int := 0; v_kayn timestamptz := pg_postmaster_start_time(); v_kayn_ed timestamptz;
  v_nimi text[] := array['', '', 'HUOMIO', 'VAKAVA', 'KRIITTINEN'];
  v_tagi text[] := array['', '', 'information_source', 'warning', 'rotating_light'];
  v_rikki text;
begin
  select kaynnistyi into v_kayn_ed from vahti_kanava where id = 1;
  if v_kayn_ed is not null and v_kayn > v_kayn_ed + interval '1 minute' then
    perform vahti_laheta('[KRIITTINEN] Tietokanta käynnistyi uudelleen',
      'Kaatui ja käynnistyi klo ' || to_char(v_kayn at time zone 'Europe/Helsinki', 'HH24.MI') || '. '
      || 'Tarkista Vahdista, mikä ajo oli käynnissä juuri ennen.', 5, 'rotating_light');
    n := n + 1;
  end if;
  update vahti_kanava set kaynnistyi = v_kayn where id = 1;

  for r in select * from vahti_tarkistukset(false) loop
    v_taso := vahti_taso(r.jarj, r.tila);
    select taso into v_ed from vahti_ilmoitus where k = r.k;
    v_ed := coalesce(v_ed, 0);
    -- viestin alku: mikä on rikki nyt; 24 h -luku sulkuihin, koska siinä on mukana jo korjautuneet
    v_rikki := case when r.kuvaus like 'rikki nyt:%' then initcap(substr(r.kuvaus, 1, 1)) || substr(r.kuvaus, 2) || '. (' || r.arvo || ', osa jo korjautunut.)'
                    else r.arvo || '. ' || r.kuvaus || '.' end;
    if v_taso > v_ed and v_taso >= 3 then
      perform vahti_laheta('[' || v_nimi[v_taso] || '] ' || r.k, v_rikki || ' ' || vahti_ohje(r.jarj), v_taso, v_tagi[v_taso]); n := n + 1;
    elsif v_taso = 0 and v_ed >= 3 then
      perform vahti_laheta('[KORJAUTUNUT] ' || r.k, r.arvo || '. ' || r.kuvaus || '.', 2, 'white_check_mark'); n := n + 1;
    end if;
    insert into vahti_ilmoitus (k, tila, vakava, taso, muuttui) values (r.k, r.tila, v_taso >= 4, v_taso, now())
      on conflict (k) do update set tila = excluded.tila, vakava = excluded.vakava, taso = excluded.taso,
        muuttui = case when vahti_ilmoitus.taso is distinct from excluded.taso then now() else vahti_ilmoitus.muuttui end;
  end loop;
  return n;
end $$;
revoke all on function vahti_ilmoita() from public, anon, authenticated;
