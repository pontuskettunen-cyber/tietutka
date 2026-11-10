-- 041: yhden linjan liikennehälytys yksikössä ("Linja 10 myöhästyy").
do $$
declare d text;
begin
  select pg_get_functiondef(p.oid) into d from pg_proc p where p.proname = 'halytys_ajo' limit 1;
  d := replace(d, $a$then 'Linjat ' || array_to_string(v_linjat[1:6], ', ') || ' myöhästyvät tällä kohdalla tavallista enemmän.'$a$,
                  $a$then case when cardinality(v_linjat) = 1 then 'Linja ' || v_linjat[1] || ' myöhästyy' else 'Linjat ' || array_to_string(v_linjat[1:6], ', ') || ' myöhästyvät' end || ' tällä kohdalla tavallista enemmän.'$a$);
  execute d;
end $$;
update halytys set vaikutus = 'Linja ' || (hsl_linjat(linjat))[1] || ' myöhästyy tällä kohdalla tavallista enemmän.'
 where lahde = 'liikenne' and cardinality(hsl_linjat(linjat)) = 1 and vaikutus like 'Linjat %';
select position('myöhästyy' in pg_get_functiondef(p.oid)) > 0 as ok from pg_proc p where p.proname = 'halytys_ajo';
