-- 024: Ihmisen arvio aikatauluagentin ehdotuksista (ensimmäinen tekoälyn laatumittari).
-- Arvio ei muuta aikatauluja: se kirjaa, oliko suunnittelija agentin kanssa samaa mieltä.
create table if not exists ai_arvio (
  suositus_id bigint primary key references ai_suositus(id) on delete cascade,
  paatos text not null check (paatos in ('hyvaksy','hylkaa')),
  syy text check (syy in ('luvut','ei_tarpeen','muu')),
  t timestamptz not null default now()
);
alter table ai_arvio enable row level security;

-- Julkinen kirjoitus vain tämän funktion kautta: sallitut arvot, vain tuoreet ehdotukset, päiväraja.
create or replace function arvioi_suositus(p_id bigint, p_paatos text, p_syy text default null)
returns text language plpgsql security definer set search_path = public as $$
begin
  if p_paatos not in ('hyvaksy','hylkaa') then return 'virhe: päätös'; end if;
  if p_paatos = 'hylkaa' and coalesce(p_syy,'') not in ('luvut','ei_tarpeen','muu') then return 'virhe: syy'; end if;
  if not exists (select 1 from ai_suositus where id = p_id and luotu > now() - interval '7 days') then return 'virhe: ehdotusta ei löydy'; end if;
  if (select count(*) from ai_arvio where t > now() - interval '1 day') >= 200 then return 'virhe: päiväraja'; end if;
  insert into ai_arvio (suositus_id, paatos, syy, t) values (p_id, p_paatos, case when p_paatos = 'hylkaa' then p_syy end, now())
  on conflict (suositus_id) do update set paatos = excluded.paatos, syy = excluded.syy, t = now();
  return 'ok';
end $$;
revoke all on function arvioi_suositus(bigint, text, text) from public;
grant execute on function arvioi_suositus(bigint, text, text) to anon, authenticated;

-- Ehdotusnäkymään arvio mukaan (sarakkeet lisätään loppuun)
create or replace view v_ai_suositus with (security_invoker = false) as
select distinct on (s.route, s.dir, s.jakso) s.id, s.route, s.dir, s.jakso, s.sisalto, s.perusteet, s.varmuus, s.malli, s.luotu,
  a.paatos, a.syy, a.t as arvioitu
from ai_suositus s left join ai_arvio a on a.suositus_id = s.id
where s.luotu > now() - interval '3 days' order by s.route, s.dir, s.jakso, s.luotu desc;

-- Laatumittari: 30 päivän ehdotukset ja niiden arviot (yksi rivi per linja-suunta-jakso-päivä, ettei sama ehdotus toistu)
create or replace view v_ai_laatu with (security_invoker = false) as
with e as (
  select distinct on (s.route, s.dir, s.jakso, (s.luotu at time zone 'Europe/Helsinki')::date) s.id, s.varmuus
  from ai_suositus s where s.luotu > now() - interval '30 days'
  order by s.route, s.dir, s.jakso, (s.luotu at time zone 'Europe/Helsinki')::date, s.luotu desc),
a as (select a.* from ai_arvio a join ai_suositus s on s.id = a.suositus_id where s.luotu > now() - interval '30 days')
select (select count(*) from e) ehdotuksia,
  (select count(*) from a) arvioitu,
  (select count(*) from a where paatos = 'hyvaksy') hyvaksytty,
  (select count(*) from a where paatos = 'hylkaa' and syy = 'luvut') hylatty_luvut,
  (select count(*) from a where paatos = 'hylkaa' and syy = 'ei_tarpeen') hylatty_ei_tarpeen,
  (select count(*) from a where paatos = 'hylkaa' and syy = 'muu') hylatty_muu;

grant select on v_ai_suositus, v_ai_laatu to anon, authenticated;
