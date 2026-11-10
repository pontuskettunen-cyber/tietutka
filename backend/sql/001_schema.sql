-- Työmaatutka: perusrakenne
-- Luvanhaltijan ja työn suorittajan tietoja EI tallenneta (tavoite koordinaatio, ei nimeäminen).

create table if not exists public.luvat_snapshot (
  snap_date      date        not null,
  layer          text        not null,          -- esim. Tilapainen_liikennejarjestely_alue
  lupa_id        text        not null,          -- hakemustunnus tai id
  hakemuksen_laji text,
  alkaa          timestamptz,
  paattyy        timestamptz,
  tarkoitus      text,
  osoite         text,
  kaupunginosa   text,
  status         text,
  geom           jsonb,                         -- GeoJSON (EPSG:4326)
  haettu         timestamptz not null default now(),
  primary key (snap_date, layer, lupa_id)
);
create index if not exists luvat_snapshot_lupa_idx on public.luvat_snapshot (lupa_id, snap_date);

create table if not exists public.tietyot_snapshot (
  snap_date  date        not null,
  tietyo_id  text        not null,
  alkaa      timestamptz,
  paattyy    timestamptz,
  otsikko    text,
  data       jsonb,
  haettu     timestamptz not null default now(),
  primary key (snap_date, tietyo_id)
);

-- Seurattavat alueet HFP-geohash-solun tarkkuudella (0,01° x 0,01°, n. 1,1 x 0,55 km).
-- Solu-muoto sama kuin HFP-topicissa, esim. '60;24/19/82'. Rooli: tyomaa tai vertailu.
create table if not exists public.seuranta_alueet (
  cell       text primary key,
  nimi       text,
  rooli      text not null default 'tyomaa' check (rooli in ('tyomaa','vertailu')),
  lupa_id    text,
  aktiivinen boolean not null default true,
  lisatty    timestamptz not null default now()
);

-- Pysäkkitapahtumat HFP:stä (DEP, ARS, PAS)
create table if not exists public.hfp_events (
  oper   integer     not null,
  veh    integer     not null,
  tst    timestamptz not null,
  event  text        not null,
  route  text,
  dir    smallint,
  oday   date,
  start  text,
  stop   integer,
  lat    double precision,
  lon    double precision,
  dl     integer,          -- poikkeama aikataulusta, s
  spd    real,
  primary key (oper, veh, tst, event)
);
create index if not exists hfp_events_route_idx on public.hfp_events (route, oday, dir);
create index if not exists hfp_events_stop_idx on public.hfp_events (stop, tst);

-- Ajojen lokitus: näkee nopeasti, toimiiko tallennin
create table if not exists public.tallennin_loki (
  id        bigserial primary key,
  funktio   text not null,
  alkoi     timestamptz not null default now(),
  rivit     integer,
  virhe     text
);

alter table public.luvat_snapshot   enable row level security;
alter table public.tietyot_snapshot enable row level security;
alter table public.seuranta_alueet  enable row level security;
alter table public.hfp_events       enable row level security;
alter table public.tallennin_loki   enable row level security;
-- Ei julkisia policyjä: vain service role (edge functionit) kirjoittaa ja lukee.
