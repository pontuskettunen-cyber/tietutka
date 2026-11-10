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
// Kaluston seisonnat (045) kerätään erikseen tauluun kalusto_seisonta: kääntöaika päätepysäkillä, pitkä seisonta pysäkillä
// (≥ 5 min) ja pitkä katko pysäkkien välillä (> 20 min). Ne eivät päädy mittaukseen. Pitkät jaksot hyväksytään vain, jos
// keruu on ollut katkeamatta käynnissä koko jakson ajan (muuten katko voisi johtua keruun tauosta eikä autosta).
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";
import mqtt from "npm:mqtt@5";

const BROKER = "wss://mqtt.hsl.fi:443/";
const LISTEN_MS = 110_000;
const BUCKET_MS = 2 * 3600_000;

const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

type St = { t: number; stop: number; dl: number | null; trip: string; arr_stop: number | null; arr_t: number | null; arr_dl: number | null; seen: boolean;
  vp?: Set<string>; vv?: Set<string>; vok?: number; vei?: number;
  vanha?: boolean;                                        // ladattu edellisestä jaksosta, viimeisin tapahtuma yli 5 min sitten
  k_alku?: number | null; k_trip?: string | null; k_dl?: number | null };  // käynnissä oleva kääntö (edellinen lähtö päättyi)
type Agg = { bucket: string; from_stop: number; to_stop: number; route: string; dir: number; mode: string;
  n: number; sum_tt: number; sum_tt2: number; min_tt: number; max_tt: number; sum_ddl: number; n_ddl: number;
  sum_ddl_ajo: number; n_ajo: number; sum_seis: number; n_seis: number };

async function run() {
  // 1) edellisen jakson tila. Mittaukseen käytetään vain alle 5 min vanhaa tilaa; enintään 4 h vanhaa käytetään seisontojen tunnistukseen.
  const st = new Map<string, St>();
  // ruuhkassa liikkeellä on yli 1000 ajoneuvoa: haetaan sivuina (PostgREST palauttaa enintään 1000 riviä)
  const prev: any[] = [];
  const tuore = Date.now() - 5 * 60_000;
  const raja = new Date(Date.now() - 4 * 3600_000).toISOString();
  // keruun kattavuus 4 h ajalta: jakso on luotettava vain, jos ajojen välissä ei ole yli 5 min aukkoa
  const ajot: number[] = [];
  {
    const { data } = await db.from("tallennin_loki").select("alkoi").eq("funktio", "hfp-segmentit").gt("rivit", 0).gt("alkoi", raja).order("alkoi").limit(500);
    (data ?? []).forEach((r: any) => ajot.push(+new Date(r.alkoi)));
    ajot.push(Date.now() + LISTEN_MS);
  }
  const katettu = (a: number, b: number) => {
    let ed = a;
    for (const x of ajot) { if (x < a) continue; if (x - ed > 300_000) return false; ed = x; if (x >= b) return true; }
    return false;
  };
  for (let from = 0; from < 20000; from += 1000) {
    const { data } = await db.from("hfp_tila").select("*").gt("t", raja).order("veh").range(from, from + 999);
    prev.push(...(data ?? []));
    if (!data || data.length < 1000) break;
  }
  for (const r of prev) st.set(r.veh, { t: +new Date(r.t), stop: r.stop, dl: r.dl, trip: r.trip,
    arr_stop: r.arr_stop, arr_t: r.arr_t ? +new Date(r.arr_t) : null, arr_dl: r.arr_dl, seen: false,
    vanha: +new Date(r.t) < tuore && !(r.arr_t && +new Date(r.arr_t) >= tuore && katettu(+new Date(r.t), +new Date(r.arr_t))),
    k_alku: r.k_alku ? +new Date(r.k_alku) : null, k_trip: r.k_trip ?? null, k_dl: r.k_dl ?? null });
  const seisonnat: any[] = [];
  const seisoi = (r: any) => { if (r.kesto_s > 0) seisonnat.push(r); };
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
        if (ev === "TLA") {   // sama vastaus voi tulla useaan kertaan: lasketaan kukin pyyntö kerran
          const d = p["tlp-decision"]; sv.vv ??= new Set();
          if ((d === "ACK" || d === "NAK") && !sv.vv.has(rid)) { sv.vv.add(rid); if (d === "ACK") sv.vok = (sv.vok ?? 0) + 1; else sv.vei = (sv.vei ?? 0) + 1; }
        }
        return;
      }
      if (!p || p.stop == null || !p.tst || p.oper == null || p.veh == null || !p.route) return;
      const key = `${p.oper}/${p.veh}`, t = Date.parse(p.tst), stop = Number(p.stop);
      const dl = typeof p.dl === "number" ? p.dl : null;
      const trip = `${p.route}|${p.dir}|${p.oday}|${p.start}`;
      const s = st.get(key);
      // myöhässä perille tullut vanha viesti ei saa palauttaa tilaa taaksepäin (syntyisi vääriä pysäkkivälejä)
      if (s && t < Math.max(s.t, s.arr_t ?? 0)) return;
      if (ev === "ARS") {
        if (s && s.trip === trip) { s.arr_stop = stop; s.arr_t = t; s.arr_dl = dl; s.seen = true; }  // valolaskurit säilyvät välin loppuun
        else {
          // uusi lähtö alkaa: edellisen lähdön viimeisestä tapahtumasta alkaa kääntö, joka päättyy uuden lähdön lähtöön (DEP)
          const k = s ? { k_alku: s.arr_t ?? s.t, k_trip: s.trip, k_dl: s.arr_dl ?? s.dl } : {};
          st.set(key, { t, stop, dl, trip, arr_stop: stop, arr_t: t, arr_dl: dl, seen: true, ...k });
        }
        return;
      }
      if (ev !== "DEP" && ev !== "PAS") return;
      const mode0 = topic.split("/")[6] ?? "bus";
      // --- kaluston seisonnat (eivät vaikuta mittaukseen) ---
      if (s) {
        // kääntö: edellinen lähtö päättyi ja uusi alkaa nyt
        const kAlku = s.trip !== trip ? (s.arr_t ?? s.t) : (s.k_alku ?? null);
        const kTrip = s.trip !== trip ? s.trip : (s.k_trip ?? null);
        const kDl = s.trip !== trip ? (s.arr_dl ?? s.dl) : (s.k_dl ?? null);
        if (kAlku != null && kTrip && t > kAlku) {
          const kesto = (t - kAlku) / 1000;
          if (kesto >= 30 && kesto <= 3 * 3600 && katettu(kAlku, t))
            seisoi({ veh: key, tyyppi: "kaanto", route: String(p.route), dir: Number(p.dir), mode: mode0, stop,
              alku: new Date(kAlku).toISOString(), loppu: new Date(t).toISOString(), kesto_s: Math.round(kesto),
              dl_alku: kDl, dl_loppu: dl, vuoro: trip, vuoro_ed: kTrip });
        }
        if (s.trip === trip) {
          // pitkä seisonta pysäkillä saman lähdön aikana
          // (ei lähdön ensimmäisellä pysäkillä: siellä odotus on osa kääntöä)
          if (ev === "DEP" && s.k_alku == null && s.arr_stop === stop && s.arr_t != null && t - s.arr_t >= 300_000 && t - s.arr_t <= 4 * 3600_000 && katettu(s.arr_t, t))
            seisoi({ veh: key, tyyppi: "pysakki", route: String(p.route), dir: Number(p.dir), mode: mode0, stop,
              alku: new Date(s.arr_t).toISOString(), loppu: new Date(t).toISOString(), kesto_s: Math.round((t - s.arr_t) / 1000),
              dl_alku: s.arr_dl, dl_loppu: dl, vuoro: trip, vuoro_ed: null });
          // pitkä katko pysäkkien välillä
          const viim = Math.max(s.t, s.arr_t ?? 0);
          if (s.stop !== stop && s.arr_stop !== stop && t - viim > 1_200_000 && t - viim <= 4 * 3600_000 && katettu(viim, t))
            seisoi({ veh: key, tyyppi: "valilla", route: String(p.route), dir: Number(p.dir), mode: mode0, stop: s.arr_stop ?? s.stop, stop2: stop,
              alku: new Date(viim).toISOString(), loppu: new Date(t).toISOString(), kesto_s: Math.round((t - viim) / 1000),
              dl_alku: s.arr_dl ?? s.dl, dl_loppu: dl, vuoro: trip, vuoro_ed: null });
        }
      }
      // DEP tai PAS sulkee pysäkkivälin edellisestä lähdöstä/ohituksesta (vain tuoreesta tilasta, kuten ennenkin)
      if (s && !s.vanha && s.trip === trip && s.stop !== stop && t > s.t) {
        const tt = (t - s.t) / 1000;
        if (tt >= 5 && tt <= 1200) {
          if (!s.seen) stitched++;
          const mode = mode0;
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
            tt, ajo, seis: seis != null && seis < 900 ? seis : null, ddl,
            ddl_ajo: ddlAjo != null && Math.abs(ddlAjo) < 900 ? ddlAjo : null,   // aikataulun uudelleensovitus voi hypäyttää dl:ää
            ddl_seis: ddlSeis != null && Math.abs(ddlSeis) < 900 ? ddlSeis : null, vuoro: trip,
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
  for (let i = 0; i < seisonnat.length; i += 1000) {
    const { error } = await db.from("kalusto_seisonta").upsert(seisonnat.slice(i, i + 1000), { onConflict: "veh,alku,tyyppi", ignoreDuplicates: true });
    if (error) lastError = error.message;
  }
  const tila = [...st.entries()].filter(([, v]) => v.seen).map(([veh, v]) => ({ veh, t: new Date(v.t).toISOString(), stop: v.stop, dl: v.dl, trip: v.trip,
    arr_stop: v.arr_stop, arr_t: v.arr_t ? new Date(v.arr_t).toISOString() : null, arr_dl: v.arr_dl,
    k_alku: v.k_alku ? new Date(v.k_alku).toISOString() : null, k_trip: v.k_trip ?? null, k_dl: v.k_dl ?? null,
    paivitetty: new Date().toISOString() }));
  for (let i = 0; i < tila.length; i += 1000) {
    const { error } = await db.from("hfp_tila").upsert(tila.slice(i, i + 1000));
    if (error) lastError = error.message;
  }
  await db.from("tallennin_loki").insert({ funktio: "hfp-segmentit", rivit: rows.length,
    virhe: lastError ?? `viestejä ${msgs}, välejä ${pairs} (jaksojen yli ${stitched}), havaintoja ${obs.length}, seisontoja ${seisonnat.length}` });
}

Deno.serve(() => {
  // @ts-ignore EdgeRuntime on Supabasen ajoympäristön globaali
  EdgeRuntime.waitUntil(run());
  return new Response(JSON.stringify({ ok: true }), { headers: { "content-type": "application/json" } });
});
