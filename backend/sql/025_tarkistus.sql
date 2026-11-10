-- 025: Tarkistettavat työmaat: suunnittelijan kuittaus.
-- Lista syntyy sivulla (lupa reitillä + haittaa ajoneuvoliikennettä + ei HSL:n tiedotetta samasta paikasta).
-- Kuittaus kertoo, että asia on tarkistettu: "tiedossa" (poikkeus hoidossa) tai "ei_tarvetta" (ei vaadi poikkeusta).
create table if not exists tarkistus_kuittaus (
  lupa_id text primary key,
  tila text not null check (tila in ('tiedossa','ei_tarvetta')),
  t timestamptz not null default now()
);
alter table tarkistus_kuittaus enable row level security;

create or replace function kuittaa_tarkistus(p_lupa text, p_tila text)
returns text language plpgsql security definer set search_path = public as $$
begin
  if p_tila is null then delete from tarkistus_kuittaus where lupa_id = p_lupa; return 'ok'; end if;
  if p_tila not in ('tiedossa','ei_tarvetta') then return 'virhe: tila'; end if;
  if not exists (select 1 from luvat_snapshot where lupa_id = p_lupa and snap_date = (select max(snap_date) from luvat_snapshot)) then return 'virhe: lupaa ei löydy'; end if;
  if (select count(*) from tarkistus_kuittaus where t > now() - interval '1 day') >= 300 then return 'virhe: päiväraja'; end if;
  insert into tarkistus_kuittaus (lupa_id, tila, t) values (p_lupa, p_tila, now())
  on conflict (lupa_id) do update set tila = excluded.tila, t = now();
  return 'ok';
end $$;
revoke all on function kuittaa_tarkistus(text, text) from public;
grant execute on function kuittaa_tarkistus(text, text) to anon, authenticated;

create or replace view v_tarkistus_kuittaus with (security_invoker = false) as
select lupa_id, tila, t from tarkistus_kuittaus;
grant select on v_tarkistus_kuittaus to anon, authenticated;
