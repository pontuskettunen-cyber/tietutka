// Työmaatutka – pysäkkivälikooste koko HSL-alueelta (bussit ja ratikat), versio 3.
// Kuuntelee lähtö- (DEP), saapumis- (ARS) ja ohitustapahtumia (PAS) ~110 s.
// - Ajoneuvon viimeisin tila tallennetaan jaksojen väliin (hfp_tila), joten jakson rajalle osuvat välit eivät katoa.
// - Pysäkkiväli jaetaan ajoon (lähtö -> saapuminen seuraavalle pysäkille) ja seisontaan (saapuminen -> lähtö).
// - Aikataulupoikkeaman muutos lasketaan erikseen ajolle ja seisonnalle.
// - Kaikista väleistä tallennetaan 2 h koosteet; lupien pysäkkiväleiltä myös yksittäiset havainnot (mediaania varten).
// Havaintoon tallennetaan vuorotunniste (linja|suunta|päivä|lähtöaika), jotta saman vuoron viiveet voidaan
// summata koko reitiltä. Ajoneuvo- tai henkilötietoja ei tallenneta havaintoihin.
// Liikennevaloetuisuus (TLR = pyyntö, TLA = vastaus ACK/NAK) lasketaan välikohtaisesti, jotta valojen ja työmaan
// vaikutus voidaan erottaa: välin havaintoon tallennetaan pyyntöjen, myönnettyjen ja evättyjen määrä.
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";
import mqtt from "npm:mqtt@5";

const BROKER = "wss://mqtt.hsl.fi:443/";
const LISTEN_MS = 110_000;
const BUCKET_MS = 2 * 3600_000;

const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

type St = { t: number; stop: number; dl: number | null; trip: string; arr_stop: number | null; arr_t: number | null; arr_dl: number | null; seen: boolean;
  vp?: Set<string>; vok?: number; vei?: number };
type Agg = { bucket: string; from_stop: number; to_stop: number; route: string; dir: number; mode: string;
  n: number; sum_tt: number; sum_tt2: number; min_tt: number; max_tt: number; sum_ddl: number; n_ddl: number;
  sum_ddl_ajo: number; n_ajo: number; sum_seis: number; n_seis: number };

async function run() {
  // 1) edellisen jakson tila (alle 5 min vanha)
  const st = new Map<string, St>();
  // ruuhkassa liikkeellä on yli 1000 ajoneuvoa: haetaan sivuina (PostgREST palauttaa enintään 1000 riviä)
  const prev: any[] = [];
  const raja = new Date(Date.now() - 5 * 60_000).toISOString();
  for (let from = 0; from < 20000; from += 1000) {
    const { data } = await db.from("hfp_tila").select("*").gt("t", raja).order("veh").range(from, from + 999);
    prev.push(...(data ?? []));
    if (!data || data.length < 1000) break;
  }
  for (const r of prev) st.set(r.veh, { t: +new Date(r.t), stop: r.stop, dl: r.dl, trip: r.trip,
    arr_stop: r.arr_stop, arr_t: r.arr_t ? +new Date(r.arr_t) : null, arr_dl: r.arr_dl, seen: false });
  // 2) seurattavat parit
  const seur = new Set<string>();
  for (let from = 0; ; from += 1000) {
    const { data } = await db.from("seuratut_parit").select("from_stop,to_stop").range(from, from + 999);
    (data ?? []).forEach((r: any) => seur.add(`${r.from_stop}|${r.to_stop}`));
    if (!data || data.length < 1000) break;
  }

  const agg = new Map<string, Agg>();
  const obs: any[] = [];
  let msgs = 0, pairs = 0, stitched = 0;
  let lastError: string | null = null;
  const t0 = Date.now();

  const client = mqtt.connect(BROKER, { reconnectPeriod: 2000, connectTimeout: 10_000 });
  client.on("connect", () => client.subscribe(
    ["dep", "ars", "pas", "tlr", "tla"].flatMap((e) => [`/hfp/v2/journey/ongoing/${e}/bus/#`, `/hfp/v2/journey/ongoing/${e}/tram/#`]), { qos: 0 }));
  client.on("message", (topic: string, msg: Uint8Array) => {
    msgs++;
    try {
      const o = JSON.parse(new TextDecoder().decode(msg));
      const ev = Object.keys(o)[0], p = o[ev];
      if (ev === "TLR" || ev === "TLA") {
        // valotapahtuma kirjataan ajoneuvon käynnissä olevalle pysäkkivälille
        if (!p || p.oper == null || p.veh == null) return;
        const sv = st.get(`${p.oper}/${p.veh}`); if (!sv) return;
        // kentät ovat muotoa "tlp-requestid"; risteys tunnistetaan sid:stä (sama pyyntö lähetetään jopa 4 kertaa)
        const rid = String(p.sid ?? p["tlp-requestid"] ?? p.tst);
        (sv.vp ??= new Set()).add(rid);
        if (ev === "TLA") { const d = p["tlp-decision"]; if (d === "ACK") sv.vok = (sv.vok ?? 0) + 1; else if (d === "NAK") sv.vei = (sv.vei ?? 0) + 1; }
        return;
      }
      if (!p || p.stop == null || !p.tst || p.oper == null || p.veh == null || !p.route) return;
      const key = `${p.oper}/${p.veh}`, t = Date.parse(p.tst), stop = Number(p.stop);
      const dl = typeof p.dl === "number" ? p.dl : null;
      const trip = `${p.route}|${p.dir}|${p.oday}|${p.start}`;
      const s = st.get(key);
      if (ev === "ARS") {
        if (s && s.trip === trip) { s.arr_stop = stop; s.arr_t = t; s.arr_dl = dl; s.seen = true; }  // valolaskurit säilyvät välin loppuun
        else st.set(key, { t, stop, dl, trip, arr_stop: stop, arr_t: t, arr_dl: dl, seen: true }); // vuoron alku: ei edellistä lähtöä
        return;
      }
      if (ev !== "DEP" && ev !== "PAS") return;
      // DEP tai PAS sulkee pysäkkivälin edellisestä lähdöstä/ohituksesta
      if (s && s.trip === trip && s.stop !== stop && t > s.t) {
        const tt = (t - s.t) / 1000;
        if (tt >= 5 && tt <= 1200) {
          if (!s.seen) stitched++;
          const mode = topic.split("/")[6] ?? "bus";
          let ajo: number | null = null, seis: number | null = null, ddlAjo: number | null = null, ddlSeis: number | null = null;
          if (ev === "PAS") { ajo = tt; seis = 0; if (dl != null && s.dl != null) { ddlAjo = dl - s.dl; ddlSeis = 0; } }
          else if (s.arr_stop === stop && s.arr_t != null && s.arr_t >= s.t && s.arr_t <= t) {
            ajo = (s.arr_t - s.t) / 1000; seis = (t - s.arr_t) / 1000;
            if (s.arr_dl != null && s.dl != null) ddlAjo = s.arr_dl - s.dl;
            if (dl != null && s.arr_dl != null) ddlSeis = dl - s.arr_dl;
          }
          const ddl = dl != null && s.dl != null && Math.abs(dl - s.dl) < 900 ? dl - s.dl : null;
          const bucket = new Date(Math.floor(t / BUCKET_MS) * BUCKET_MS).toISOString();
          const k = `${bucket}|${s.stop}|${stop}|${p.route}|${p.dir}`;
          const a = agg.get(k) ?? { bucket, from_stop: s.stop, to_stop: stop, route: String(p.route), dir: Number(p.dir), mode,
            n: 0, sum_tt: 0, sum_tt2: 0, min_tt: tt, max_tt: tt, sum_ddl: 0, n_ddl: 0, sum_ddl_ajo: 0, n_ajo: 0, sum_seis: 0, n_seis: 0 };
          a.n++; a.sum_tt += tt; a.sum_tt2 += tt * tt; a.min_tt = Math.min(a.min_tt, tt); a.max_tt = Math.max(a.max_tt, tt);
          if (ddl != null) { a.sum_ddl += ddl; a.n_ddl++; }
          if (ddlAjo != null && Math.abs(ddlAjo) < 900) { a.sum_ddl_ajo += ddlAjo; a.n_ajo++; }
          if (seis != null && seis < 900) { a.sum_seis += seis; a.n_seis++; }
          agg.set(k, a);
          pairs++;
          if (seur.has(`${s.stop}|${stop}`)) obs.push({ t: new Date(t).toISOString(), from_stop: s.stop, to_stop: stop, route: String(p.route), dir: Number(p.dir),
            tt, ajo, seis, ddl, ddl_ajo: ddlAjo, ddl_seis: ddlSeis, vuoro: trip,
            valo_pyynto: s.vp ? s.vp.size : 0, valo_ok: s.vok ?? 0, valo_ei: s.vei ?? 0 });
        }
      }
      st.set(key, { t, stop, dl, trip, arr_stop: null, arr_t: null, arr_dl: null, seen: true });
    } catch { /* ohitetaan */ }
  });
  client.on("error", (e: Error) => { lastError = e.message; });
  await new Promise((r) => setTimeout(r, LISTEN_MS - (Date.now() - t0)));
  client.end(true);

  // 3) tallennus
  const rows = [...agg.values()];
  for (let i = 0; i < rows.length; i += 1000) {
    const { error } = await db.rpc("seg_add3", { rows: rows.slice(i, i + 1000) });
    if (error) lastError = error.message;
  }
  for (let i = 0; i < obs.length; i += 1000) {
    const { error } = await db.from("seg_havainto").insert(obs.slice(i, i + 1000));
    if (error) lastError = error.message;
  }
  const tila = [...st.entries()].filter(([, v]) => v.seen).map(([veh, v]) => ({ veh, t: new Date(v.t).toISOString(), stop: v.stop, dl: v.dl, trip: v.trip,
    arr_stop: v.arr_stop, arr_t: v.arr_t ? new Date(v.arr_t).toISOString() : null, arr_dl: v.arr_dl, paivitetty: new Date().toISOString() }));
  for (let i = 0; i < tila.length; i += 1000) {
    const { error } = await db.from("hfp_tila").upsert(tila.slice(i, i + 1000));
    if (error) lastError = error.message;
  }
  await db.from("tallennin_loki").insert({ funktio: "hfp-segmentit", rivit: rows.length,
    virhe: lastError ?? `viestejä ${msgs}, välejä ${pairs} (jaksojen yli ${stitched}), havaintoja ${obs.length}` });
}

Deno.serve(() => {
  // @ts-ignore EdgeRuntime on Supabasen ajoympäristön globaali
  EdgeRuntime.waitUntil(run());
  return new Response(JSON.stringify({ ok: true }), { headers: { "content-type": "application/json" } });
});
