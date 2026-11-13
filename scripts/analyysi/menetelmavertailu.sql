-- Menetelmävertailu (vain luku): nykyinen "lisäaika per ohitus" vs. sama väli työn aikana miinus sama väli ilman työtä.
with l as (
  select distinct on (lupa_id) lupa_id, alkaa, paattyy, osoite from luvat_snapshot
  where snap_date > current_date - 45 order by lupa_id, snap_date desc),
ls as (
  select s.lupa_id, s.from_stop, s.to_stop, l.alkaa, coalesce(l.paattyy + interval '1 day', 'infinity'::timestamptz) loppu
  from lupa_segmentit s join l using (lupa_id) where l.alkaa is not null),
segs as (select distinct from_stop, to_stop from ls),
ref as (
  select bucket, route, dir, sum(sum_ddl_ajo)/nullif(sum(n_ajo),0) ref_ajo
  from segment_2h where bucket > now() - interval '22 days' and n_ajo > 0 group by 1,2,3),
o as (
  select h.from_stop, h.to_stop, h.route, h.dir, h.t,
    case when extract(isodow from h.t at time zone 'Europe/Helsinki') in (6,7) then 'muu'
         when extract(hour from h.t at time zone 'Europe/Helsinki') between 6 and 9 then 'aamu'
         when extract(hour from h.t at time zone 'Europe/Helsinki') between 10 and 14 then 'paiva'
         when extract(hour from h.t at time zone 'Europe/Helsinki') between 15 and 17 then 'ilta' else 'muu' end jakso,
    -(h.ddl_ajo - r.ref_ajo) lisa
  from seg_havainto h join segs g on g.from_stop = h.from_stop and g.to_stop = h.to_stop
  join ref r on r.bucket = date_bin('2 hours', h.t, timestamptz '2000-01-01') and r.route = h.route and r.dir = h.dir
  where h.ddl_ajo is not null and abs(h.ddl_ajo) < 900 and r.ref_ajo is not null),
-- havainto on "ilman työtä", jos yksikään välin lupa ei ollut voimassa (±1 vrk puskuri)
tyossa as (
  select distinct o.from_stop, o.to_stop, o.t from o join ls x on x.from_stop = o.from_stop and x.to_stop = o.to_stop
  and o.t >= x.alkaa - interval '1 day' and o.t < x.loppu + interval '1 day'),
pohja as (
  select o.from_stop, o.to_stop, o.route, o.dir, o.jakso, count(*) n,
    count(distinct (o.t at time zone 'Europe/Helsinki')::date) pv, percentile_cont(0.5) within group (order by o.lisa) med
  from o left join tyossa w on w.from_stop = o.from_stop and w.to_stop = o.to_stop and w.t = o.t
  where w.t is null group by 1,2,3,4,5),
aikana as (
  select x.lupa_id, o.from_stop, o.to_stop, o.route, o.dir, o.jakso, count(*) n,
    count(distinct (o.t at time zone 'Europe/Helsinki')::date) pv, percentile_cont(0.5) within group (order by o.lisa) med
  from o join ls x on x.from_stop = o.from_stop and x.to_stop = o.to_stop and o.t >= x.alkaa and o.t < x.loppu
  where o.t > now() - interval '7 days'
  group by 1,2,3,4,5,6),
vali as (
  select a.lupa_id, a.route, a.dir, a.jakso, a.from_stop, a.to_stop, a.n n_a, a.pv pv_a, a.med aikana_med,
    p.n n_p, p.pv pv_p, p.med pohja_med, a.med - p.med ero
  from aikana a join pohja p using (from_stop, to_stop, route, dir, jakso)
  where a.n >= 5 and p.n >= 5),
linja as (  -- linja ajaa kaikki työmaan välit: summa väleittäin, jaksoista ohituksilla painotettu
  select lupa_id, route, dir, sum(n_a) n_a, min(pv_p) pv_p,
    sum(ero * n_a) / sum(n_a) * count(distinct (from_stop, to_stop)) / count(distinct (from_stop, to_stop)) ero_vali,
    sum(ero) / count(distinct jakso) ero_linja
  from vali group by 1,2,3),
uusi as (
  select lupa_id, sum(n_a) n_a, min(pv_p) pv_pohja, sum(n_a * ero_linja) / sum(n_a) uusi_s from linja group by 1),
nyk as (select lupa_id, lisa_ajo nyk_s, ohitukset from lupa_mitta where ikkuna = '7d' and jakso = 'kaikki'),
kaikki as (
  select l.osoite, l.lupa_id, round(n.nyk_s::numeric, 1) nykyinen_s, round(u.uusi_s::numeric, 1) uusi_s,
    round((u.uusi_s - n.nyk_s)::numeric, 1) muutos_s, u.n_a ohituksia_aikana, u.pv_pohja pohjapaivia, n.ohitukset
  from l join nyk n using (lupa_id) left join uusi u using (lupa_id)
  where l.alkaa <= now() and (l.paattyy is null or l.paattyy >= now() - interval '1 day') and n.ohitukset >= 30)
select * from (
  select 'YHTEENVETO' osoite, null lupa_id,
    round(avg(nykyinen_s), 1) nykyinen_s, round(avg(uusi_s), 1) uusi_s, round(avg(uusi_s - nykyinen_s), 1) muutos_s,
    count(*)::int ohituksia_aikana, count(uusi_s)::int pohjapaivia, null::int ohitukset, 0 jarj
  from kaikki
  union all
  select osoite, lupa_id, nykyinen_s, uusi_s, muutos_s, ohituksia_aikana, pohjapaivia, ohitukset, 1 from kaikki
) z order by jarj, ohitukset desc nulls last limit 40;
