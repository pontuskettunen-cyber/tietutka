-- 018: Säähavainnot (Ilmatieteen laitos, Kaisaniemi) 10 min välein ja 2 tunnin jaksoina samoihin aikaväleihin kuin bussien mittaukset.
create table if not exists saa_havainto (
  t timestamptz primary key,
  asema int,
  t2m real, ri real, lumi real, tuuli real, wawa smallint
);
alter table saa_havainto enable row level security;

-- Luokitus: WMO 4680 -säätilakoodi (wawa) ja sateen intensiteetti (ri, mm/h).
create or replace view v_saa_2h with (security_invoker = false) as
select date_bin('2 hours', t, timestamptz '2000-01-01 00:00+00') bucket,
  round(avg(t2m)::numeric, 1) lampo,
  round((sum(coalesce(ri,0)) / 6.0)::numeric, 1) sade_mm,
  round(max(ri)::numeric, 1) sade_max,
  max(lumi) lumi_cm,
  round(max(tuuli)::numeric, 1) tuuli,
  case
    when count(*) filter (where wawa between 70 and 78 or wawa between 85 and 87) >= 2 then 'lumisade'
    when count(*) filter (where wawa in (54,55,56,64,65,66)) >= 1 then 'jäätävä sade'
    when count(*) filter (where wawa in (67,68)) >= 1 or (sum(coalesce(ri,0)) > 0.6 and avg(t2m) between -1 and 1.5) then 'räntä, liukasta'
    when max(ri) >= 5 or sum(coalesce(ri,0)) / 6.0 >= 4 then 'rankkasade'
    when sum(coalesce(ri,0)) / 6.0 >= 0.3 then 'sade'
    when min(t2m) <= -10 then 'kova pakkanen'
    else 'pouta'
  end luokka,
  count(*) n
from saa_havainto
where t > now() - interval '60 days'
group by 1;
grant select on v_saa_2h to anon, authenticated;

do $$ begin
  perform cron.unschedule('saa-10min') where exists (select 1 from cron.job where jobname = 'saa-10min');
  perform cron.schedule('saa-10min', '7,17,27,37,47,57 * * * *',
    replace((select command from cron.job where jobname = 'reittiviivat-tunti'), 'functions/v1/reittiviivat', 'functions/v1/saa-haku'));
end $$;
