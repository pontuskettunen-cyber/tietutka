-- 039: Liikennehälytyksen linjat matkustajan tuntemassa muodossa (HSL:n reittitunnus 1036 -> linja 36, 2321 -> 321).
-- Sama sääntö kuin sivulla (ln): nelinumeroisen tunnuksen ensimmäinen numero on alue, etunollat pois.
create or replace function hsl_linja(p text) returns text language sql immutable as $$
  select case when p ~ '^\d{4}' then coalesce(nullif(ltrim(substr(p, 2), '0'), ''), p) else p end;
$$;

-- Vain matkustajalle näkyvät linjat (4, 55, 69N, 550B), numerojärjestyksessä, ilman toistoja
create or replace function hsl_linjat(p text[]) returns text[] language sql immutable as $$
  select array_agg(n order by (substring(n from '^\d+'))::int, n)
  from (select distinct hsl_linja(x) n from unnest(coalesce(p, '{}')) x) y
  where n ~ '^\d{1,3}[A-Z]?$';
$$;

do $do$
declare d text := pg_get_functiondef('halytys_ajo()'::regprocedure);
begin
  d := replace(d,
    'select linjat into v_linjat from lupa_tila where lupa_tila.lupa_id = r.lupa_id;',
    'select hsl_linjat(linjat) into v_linjat from lupa_tila where lupa_tila.lupa_id = r.lupa_id;');
  if position('hsl_linjat(linjat)' in d) = 0 then raise exception 'korvaus ei osunut'; end if;
  execute d;
end $do$;

-- jo auki olevat liikennehälytykset oikeaan muotoon heti
update halytys set linjat = hsl_linjat(linjat),
  vaikutus = 'Linjat ' || array_to_string((hsl_linjat(linjat))[1:6], ', ') || ' myöhästyvät tällä kohdalla tavallista enemmän.'
where lahde = 'liikenne' and linjat is not null;
