-- Työmaatutka 009: päiväkohtainen historia ja mittausjakson näkyvyys
-- lupa_paiva: jokaisen luvan mitattu lisäaika ja ajoneuvotunnit Helsingin vuorokausittain
-- kok_paiva:  koko kaupungin summa vuorokausittain (vertailut: eilinen samalla päivätyypillä, viikko sitten)

create table if not exists lupa_paiva (
  pv date, lupa_id text, n int, ohitukset int, lisa_ajo real, ajoneuvotunnit real,
  primary key (pv, lupa_id));
create table if not exists kok_paiva (
  pv date primary key, paivatyyppi text, ajoneuvotunnit real, tyomaita int, havaintoja int,
  mitattu_alkaen timestamptz, mitattu_asti timestamptz);
alter table lupa_paiva enable row level security;
alter table kok_paiva enable row level security;

create or replace function paivita_paivat() returns text
language plpgsql security definer set search_path = public as $$
begin
  create temp table _r on commit drop as
  select bucket, route, dir, sum(sum_ddl_ajo)/nullif(sum(n_ajo),0) ref_ajo
  from segment_2h where bucket > now() - interval '16 days' and n_ajo > 0 group by 1,2,3;
  create index on _r (bucket, route, dir);

  create temp table _p on commit drop as
  select (h.t at time zone 'Europe/Helsinki')::date pv, ls.lupa_id, h.route, h.dir, h.from_stop, h.to_stop,
    -(h.ddl_ajo - r.ref_ajo) lisa
  from seg_havainto h
  join lupa_segmentit ls on ls.from_stop = h.from_stop and ls.to_stop = h.to_stop
  join _r r on r.bucket = date_bin('2 hours', h.t, timestamptz '2000-01-01') and r.route = h.route and r.dir = h.dir
  where h.t > now() - interval '15 days' and h.ddl_ajo is not null;

  delete from lupa_paiva where pv >= (now() at time zone 'Europe/Helsinki')::date - 15;
  insert into lupa_paiva
  select pv, lupa_id, sum(n)::int, sum(n)::int,
    sum(n*lisa)/nullif(sum(n),0), sum(n*greatest(lisa,0))/3600.0
  from (
    select pv, lupa_id, route, dir, max(n) n, sum(med) lisa
    from (select pv, lupa_id, route, dir, from_stop, to_stop, count(*) n,
            percentile_cont(0.5) within group (order by lisa) med
          from _p group by 1,2,3,4,5,6) s
    group by 1,2,3,4) r
  group by pv, lupa_id;

  delete from kok_paiva where pv >= (now() at time zone 'Europe/Helsinki')::date - 15;
  insert into kok_paiva
  select lp.pv,
    case when extract(isodow from lp.pv) in (6,7) then 'viikonloppu' else 'arki' end,
    sum(case when lp.n >= 10 then lp.ajoneuvotunnit else 0 end),
    count(*) filter (where lp.n >= 10 and lp.lisa_ajo > 0),
    sum(lp.n)::int,
    (select min(t) from seg_havainto where (t at time zone 'Europe/Helsinki')::date = lp.pv),
    (select max(t) from seg_havainto where (t at time zone 'Europe/Helsinki')::date = lp.pv)
  from lupa_paiva lp where lp.pv >= (now() at time zone 'Europe/Helsinki')::date - 15
  group by lp.pv;

  return 'päiviä '||(select count(*) from kok_paiva);
end $$;
revoke execute on function paivita_paivat() from public, anon, authenticated;

create or replace view v_kok_paiva with (security_invoker = false) as select * from kok_paiva order by pv;
create or replace view v_lupa_paiva with (security_invoker = false) as select * from lupa_paiva where pv > (now() at time zone 'Europe/Helsinki')::date - 15;
grant select on v_kok_paiva, v_lupa_paiva to anon, authenticated;

-- mittausjakso tilanäkymään
drop view if exists v_tila;
create view v_tila with (security_invoker = false) as
select
  (select count(*) from seg_havainto) tapahtumia,
  (select count(*) from seg_havainto where t > now() - interval '10 minutes') viim_10_min,
  (select count(distinct route) from segment_2h where bucket > now() - interval '24 hours') linjoja_24h,
  (select coalesce(sum(n),0) from segment_2h) pysakkivali_havainnot,
  (select count(*) from (select distinct from_stop, to_stop from segment_2h) x) pysakkivaleja,
  (select max(alkoi) from tallennin_loki where funktio = 'hfp-segmentit') viimeisin,
  (select min(bucket) from segment_2h) keruu_alkoi,
  (select count(*) from luvat_snapshot where snap_date = (select max(snap_date) from luvat_snapshot)) lupia_tanaan,
  (select count(*) from tietyot_snapshot where snap_date = (select max(snap_date) from tietyot_snapshot)) tietoita_tanaan,
  round(pg_database_size(current_database()) / 1e6) db_mb,
  (select min(t) from seg_havainto) havainto_alkoi;
grant select on v_tila to anon, authenticated;

select cron.schedule('paivat-30min', '9,39 * * * *', $$select paivita_paivat()$$);
select paivita_paivat();
