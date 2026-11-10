-- 023: Tekoälyn käyttöloki (LLMOps): jokainen kielimallikutsu tokenit, hinta, vasteaika ja virheet.
-- Sisältöä (kehotteita tai vastauksia) ei tallenneta, vain mittarit.
create table if not exists ai_kaytto (
  id bigint generated always as identity primary key,
  t timestamptz not null default now(),
  tila text not null,            -- mikä toiminto kutsui: luokittele, katsaus, viikko, aikataulu, lausunto, kysy …
  malli text not null,
  syote int, tuotos int,         -- input / output tokens
  cache_luku int, cache_kirj int,
  ms int,                        -- vasteaika
  ok boolean not null,
  katkesi boolean,               -- stop_reason = max_tokens (vastaus katkesi)
  virhe text
);
create index if not exists ai_kaytto_t on ai_kaytto (t desc);
alter table ai_kaytto enable row level security;

-- Listahinnat USD / miljoona tokenia (Anthropic, 10/2026). Päivitetään käsin hintojen muuttuessa.
create table if not exists ai_hinta (
  malli text primary key,
  syote_usd numeric not null, tuotos_usd numeric not null,
  pitka_kerroin numeric not null default 1,  -- Haiku 5.5: yli 100k tokenin kehote 5×
  voimassa date not null default current_date
);
alter table ai_hinta enable row level security;
insert into ai_hinta (malli, syote_usd, tuotos_usd, pitka_kerroin, voimassa) values
  ('claude-haiku-5-5', 0.10, 0.50, 5, '2026-10-07'),
  ('claude-sonnet-5-5', 2.00, 10.00, 1, '2026-09-28')
on conflict (malli) do update set syote_usd = excluded.syote_usd, tuotos_usd = excluded.tuotos_usd,
  pitka_kerroin = excluded.pitka_kerroin, voimassa = excluded.voimassa;

-- Kutsukohtainen hinta
create or replace view v_ai_kutsut with (security_invoker = false) as
select k.id, k.t, k.tila, k.malli, k.syote, k.tuotos, k.ms, k.ok, k.katkesi,
  round(((coalesce(k.syote,0) + coalesce(k.cache_kirj,0)*1.25 + coalesce(k.cache_luku,0)*0.1) * h.syote_usd
        + coalesce(k.tuotos,0) * h.tuotos_usd)
        * case when coalesce(k.syote,0) + coalesce(k.cache_luku,0) + coalesce(k.cache_kirj,0) > 100000 then h.pitka_kerroin else 1 end
        / 1e6, 5) as usd
from ai_kaytto k left join ai_hinta h using (malli)
order by k.t desc limit 200;

-- Päiväkooste toiminnoittain (Helsingin aikaa), 60 pv
create or replace view v_ai_paiva with (security_invoker = false) as
with k as (
  select (k.t at time zone 'Europe/Helsinki')::date pv, k.*,
    ((coalesce(k.syote,0) + coalesce(k.cache_kirj,0)*1.25 + coalesce(k.cache_luku,0)*0.1) * h.syote_usd
      + coalesce(k.tuotos,0) * h.tuotos_usd)
      * case when coalesce(k.syote,0) + coalesce(k.cache_luku,0) + coalesce(k.cache_kirj,0) > 100000 then h.pitka_kerroin else 1 end / 1e6 usd
  from ai_kaytto k left join ai_hinta h using (malli)
  where k.t > now() - interval '60 days')
select pv, tila, malli, count(*) kutsut, count(*) filter (where not ok) virheet,
  count(*) filter (where katkesi) katkenneet,
  sum(syote) syote, sum(tuotos) tuotos, round(sum(usd)::numeric, 4) usd,
  round(avg(ms) filter (where ok))::int ms_ka,
  round((percentile_cont(0.9) within group (order by ms) filter (where ok))::numeric)::int ms_p90
from k group by 1, 2, 3 order by 1 desc, 2;

grant select on v_ai_kutsut, v_ai_paiva to anon, authenticated;
