-- 020: Uusin säähavainto etusivun sääkorttiin
create or replace view v_saa_nyt with (security_invoker = false) as
select t, t2m, ri, lumi, tuuli, wawa from saa_havainto where t2m is not null order by t desc limit 1;
grant select on v_saa_nyt to anon, authenticated;
