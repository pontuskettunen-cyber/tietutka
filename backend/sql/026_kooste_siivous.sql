-- 026: Pysäkkivälikoosteen (segment_2h) säilytysaika. Kooste kasvaa noin 38 Mt / vrk (koko HSL-alue, 2 h jaksot).
-- 60 vrk riittää kaikille analyyseille (pisin ikkuna 22 vrk) ja pitää kannan Pro-tason 8 Gt:n sisällä (noin 2,6 Gt).
do $$ begin
  perform cron.unschedule('kooste-siivous') where exists (select 1 from cron.job where jobname = 'kooste-siivous');
  perform cron.schedule('kooste-siivous', '50 2 * * *', $c$delete from segment_2h where bucket < now() - interval '60 days'$c$);
end $$;
