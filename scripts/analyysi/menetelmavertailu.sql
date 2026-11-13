-- Menetelmävertailu (vain luku), kevyt versio: 12 eniten ohitettua aktiivista lupaa.
-- Uusi = (välin päiväkeskiarvojen mediaani työn aikana, 7 vrk) − (sama ilman voimassa olevaa lupaa välillä, ±1 vrk puskuri).
with nyk as (
  select m.lupa_id, m.lisa_ajo nyk_s, m.ohitukset from lupa_mitta m
  where m.ikkuna = '7d' and m.jakso = 'kaikki' and m.ohitukset >= 30
  order by m.ohitukset desc limit 12),
l as (
  select distinct on (lupa_id) lupa_id, alkaa, paattyy, osoite from luvat_snapshot
  where snap_date > current_date - 60 and lupa_id in (select lupa_id from nyk) order by lupa_id, snap_date desc),
ls as (
  select s.lupa_id, s.from_stop, s.to_stop from lupa_segmentit s where s.lupa_id in (select lupa_id from nyk)),
segs as (select distinct from_stop, to_stop from ls),
-- kaikki luvat näillä väleillä (myös muut kuin top 12), jotta pohja on puhdas
kaikki_luvat as (
  select distinct s.from_stop, s.to_stop, x.alkaa::date a, coalesce(x.paattyy::date, current_date + 1) p
  from lupa_segmentit s join segs g using (from_stop, to_stop)
  join (select distinct on (lupa_id) lupa_id, alkaa, paattyy from luvat_snapshot where snap_date > current_date - 60
        order by lupa_id, snap_date desc) x using (lupa_id)
  where x.alkaa is not null),
h as (
  select h.from_stop, h.to_stop, h.route, h.dir, h.t, h.ddl_ajo
  from seg_havainto h join segs g using (from_stop, to_stop)
  where h.ddl_ajo is not null and abs(h.ddl_ajo) < 900),
rt as (select distinct route, dir from h),
ref as (
  select s.bucket, s.route, s.dir, sum(s.sum_ddl_ajo)/nullif(sum(s.n_ajo),0) ref_ajo
  from segment_2h s join rt using (route, dir)
  where s.bucket > now() - interval '22 days' and s.n_ajo > 0 group by 1,2,3),
o as (
  select h.from_stop, h.to_stop, h.route, h.dir, (h.t at time zone 'Europe/Helsinki')::date pv,
    case when extract(isodow from h.t at time zone 'Europe/Helsinki') in (6,7) then 'vkl'
         when extract(hour from h.t at time zone 'Europe/Helsinki') between 6 and 9 then 'aamu'
         when extract(hour from h.t at time zone 'Europe/Helsinki') between 10 and 14 then 'paiva'
         when extract(hour from h.t at time zone 'Europe/Helsinki') between 15 and 17 then 'ilta' else 'muu' end jakso,
    -(h.ddl_ajo - r.ref_ajo) lisa
  from h join ref r on r.bucket = date_bin('2 hours', h.t, timestamptz '2000-01-01') and r.route = h.route and r.dir = h.dir),
paiva as (
  select from_stop, to_stop, route, dir, jakso, pv, count(*) n, avg(lisa) lisa from o group by 1,2,3,4,5,6),
pl as (
  select p.*, exists (select 1 from kaikki_luvat k where k.from_stop = p.from_stop and k.to_stop = p.to_stop
                      and p.pv between k.a - 1 and k.p + 1) tyossa
  from paiva p),
pohja as (
  select from_stop, to_stop, route, dir, jakso, count(*) pv_n, percentile_cont(0.5) within group (order by lisa) med
  from pl where not tyossa group by 1,2,3,4,5),
aikana as (
  select x.lupa_id, p.from_stop, p.to_stop, p.route, p.dir, p.jakso, sum(p.n) n, count(*) pv_n,
    percentile_cont(0.5) within group (order by p.lisa) med
  from pl p join ls x using (from_stop, to_stop) join l using (lupa_id)
  where p.pv >= current_date - 7 and p.pv >= l.alkaa::date and (l.paattyy is null or p.pv <= l.paattyy::date)
  group by 1,2,3,4,5,6),
vali as (
  select a.lupa_id, a.route, a.dir, a.jakso, a.n, b.pv_n pohjapv, a.med - b.med ero
  from aikana a join pohja b using (from_stop, to_stop, route, dir, jakso)),
linja as (  -- linjan lisäaika = välien erojen summa, jaksot painotettuna ohituksilla
  select lupa_id, route, dir, sum(n) n, min(pohjapv) pohjapv,
    sum(ero_j * n_j) / sum(n_j) ero
  from (select lupa_id, route, dir, jakso, max(n) n_j, sum(ero) ero_j, sum(n) n, min(pohjapv) pohjapv
        from vali group by 1,2,3,4) j group by 1,2,3),
uusi as (
  select lupa_id, sum(n) n, min(pohjapv) min_pohjapv, round(percentile_cont(0.5) within group (order by pohjapv)) med_pohjapv,
    sum(ero * n) / sum(n) uusi_s from linja group by 1)
select l.osoite, nyk.lupa_id, nyk.ohitukset, round(nyk.nyk_s::numeric, 1) nykyinen_s, round(u.uusi_s::numeric, 1) uusi_s,
  round((u.uusi_s - nyk.nyk_s)::numeric, 1) muutos_s, u.min_pohjapv, u.med_pohjapv
from nyk left join l using (lupa_id) left join uusi u using (lupa_id)
order by nyk.ohitukset desc;
