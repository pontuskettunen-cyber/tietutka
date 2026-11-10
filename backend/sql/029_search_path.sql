-- 029: Supabasen tietoturvatarkastuksen (Security Advisor) varoitukset: kiinteä search_path laskentafunktioille.
alter function etaisyys_m(float8, float8, float8, float8, float8, float8) set search_path = public;
alter function etaisyys_janaan(float8, float8, float8, float8, float8, float8) set search_path = public;
do $$ begin
  execute (select 'alter function ' || p.oid::regprocedure || ' set search_path = public'
           from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.proname = 'tt_cell' limit 1);
end $$;
select proname, proconfig from pg_proc where proname in ('etaisyys_m','etaisyys_janaan','tt_cell');
