-- Menetelmävertailu (vain luku) seg_paiva-koosteesta.
-- Uusi = välin päiväkeskiarvojen mediaani työn aikana (7 vrk) − mediaani päivinä, jolloin välillä ei ollut yhtään voimassa olevaa lupaa (±1 vrk).
with nyk as (
  select lupa_id, lisa_ajo nyk_s, ohitukset from lupa_mitta where ikkuna = '7d' and jakso = 'kaikki' and ohitukset >= 30),
ls as (select s.lupa_id, s.from_stop, s.to_stop from lupa_segmentit s join nyk using (lupa_id)),
segs as (select distinct from_stop, to_stop from ls),
ids as (select distinct s.lupa_id from lupa_segmentit s join segs using (from_stop, to_stop)),
lv as (  -- viimeisin tieto jokaisesta välin luvasta (myös päättyneistä), indeksin kautta
  select i.lupa_id, x.alkaa::date a, coalesce(x.paattyy::date, current_date + 1) p, x.osoite
  from ids i cross join lateral (select alkaa, paattyy, osoite from luvat_snapshot l
    where l.lupa_id = i.lupa_id order by snap_date desc limit 1) x where x.alkaa is not null),
kl as (  -- välit × päivät, joina jokin lupa oli voimassa (±1 vrk)
  select distinct s.from_stop, s.to_stop, g::date pv
  from lupa_segmentit s join segs using (from_stop, to_stop) join lv using (lupa_id)
  cross join generate_series(greatest(lv.a - 1, current_date - 30), least(lv.p + 1, current_date), interval '1 day') g),
pl as (
  select d.*, d.sum_lisa / d.n lisa, (k.pv is not null) tyossa
  from seg_paiva d join segs using (from_stop, to_stop)
  left join kl k on k.from_stop = d.from_stop and k.to_stop = d.to_stop and k.pv = d.pv
  where d.n >= 2),
pohja as (
  select from_stop, to_stop, route, dir, jakso, count(*) pv_n, percentile_cont(0.5) within group (order by lisa) med
  from pl where not tyossa group by 1,2,3,4,5 having count(*) >= 3),
aikana as (
  select x.lupa_id, p.from_stop, p.to_stop, p.route, p.dir, p.jakso, sum(p.n) n, count(*) pv_n,
    percentile_cont(0.5) within group (order by p.lisa) med
  from pl p join ls x using (from_stop, to_stop) join lv using (lupa_id)
  where p.pv >= current_date - 7 and p.pv between lv.a and lv.p
  group by 1,2,3,4,5,6),
j as (  -- linja × jakso: välien erot summataan (linja ajaa kaikki välit)
  select a.lupa_id, a.route, a.dir, a.jakso, max(a.n) n, sum(a.med - b.med) ero, min(b.pv_n) pohjapv,
    count(*) valit_mitattu
  from aikana a join pohja b using (from_stop, to_stop, route, dir, jakso) group by 1,2,3,4),
u as (
  select lupa_id, sum(n) n_mitattu, min(pohjapv) min_pohjapv, sum(ero * n) / sum(n) uusi_s from j group by 1),
tot as (select lupa_id, sum(n) n_kaikki from aikana group by 1)
select coalesce(lv.osoite, nyk.lupa_id) osoite, nyk.ohitukset,
  round(nyk.nyk_s::numeric, 1) nykyinen_s, round(u.uusi_s::numeric, 1) uusi_s,
  round((u.uusi_s - nyk.nyk_s)::numeric, 1) muutos_s,
  round(100.0 * u.n_mitattu / nullif(tot.n_kaikki, 0)) kattavuus_pct, u.min_pohjapv,
  lv.a alkoi
from nyk left join lv using (lupa_id) left join u using (lupa_id) left join tot using (lupa_id)
order by (u.uusi_s is null), nyk.ohitukset desc limit 60;
