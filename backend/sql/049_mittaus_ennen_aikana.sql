-- 049: Työn vaikutus mitataan samalta väliltä ilman töitä vs. työn aikana (kaikki välit, pysyvä päiväkooste).
--
-- 1) seg_paiva lasketaan nyt segment_2h:sta, joka kattaa KAIKKI bussi- ja ratikkavälit (ei vain lupien välejä).
--    Näin jokaisella uudella työllä on pohjataso valmiina jo ennen kuin lupa ilmestyy järjestelmään.
--    lisa = −(ddl_ajo − linjan keskiarvo samassa 2 h:n lohkossa), summattuna täsmälleen kuten havaintotasolla.
--    Jaksot: 'tyo' = arki noin klo 7–16 (sama kuin haitta-arvion päivätyö), 'muu' = muu aika.
-- 2) Säilytys: kaikki välit 45 vrk, lupien välit 400 vrk (seg_suoja).
-- 3) lupa_seg_hist muistaa lupien välit ja päivät myös luvan poistuttua rajapinnasta, jotta pohjapäivät ovat oikeasti puhtaita.
-- 4) paivita_vaikutus(): tila todennettu / alustava / pohjaa_kertyy / odottaa_paattymista / ei_pohjaa + vaihteluväli.

drop table if exists seg_paiva;
create table seg_paiva (
  pv date not null, from_stop integer not null, to_stop integer not null, route text not null, dir smallint not null,
  jakso text not null, n integer not null, sum_lisa real not null, n_seis integer not null, sum_lisa_seis real not null,
  primary key (from_stop, to_stop, pv, route, dir, jakso));
create index seg_paiva_pv on seg_paiva (pv);
alter table seg_paiva enable row level security;

create table if not exists lupa_seg_hist (
  lupa_id text not null, from_stop integer not null, to_stop integer not null,
  alkaa date, paattyy date, nahty date not null,
  primary key (lupa_id, from_stop, to_stop));
create index if not exists lupa_seg_hist_pari on lupa_seg_hist (from_stop, to_stop);
alter table lupa_seg_hist enable row level security;

create or replace function seg_paiva_laske(p_pv date) returns integer
language plpgsql security definer set search_path = public as $$
declare a timestamptz := (p_pv::timestamp at time zone 'Europe/Helsinki');
        b timestamptz := ((p_pv + 1)::timestamp at time zone 'Europe/Helsinki');
        k integer;
begin
  delete from seg_paiva where pv = p_pv;
  with s as (
    select bucket, from_stop, to_stop, route, coalesce(dir, 0)::smallint dir, n_ajo, sum_ddl_ajo, n_seis, sum_seis
    from segment_2h where bucket >= a and bucket < b and (n_ajo > 0 or n_seis > 0)),
  ref as (
    select bucket, route, dir, sum(sum_ddl_ajo) / nullif(sum(n_ajo), 0) ref_ajo, sum(sum_seis) / nullif(sum(n_seis), 0) ref_seis
    from s group by 1, 2, 3)
  insert into seg_paiva (pv, from_stop, to_stop, route, dir, jakso, n, sum_lisa, n_seis, sum_lisa_seis)
  select p_pv, s.from_stop, s.to_stop, s.route, s.dir,
    case when extract(isodow from s.bucket at time zone 'Europe/Helsinki') <= 5
          and extract(hour from (s.bucket + interval '1 hour') at time zone 'Europe/Helsinki') between 7 and 16 then 'tyo' else 'muu' end j,
    sum(s.n_ajo), coalesce(sum(-(s.sum_ddl_ajo - s.n_ajo * r.ref_ajo)) filter (where r.ref_ajo is not null), 0),
    sum(s.n_seis), coalesce(sum(s.sum_seis - s.n_seis * r.ref_seis) filter (where r.ref_seis is not null), 0)
  from s join ref r using (bucket, route, dir)
  group by 2, 3, 4, 5, 6
  having sum(s.n_ajo) > 0;
  get diagnostics k = row_count;
  return k;
end $$;
revoke all on function seg_paiva_laske(date) from public, anon, authenticated;

create or replace function seg_paiva_siivous() returns void
language sql security definer set search_path = public as $$
  delete from seg_paiva d where d.pv < current_date - 400
     or (d.pv < current_date - 45 and not exists (select 1 from lupa_seg_hist h where h.from_stop = d.from_stop and h.to_stop = d.to_stop));
  delete from lupa_seg_hist where nahty < current_date - 400;
$$;
revoke all on function seg_paiva_siivous() from public, anon, authenticated;

alter table lupa_vaikutus add column if not exists pohja_pv int;
alter table lupa_vaikutus add column if not exists aikana_pv int;
alter table lupa_vaikutus add column if not exists vali_ala real;
alter table lupa_vaikutus add column if not exists vali_yla real;
alter table lupa_vaikutus add column if not exists kattavuus real;

create or replace function paivita_vaikutus() returns text
language plpgsql security definer set search_path = public as $$
declare v_alku date := (select min(pv) from seg_paiva);
begin
  create temp table _l on commit drop as
  select distinct on (lupa_id) lupa_id, alkaa, paattyy, osoite
  from luvat_snapshot where snap_date > current_date - 45 and lupa_id in (select lupa_id from lupa_segmentit)
  order by lupa_id, snap_date desc;

  insert into lupa_seg_hist (lupa_id, from_stop, to_stop, alkaa, paattyy, nahty)
  select s.lupa_id, s.from_stop, s.to_stop, l.alkaa::date, l.paattyy::date, current_date
  from lupa_segmentit s join _l l using (lupa_id) where l.alkaa is not null
  on conflict (lupa_id, from_stop, to_stop) do update set alkaa = excluded.alkaa, paattyy = excluded.paattyy, nahty = excluded.nahty;

  create temp table _seg on commit drop as select distinct from_stop, to_stop from lupa_segmentit;

  -- välit × päivät, joina mikä tahansa lupa oli voimassa (±1 vrk). Avoin lupa: viimeiseen havaintopäivään asti.
  create temp table _tyo on commit drop as
  select distinct h.from_stop, h.to_stop, g::date pv
  from lupa_seg_hist h join _seg using (from_stop, to_stop)
  cross join generate_series(greatest(h.alkaa - 1, coalesce(v_alku, current_date)),
                             least(coalesce(h.paattyy, greatest(h.nahty, current_date)) + 1, current_date), interval '1 day') g
  where h.alkaa is not null;
  create index on _tyo (from_stop, to_stop, pv);

  create temp table _d on commit drop as
  select d.from_stop, d.to_stop, d.route, d.dir, d.jakso, d.pv, d.n, d.sum_lisa / d.n lisa,
    case when d.n_seis > 0 then d.sum_lisa_seis / d.n_seis end lisa_seis, (t.pv is not null) tyossa
  from seg_paiva d join _seg using (from_stop, to_stop)
  left join _tyo t on t.from_stop = d.from_stop and t.to_stop = d.to_stop and t.pv = d.pv
  where d.n >= 2;

  -- pohjataso: välin, linjan ja jakson mediaani päivinä ilman yhtään voimassa olevaa lupaa
  create temp table _b on commit drop as
  select from_stop, to_stop, route, dir, jakso, count(*) pv_n, sum(n) n, min(pv) eka, max(pv) vika,
    percentile_cont(0.5) within group (order by lisa) a,
    percentile_cont(0.5) within group (order by lisa_seis) s
  from _d where not tyossa group by 1, 2, 3, 4, 5 having count(*) >= 3;

  -- työn aikana: luvan voimassaolopäivät, enintään viimeiset 14 päivää
  create temp table _a on commit drop as
  select s.lupa_id, l.alkaa::date alkaa, l.paattyy::date paattyy, d.*
  from _d d join lupa_segmentit s using (from_stop, to_stop) join _l l using (lupa_id)
  where l.alkaa is not null and d.pv >= l.alkaa::date
    and d.pv <= least(coalesce(l.paattyy::date, current_date), current_date)
    and d.pv > least(coalesce(l.paattyy::date, current_date), current_date) - 14;

  -- päivä × linja × jakso: välien erojen summa (linja ajaa kaikki työmaan välit)
  create temp table _e on commit drop as
  select a.lupa_id, a.pv, a.route, a.dir, a.jakso, max(a.n) n, sum(a.lisa - b.a) ero, sum(a.lisa_seis - b.s) ero_seis,
    min(b.pv_n) pohja_pv, max(b.n) pohja_n, bool_and(b.vika < a.alkaa) ennen, bool_and(b.eka > a.paattyy) jalkeen
  from _a a join _b b using (from_stop, to_stop, route, dir, jakso)
  group by 1, 2, 3, 4, 5;

  -- kattavuus: kuinka suuri osa työn aikaisista ohituksista saatiin verrattua
  create temp table _kat on commit drop as
  select x.lupa_id, sum(coalesce(e.n, 0))::float / nullif(sum(x.n), 0) kattavuus
  from (select lupa_id, pv, route, dir, jakso, max(n) n from _a group by 1, 2, 3, 4, 5) x
  left join _e e using (lupa_id, pv, route, dir, jakso) group by 1;

  -- luvan päiväluku = linjojen ja jaksojen ohituksilla painotettu keskiarvo
  create temp table _p on commit drop as
  select lupa_id, pv, sum(n * ero) / sum(n) ero, sum(n * ero_seis) filter (where ero_seis is not null) / nullif(sum(n) filter (where ero_seis is not null), 0) ero_seis, sum(n) n
  from _e group by 1, 2;

  create temp table _ln on commit drop as
  select lupa_id, route, dir, sum(n * ero) / sum(n) ero, sum(n)::int n_a, max(pohja_n)::int n_b
  from _e group by 1, 2, 3;

  create temp table _oh on commit drop as
  select lupa_id, route, dir, ohitukset from lupa_mitta_linja where ikkuna = '24h' and jakso = 'kaikki';

  create temp table _v on commit drop as
  select p.lupa_id, count(*)::int aikana_pv, sum(p.n)::int aikana_n,
    percentile_cont(0.5) within group (order by p.ero) s,
    percentile_cont(0.5) within group (order by p.ero_seis) seis,
    case when count(*) >= 4 then percentile_cont(0.25) within group (order by p.ero) else min(p.ero) end ala,
    case when count(*) >= 4 then percentile_cont(0.75) within group (order by p.ero) else max(p.ero) end yla
  from _p p group by 1;

  delete from lupa_vaikutus where lupa_id in (select lupa_id from _l) or paivitetty < now() - interval '400 days';
  insert into lupa_vaikutus (lupa_id, tila, vertailu, alkaa, paattyy, osoite, pohja_n, aikana_n, vaikutus_s, vaikutus_seis,
                             ajoneuvotunnit_vrk, linjat, jaksot, paivitetty, pohja_pv, aikana_pv, vali_ala, vali_yla, kattavuus)
  select l.lupa_id,
    case when now() < l.alkaa then 'pohjaa_kertyy'
         when v.lupa_id is not null and q.pohja_pv >= 5 and v.aikana_pv >= 2 and k.kattavuus >= 0.5 then 'todennettu'
         when v.lupa_id is not null then 'alustava'
         when l.alkaa::date <= coalesce(v_alku, current_date) then 'odottaa_paattymista'
         else 'ei_pohjaa' end,
    case when q.ennen then 'ennen' when q.jalkeen then 'jalkeen' when v.lupa_id is not null then 'ilman' end,
    l.alkaa, l.paattyy, l.osoite,
    coalesce(q.pohja_n, pk.n), v.aikana_n, v.s, v.seis, ln.vehh, ln.linjat, null, now(),
    q.pohja_pv, v.aikana_pv, v.ala, v.yla, k.kattavuus
  from _l l
  left join _v v using (lupa_id)
  left join _kat k using (lupa_id)
  left join (select lupa_id, round(percentile_cont(0.5) within group (order by pohja_pv))::int pohja_pv,
                    max(pohja_n)::int pohja_n, bool_and(ennen) ennen, bool_and(jalkeen) jalkeen
             from _e group by 1) q using (lupa_id)
  left join (select n.lupa_id, sum(coalesce(o.ohitukset, 0) * n.ero) / 3600.0 vehh,
                    jsonb_agg(jsonb_build_object('route', n.route, 'dir', n.dir, 'ero', round(n.ero::numeric, 1), 'n_a', n.n_a, 'n_b', n.n_b, 'ohit_vrk', o.ohitukset) order by n.n_a desc) linjat
             from _ln n left join _oh o on o.lupa_id = n.lupa_id and o.route = n.route and o.dir = n.dir
             group by 1) ln using (lupa_id)
  left join (select s.lupa_id, sum(b.n)::int n from lupa_segmentit s join _b b using (from_stop, to_stop) group by 1) pk using (lupa_id);

  return 'todennettu ' || (select count(*) from lupa_vaikutus where tila = 'todennettu')
      || ', alustava ' || (select count(*) from lupa_vaikutus where tila = 'alustava');
end $$;
revoke all on function paivita_vaikutus() from public, anon, authenticated;

-- Ajastus: tämän päivän osakooste tunneittain, edelliset 2 päivää yöllä (myöhästyneet havainnot), siivous.
do $$ begin
  perform cron.unschedule('seg-paiva') where exists (select 1 from cron.job where jobname = 'seg-paiva');
  perform cron.unschedule('seg-paiva-tanaan') where exists (select 1 from cron.job where jobname = 'seg-paiva-tanaan');
end $$;
select cron.schedule('seg-paiva', '50 1 * * *', $$select seg_paiva_laske(current_date - 1); select seg_paiva_laske(current_date - 2); select seg_paiva_siivous()$$);
select cron.schedule('seg-paiva-tanaan', '5 * * * *', $$select seg_paiva_laske(current_date)$$);
