-- 015: HSL:n häiriötiedotteet (Digitransit) poikkeusreittien varmistukseen
create table if not exists hsl_hairiot (
  id text primary key,
  otsikko text, kuvaus text, vaikutus text, syy text, vakavuus text,
  alkaa timestamptz, paattyy timestamptz,
  reitit text[] default '{}', pysakit text[] default '{}',
  paivitetty timestamptz default now(), poistunut timestamptz
);
alter table hsl_hairiot enable row level security;

create or replace view v_hairiot with (security_invoker = false) as
select id, otsikko, kuvaus, vaikutus, syy, vakavuus, alkaa, paattyy, reitit, pysakit
from hsl_hairiot
where poistunut is null and (paattyy is null or paattyy > now() - interval '1 day');
grant select on v_hairiot to anon, authenticated;

-- haku 15 min välein (sama kutsutapa kuin muilla funktioilla)
do $$ begin
  perform cron.unschedule('hsl-hairiot-15min') where exists (select 1 from cron.job where jobname = 'hsl-hairiot-15min');
  perform cron.schedule('hsl-hairiot-15min', '4,19,34,49 * * * *',
    replace((select command from cron.job where jobname = 'reittiviivat-tunti'), 'functions/v1/reittiviivat', 'functions/v1/hsl-hairiot'));
end $$;
