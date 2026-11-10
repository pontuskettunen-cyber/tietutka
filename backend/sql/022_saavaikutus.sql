-- 022: Sään vaikutus busseihin, linjoihin ja työmaihin.
-- Menetelmä: jokaisen pysäkkivälin (linja, suunta) keskimääräistä ajoaikaa verrataan saman välin omaan poutatasoon
-- samassa vuorokaudenjaksossa ja päivätyypissä (arki / viikonloppu). Näin ruuhka ja vuorokaudenaika eivät sekoitu säähän.
-- Työmaalle lasketaan, paljonko sen välit hidastuvat kussakin säässä ja paljonko muu kaupunki hidastuu samassa säässä:
-- erotus kertoo, pahentaako sää työmaan haittaa.
create table if not exists saa_kerroin (luokka text primary key, kerroin real, jaksot int, n int, paivitetty timestamptz default now());
create table if not exists saa_linja (route text, luokka text, kerroin real, jaksot int, n int, primary key (route, luokka));
create table if not exists saa_tyomaa (lupa_id text, luokka text, lisa_s real, odotettu_s real, jaksot int, n int, primary key (lupa_id, luokka));
create table if not exists saa_jaksot (luokka text primary key, jaksot int);
alter table saa_kerroin enable row level security; alter table saa_linja enable row level security;
alter table saa_tyomaa enable row level security; alter table saa_jaksot enable row level security;

create or replace function paivita_saavaikutus() returns text
language plpgsql security definer set search_path = public as $$
begin
  create temp table _w on commit drop as
  select bucket, luokka from v_saa_2h where bucket > now() - interval '21 days' and n >= 6;
  create index on _w (bucket);

  create temp table _s on commit drop as
  select s.bucket, s.from_stop, s.to_stop, s.route, s.dir, w.luokka,
    case when extract(isodow from s.bucket at time zone 'Europe/Helsinki') >= 6 then 'vl' else 'arki' end
      || case when extract(hour from s.bucket at time zone 'Europe/Helsinki') between 6 and 8 then 'aamu'
              when extract(hour from s.bucket at time zone 'Europe/Helsinki') between 9 and 14 then 'paiva'
              when extract(hour from s.bucket at time zone 'Europe/Helsinki') between 15 and 17 then 'ruuhka'
              when extract(hour from s.bucket at time zone 'Europe/Helsinki') between 18 and 21 then 'ilta' else 'yo' end jakso,
    s.sum_tt, s.n
  from segment_2h s join _w w on w.bucket = s.bucket
  where s.bucket > now() - interval '21 days' and s.n > 0 and s.sum_tt > 0;

  -- poutataso: välin oma keskiarvo samassa jaksossa poutasäällä
  create temp table _base on commit drop as
  select from_stop, to_stop, route, dir, jakso, sum(sum_tt) / sum(n) base, sum(n) bn
  from _s where luokka = 'pouta' group by 1,2,3,4,5 having sum(n) >= 5;
  create index on _base (from_stop, to_stop, route, dir, jakso);

  create temp table _r on commit drop as
  select s.bucket, s.from_stop, s.to_stop, s.route, s.dir, s.luokka, s.n, (s.sum_tt / s.n) tt, b.base
  from _s s join _base b using (from_stop, to_stop, route, dir, jakso)
  where s.luokka <> 'pouta';

  delete from saa_jaksot;
  insert into saa_jaksot select luokka, count(*) from _w where luokka <> 'pouta' group by 1;

  delete from saa_kerroin;
  insert into saa_kerroin (luokka, kerroin, jaksot, n)
  select luokka, sum(n * tt / base) / sum(n) - 1, count(distinct bucket), sum(n) from _r group by 1;

  delete from saa_linja;
  insert into saa_linja (route, luokka, kerroin, jaksot, n)
  select route, luokka, sum(n * tt / base) / sum(n) - 1, count(distinct bucket), sum(n)
  from _r group by 1, 2 having sum(n) >= 40 and count(distinct bucket) >= 2;

  delete from saa_tyomaa;
  insert into saa_tyomaa (lupa_id, luokka, lisa_s, odotettu_s, jaksot, n)
  select ls.lupa_id, r.luokka,
    sum(r.n * (r.tt - r.base)) / sum(r.n),
    sum(r.n * r.base * k.kerroin) / sum(r.n),
    count(distinct r.bucket), sum(r.n)
  from lupa_segmentit ls
  join _r r on r.from_stop = ls.from_stop and r.to_stop = ls.to_stop
  join saa_kerroin k on k.luokka = r.luokka
  group by 1, 2 having sum(r.n) >= 15;

  return 'kertoimia '||(select count(*) from saa_kerroin)||', linjoja '||(select count(*) from saa_linja)||', työmaita '||(select count(distinct lupa_id) from saa_tyomaa);
end $$;
revoke execute on function paivita_saavaikutus() from public, anon, authenticated;

create or replace view v_saa_kerroin with (security_invoker = false) as
select j.luokka, k.kerroin, coalesce(k.jaksot, 0) jaksot, coalesce(k.n, 0) n, j.jaksot saajaksot, k.paivitetty
from saa_jaksot j left join saa_kerroin k using (luokka);
create or replace view v_saa_linja with (security_invoker = false) as select * from saa_linja;
create or replace view v_saa_tyomaa with (security_invoker = false) as select * from saa_tyomaa;
grant select on v_saa_kerroin, v_saa_linja, v_saa_tyomaa to anon, authenticated;

do $$ begin
  perform cron.unschedule('saavaikutus-tunti') where exists (select 1 from cron.job where jobname = 'saavaikutus-tunti');
  perform cron.schedule('saavaikutus-tunti', '40 * * * *', $c$select paivita_saavaikutus()$c$);
end $$;
