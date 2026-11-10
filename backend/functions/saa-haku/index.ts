// Työmaatutka – säähavainnot Ilmatieteen laitoksen avoimesta datasta (CC BY 4.0), Helsinki Kaisaniemi (fmisid 100971).
// Miksi: sää vääristää ennen–jälkeen-vertailua (lumipäivänä kaikki on hitaampaa), ja sää aiheuttaa itse katutöitä
// (pakkasen vesijohtovuodot, rankkasateen tulvat). Havainnot tallennetaan 10 min välein samaan tahtiin kuin bussien mittaukset.
// Kutsu: POST /functions/v1/saa-haku  (oletus: viimeiset 3 h)  tai  ?paivat=30  (takautuva haku, enintään 7 vrk kerrallaan).
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";

const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
const FMISID = 100971; // Helsinki Kaisaniemi
const PARAM = "t2m,ri_10min,r_1h,snow_aws,ws_10min,wawa";
const MAP: Record<string, string> = { t2m: "t2m", ri_10min: "ri", r_1h: "r1h", snow_aws: "lumi", ws_10min: "tuuli", wawa: "wawa" };

async function hae(alku: Date, loppu: Date) {
  const u = `https://opendata.fmi.fi/wfs?service=WFS&version=2.0.0&request=getFeature&storedquery_id=fmi::observations::weather::simple` +
    `&fmisid=${FMISID}&parameters=${PARAM}&timestep=10&starttime=${alku.toISOString().slice(0, 19)}Z&endtime=${loppu.toISOString().slice(0, 19)}Z`;
  const r = await fetch(u);
  if (!r.ok) throw new Error(`FMI ${r.status}`);
  const xml = await r.text();
  const rows = new Map<string, any>();
  const re = /<BsWfs:Time>([^<]+)<\/BsWfs:Time>\s*<BsWfs:ParameterName>([^<]+)<\/BsWfs:ParameterName>\s*<BsWfs:ParameterValue>([^<]+)<\/BsWfs:ParameterValue>/g;
  for (const m of xml.matchAll(re)) {
    const v = Number(m[3]);
    if (!Number.isFinite(v)) continue;
    const t = m[1], k = MAP[m[2]];
    if (!k) continue;
    const row = rows.get(t) ?? { t, asema: FMISID };
    row[k] = k === "lumi" && v < 0 ? 0 : v; // -1 = ei lunta
    rows.set(t, row);
  }
  return [...rows.values()];
}

// Ilmatieteen laitoksen varoitukset (CAP-syöte): tallennetaan ne, jotka koskevat Helsinkiä
// (liikennesää, jalankulkusää eli liukkaus, sade, tulva, tuuli). Syöte sisältää vain voimassa olevat, joten historia kertyy tästä alkaen.
const HKI: [number, number] = [60.1699, 24.9384];
function sisalla(poly: [number, number][], p: [number, number]) {
  let c = false;
  for (let i = 0, j = poly.length - 1; i < poly.length; j = i++) {
    const [ai, bi] = poly[i], [aj, bj] = poly[j];
    if ((bi > p[1]) !== (bj > p[1]) && p[0] < (aj - ai) * (p[1] - bi) / (bj - bi) + ai) c = !c;
  }
  return c;
}
const tag = (x: string, t: string) => (x.match(new RegExp(`<${t}>([\\s\\S]*?)</${t}>`)) ?? [])[1]?.trim() ?? null;
async function varoitukset() {
  const r = await fetch("https://alerts.fmi.fi/cap/feed/atom_fi-FI.xml");
  if (!r.ok) throw new Error(`FMI varoitukset ${r.status}`);
  const xml = await r.text();
  const rows: any[] = [];
  for (const e of xml.split("<entry>").slice(1)) {
    const id = tag(e, "id"); if (!id) continue;
    const info = (e.match(/<info>([\s\S]*?)<\/info>/g) ?? []).find((x) => /<language>fi/.test(x)) ?? (e.match(/<info>([\s\S]*?)<\/info>/) ?? [])[0];
    if (!info) continue;
    const alueet = [...info.matchAll(/<areaDesc>([^<]*)<\/areaDesc>/g)].map((m) => m[1]);
    const polyt = [...info.matchAll(/<polygon>([^<]*)<\/polygon>/g)].map((m) => m[1].trim().split(/\s+/).map((pq) => pq.split(",").map(Number) as [number, number]));
    const koskee = alueet.some((a) => /Helsin/i.test(a)) || polyt.some((pl) => pl.length > 2 && sisalla(pl, HKI));
    if (!koskee || /merelle/i.test(tag(info, "event") ?? "")) continue;
    rows.push({ id, tapahtuma: tag(info, "event"), otsikko: tag(info, "headline") ?? tag(e, "title"), vakavuus: tag(info, "severity"),
      alkaa: tag(info, "onset") ?? tag(info, "effective"), paattyy: tag(info, "expires"), alueet: alueet.slice(0, 12).join(", "), paivitetty: new Date().toISOString() });
  }
  if (rows.length) { const { error } = await db.from("saa_varoitus").upsert(rows); if (error) throw error; }
  return rows.length;
}

Deno.serve(async (req) => {
  const paivat = Math.min(60, Number(new URL(req.url).searchParams.get("paivat") ?? 0));
  const loppu = new Date();
  const jaksot: [Date, Date][] = [];
  if (paivat > 0) {
    for (let a = new Date(+loppu - paivat * 864e5); a < loppu; a = new Date(+a + 7 * 864e5)) jaksot.push([a, new Date(Math.min(+a + 7 * 864e5, +loppu))]);
  } else jaksot.push([new Date(+loppu - 3 * 3600e3), loppu]);
  let n = 0;
  try {
    for (const [a, b] of jaksot) {
      const rows = await hae(a, b);
      for (let i = 0; i < rows.length; i += 500) {
        const { error } = await db.from("saa_havainto").upsert(rows.slice(i, i + 500));
        if (error) throw error;
      }
      n += rows.length;
    }
    let vn = 0; try { vn = await varoitukset(); } catch (e) { await db.from("tallennin_loki").insert({ funktio: "saa-haku/varoitukset", rivit: 0, virhe: String(e).slice(0, 300) }); }
    return new Response(JSON.stringify({ havaintoja: n, jaksoja: jaksot.length, varoituksia_helsinki: vn }), { headers: { "content-type": "application/json" } });
  } catch (e) {
    await db.from("tallennin_loki").insert({ funktio: "saa-haku", rivit: n, virhe: String(e).slice(0, 300) });
    return new Response(JSON.stringify({ virhe: String(e) }), { status: 500 });
  }
});
