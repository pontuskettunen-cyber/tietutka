-- 021: Sademäärä tunnin kertymästä (r_1h, mitattu) eikä intensiteetistä arvioituna.
-- Tarkistus 3.11.2026: intensiteetistä laskettu 24 h summa 1,1 mm vs. Ilmatieteen laitoksen tuntikertymä 1,5 mm.
alter table saa_havainto add column if not exists r1h real;
create or replace view v_saa_2h with (security_invoker = false) as
select date_bin('2 hours', t, timestamptz '2000-01-01 00:00+00') bucket,
  round(avg(t2m)::numeric, 1) lampo,
  round(coalesce(sum(r1h), sum(coalesce(ri,0)) / 6.0)::numeric, 1) sade_mm,
  round(max(ri)::numeric, 1) sade_max,
  max(lumi) lumi_cm,
  round(max(tuuli)::numeric, 1) tuuli,
  case
    when count(*) filter (where wawa between 70 and 78 or wawa between 85 and 87) >= 2 then 'lumisade'
    when count(*) filter (where wawa in (54,55,56,64,65,66)) >= 1 then 'jäätävä sade'
    when count(*) filter (where wawa in (67,68)) >= 1 or (coalesce(sum(r1h), sum(coalesce(ri,0)) / 6.0) > 0.6 and avg(t2m) between -1 and 1.5) then 'räntä, liukasta'
    when max(ri) >= 5 or coalesce(sum(r1h), sum(coalesce(ri,0)) / 6.0) >= 4 then 'rankkasade'
    when coalesce(sum(r1h), sum(coalesce(ri,0)) / 6.0) >= 0.3 or count(*) filter (where ri > 0) >= 3 then 'sade'
    when min(t2m) <= -10 then 'kova pakkanen'
    else 'pouta'
  end luokka,
  count(*) n
from saa_havainto
where t > now() - interval '60 days'
group by 1;
grant select on v_saa_2h to anon, authenticated;
