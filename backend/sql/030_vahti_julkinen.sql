-- 030: Vahdin tarkistukset sivulle. Näkymän kautta kutsuttu funktio tarvitsee kutsujan (anon) suoritusoikeuden,
-- joten julkiselle näkymälle oma kääre, joka vain lukee (ei tallenna kokoa).
create or replace function vahti_nyt()
returns table (jarj int, k text, tila text, arvo text, kuvaus text)
language sql security definer set search_path = public as $$ select * from vahti_tarkistukset(false) $$;
revoke all on function vahti_nyt() from public;
grant execute on function vahti_nyt() to anon, authenticated;
create or replace view v_vahti_nyt with (security_invoker = false) as select * from vahti_nyt() order by jarj;
grant select on v_vahti_nyt to anon, authenticated;
