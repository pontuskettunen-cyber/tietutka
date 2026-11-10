-- 040: levytilahälytyksen ohje. Siivous ajetaan jo joka yö, joten uudelleenajo ei auta.
do $$
declare d text;
begin
  select pg_get_functiondef(p.oid) into d from pg_proc p where p.proname = 'vahti_sisalto' limit 1;
  d := replace(d, $a$v_syy := 'data kasvaa nopeammin kuin siivous poistaa'; v_auttaa := true;$a$,
                  $a$v_syy := 'data kasvaa nopeammin kuin siivous poistaa'; v_auttaa := false;$a$);
  d := replace(d, $a$'Aja siivous uudelleen tai kasvata tietokannan tilaa.'$a$,
                  $a$'Kasvata tietokannan tilaa (Supabasen paketti) tai lyhennä säilytysaikaa. Siivous ajetaan jo joka yö, joten uudelleenajo ei auta.'$a$);
  execute d;
end $$;
select position('lyhennä säilytysaikaa' in pg_get_functiondef(p.oid)) > 0 as ok from pg_proc p where p.proname = 'vahti_sisalto';
