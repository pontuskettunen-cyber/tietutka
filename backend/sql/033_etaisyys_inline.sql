-- 033: lupasegmenttien päivitys kaatoi kannan tai ylitti 2 min aikarajan (Vahti 4.11.).
-- Syy: etaisyys_m oli SQL-funktio, jossa alikysely (FROM) – sellaista ei voi avata kyselyn sisään,
-- joten jokainen kutsu (noin 1,5 miljoonaa per ajo) oli erillinen funktiokutsu.
-- Sama laskukaava ilman alikyselyä: Postgres avaa sen suoraan lausekkeeksi.
-- search_path-asetus poistetaan näistä puhtaista laskufunktioista (029), koska asetus estää avaamisen;
-- funktiot eivät viittaa tauluihin, joten asetuksella ei ole turvallisuusmerkitystä.
create or replace function etaisyys_m(plat float8, plon float8, alat float8, alon float8, blat float8, blon float8)
returns float8 language sql immutable parallel safe as $f$
  select sqrt(
    ((plon-alon)*55400.0 - (blon-alon)*55400.0 *
      (case when ((blon-alon)*55400.0)^2 + ((blat-alat)*110540.0)^2 = 0 then 0
            else greatest(0, least(1, ((plon-alon)*55400.0*(blon-alon)*55400.0 + (plat-alat)*110540.0*(blat-alat)*110540.0)
                                      / (((blon-alon)*55400.0)^2 + ((blat-alat)*110540.0)^2))) end))^2
  + ((plat-alat)*110540.0 - (blat-alat)*110540.0 *
      (case when ((blon-alon)*55400.0)^2 + ((blat-alat)*110540.0)^2 = 0 then 0
            else greatest(0, least(1, ((plon-alon)*55400.0*(blon-alon)*55400.0 + (plat-alat)*110540.0*(blat-alat)*110540.0)
                                      / (((blon-alon)*55400.0)^2 + ((blat-alat)*110540.0)^2))) end))^2)
$f$;
alter function etaisyys_m(float8, float8, float8, float8, float8, float8) reset search_path;
alter function etaisyys_janaan(float8, float8, float8, float8, float8, float8) reset search_path;
