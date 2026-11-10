-- 016: Liikennevaloetuisuus pysäkkiväleittäin (HSL HFP: TLR = pyyntö, TLA = vastaus ACK/NAK)
-- HUOM: HSL:n TLA-vastaus on kuittaus (ACK), ei tieto vihreästä valosta, joten myönnetty/evätty ei ole käytettävissä.
-- Käytetään valo-ohjattujen risteysten määrää välillä (etuisuuspyyntöjä per ohitus).
-- Erottaa valojen ja työmaan vaikutuksen: verrataan ajoaikaa niillä ohituksilla, joilla etuisuus evättiin, niihin joilla ei.
alter table seg_havainto add column if not exists valo_pyynto smallint, add column if not exists valo_ok smallint, add column if not exists valo_ei smallint;

drop view if exists v_vali_valot;
create view v_vali_valot with (security_invoker = false) as
select from_stop, to_stop,
  count(*) filter (where valo_pyynto is not null) n,
  count(*) filter (where valo_pyynto > 0) n_valo,
  round(avg(valo_pyynto)::numeric, 1) valoja_per_ohitus,
  sum(valo_pyynto) pyynnot, sum(valo_ok) myonnetty, sum(valo_ei) evatty,
  round(avg(ddl_ajo) filter (where valo_pyynto > 0 and coalesce(valo_ei,0) = 0)::numeric, 1) viive_ei_evatty,
  round(avg(ddl_ajo) filter (where valo_ei > 0)::numeric, 1) viive_evatty,
  count(*) filter (where valo_ei > 0) n_evatty,
  round(avg(ddl_ajo) filter (where valo_pyynto = 0)::numeric, 1) viive_ei_valoja
from seg_havainto
where t > greatest(now() - interval '7 days', '2026-11-02 15:55+00'::timestamptz) and valo_pyynto is not null
group by from_stop, to_stop;
grant select on v_vali_valot to anon, authenticated;
