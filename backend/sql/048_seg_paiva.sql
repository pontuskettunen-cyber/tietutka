-- 048: Välin päiväkooste (säilytetään 400 vrk). Pohja uudelle "ennen/aikana"-mittaukselle.
-- lisa = −(ddl_ajo − linjan keskiarvo samassa 2 h:n lohkossa), kuten 007:ssä. Tallennetaan summina, jotta yhdistely on tarkka.
create table if not exists seg_paiva (
  pv date not null, from_stop integer not null, to_stop integer not null, route text not null, dir smallint not null,
  jakso text not null, n integer not null, sum_lisa real not null, sum_ajo real not null,
  primary key (from_stop, to_stop, pv, route, dir, jakso));
create index if not exists seg_paiva_pv on seg_paiva (pv);
alter table seg_paiva enable row level security;

create or replace function seg_paiva_laske(p_pv date) returns integer
language plpgsql security definer set search_path = public as $$
declare a timestamptz := (p_pv::timestamp at time zone 'Europe/Helsinki');
        b timestamptz := ((p_pv + 1)::timestamp at time zone 'Europe/Helsinki');
        k integer;
begin
  delete from seg_paiva where pv = p_pv;
  with h as (
    select from_stop, to_stop, route, coalesce(dir, 0)::smallint dir, t, ddl_ajo
    from seg_havainto where t >= a and t < b and ddl_ajo is not null and abs(ddl_ajo) < 900),
  ref as (
    select bucket, route, coalesce(dir, 0)::smallint dir, sum(sum_ddl_ajo) / nullif(sum(n_ajo), 0) ref_ajo
    from segment_2h where bucket >= a - interval '2 hours' and bucket < b and n_ajo > 0 group by 1, 2, 3)
  insert into seg_paiva (pv, from_stop, to_stop, route, dir, jakso, n, sum_lisa, sum_ajo)
  select p_pv, h.from_stop, h.to_stop, h.route, h.dir,
    case when extract(isodow from h.t at time zone 'Europe/Helsinki') in (6, 7) then 'vkl'
         when extract(hour from h.t at time zone 'Europe/Helsinki') between 6 and 9 then 'aamu'
         when extract(hour from h.t at time zone 'Europe/Helsinki') between 10 and 14 then 'paiva'
         when extract(hour from h.t at time zone 'Europe/Helsinki') between 15 and 17 then 'ilta' else 'muu' end,
    count(*), sum(-(h.ddl_ajo - r.ref_ajo)), sum(h.ddl_ajo)
  from h join ref r on r.bucket = date_bin('2 hours', h.t, timestamptz '2000-01-01') and r.route = h.route and r.dir = h.dir
  where r.ref_ajo is not null
  group by 2, 3, 4, 5, 6;
  get diagnostics k = row_count;
  return k;
end $$;
revoke all on function seg_paiva_laske(date) from public, anon, authenticated;

-- Yöllinen kooste eiliselle ja toissapäivälle (myöhästyneet havainnot), siivous 400 vrk.
select cron.schedule('seg-paiva', '50 1 * * *', $$select seg_paiva_laske(current_date - 1); select seg_paiva_laske(current_date - 2); delete from seg_paiva where pv < current_date - 400$$);
