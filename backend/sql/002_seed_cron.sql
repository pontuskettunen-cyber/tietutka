-- Työmaatutka: seurattavat alueet ja ajastukset
-- Valittu 1.11.2026 Helsingin lupadatasta: työt, jotka alkavat 5.–12.11.,
-- jolloin ehditään kerätä muutaman päivän vertailudata ennen töitä.

insert into public.seuranta_alueet (cell, nimi, rooli) values
  ('60;24/19/82', 'Mannerheimintie 54 / Kivelänkatu – kuitukaapeli, alkaa 5.11.', 'tyomaa'),
  ('60;24/19/92', 'Nordenskiöldinkatu 20 / Auroranportti – kaivutyö, alkaa 9.11.', 'tyomaa'),
  ('60;24/19/64', 'Merimiehenkatu 11 – kaasulinjan tulppaus, alkaa 10.11.', 'tyomaa'),
  ('60;24/19/63', 'Lönnrotinkatu 18 – kaasun tulppaus, alkaa 12.11.', 'tyomaa'),
  ('60;24/19/65', 'Senaatintori ympäristö – Tuomaan markkinat, alkaa 9.11.', 'tyomaa'),
  ('60;24/19/91', 'Mannerheimintie / Ruskeasuo – vertailualue', 'vertailu')
on conflict (cell) do nothing;

create extension if not exists pg_cron;
create extension if not exists pg_net;

-- Korvaa <PROJECT_REF> ja <ANON_KEY> projektin arvoilla ennen ajoa (tai tallenna Vaultiin).
select cron.schedule(
  'hfp-recorder-minuutti',
  '* * * * *',
  $$ select net.http_post(
       url := 'https://<PROJECT_REF>.supabase.co/functions/v1/hfp-recorder',
       headers := jsonb_build_object('Content-Type','application/json','Authorization','Bearer <ANON_KEY>'),
       body := '{}'::jsonb,
       timeout_milliseconds := 5000) $$
);

select cron.schedule(
  'snapshot-luvat-paiva',
  '15 3 * * *',   -- 05:15 Suomen aikaa (UTC+2)
  $$ select net.http_post(
       url := 'https://<PROJECT_REF>.supabase.co/functions/v1/snapshot-luvat',
       headers := jsonb_build_object('Content-Type','application/json','Authorization','Bearer <ANON_KEY>'),
       body := '{}'::jsonb,
       timeout_milliseconds := 60000) $$
);
