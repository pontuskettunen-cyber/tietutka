// Työmaatutka – pysäkkivälien viivat katuja pitkin.
// Lähde: HSL:n avoin linjasto (ArcGIS, CC BY 4.0), taso 2 "HSL linjat": NUMERO = HFP:n reittitunnus, SUUNTA = suunta.
// Jokaiselle työmaiden pysäkkivälille haetaan sen linjojen reittiviiva ja leikataan pysäkkien väliltä.
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";

const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

// PostgREST palauttaa enintään 1000 riviä: haetaan sivuina
async function sivuittain(mk: () => any) {
  const out: any[] = [];
  for (let off = 0; off < 50000; off += 1000) {
    const { data, error } = await mk().range(off, off + 999);
    if (error) throw error;
    out.push(...(data ?? []));
    if (!data || data.length < 1000) break;
  }
  return out;
}
const URL_ = "https://services1.arcgis.com/sswNXkUiRoWtrx0t/ArcGIS/rest/services/HSL_linjasto_ja_pysakit/FeatureServer/2/query";
const MAX_POIKKEAMA = 70; // m: pysäkin etäisyys reittiviivasta

type P = [number, number]; // [lon, lat]
const KX = 55600, KY = 111320; // m/aste Helsingin leveysasteella
const d2 = (a: P, b: P) => Math.hypot((a[0] - b[0]) * KX, (a[1] - b[1]) * KY);

// pisteen projektio murtoviivalle: palauttaa {i, t, dist, pos} (pos = kuljettu matka metreinä)
function proj(line: P[], cum: number[], p: P) {
  let best = { i: 0, t: 0, dist: Infinity, pos: 0 };
  for (let i = 0; i < line.length - 1; i++) {
    const a = line[i], b = line[i + 1];
    const ax = (b[0] - a[0]) * KX, ay = (b[1] - a[1]) * KY, px = (p[0] - a[0]) * KX, py = (p[1] - a[1]) * KY;
    const L2 = ax * ax + ay * ay;
    const t = L2 ? Math.max(0, Math.min(1, (px * ax + py * ay) / L2)) : 0;
    const dist = Math.hypot(px - t * ax, py - t * ay);
    if (dist < best.dist) best = { i, t, dist, pos: cum[i] + t * Math.sqrt(L2) };
  }
  return best;
}
const lerp = (a: P, b: P, t: number): P => [a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t];

async function haeReitit(routes: string[]) {
  const out = new Map<string, P[]>(); // "route|suunta" -> viiva
  for (let i = 0; i < routes.length; i += 40) {
    const where = `NUMERO in (${routes.slice(i, i + 40).map((r) => `'${r.replace(/'/g, "")}'`).join(",")})`;
    const q = new URLSearchParams({ where, outFields: "NUMERO,SUUNTA", outSR: "4326", returnGeometry: "true", f: "json" });
    const r = await fetch(URL_, { method: "POST", body: q, headers: { "content-type": "application/x-www-form-urlencoded" } });
    if (!r.ok) throw new Error(`ArcGIS ${r.status}`);
    const d = await r.json();
    for (const f of d.features ?? []) {
      const pts: P[] = [];
      for (const path of f.geometry?.paths ?? []) for (const q of path) {
        const p: P = [q[0], q[1]];
        if (!pts.length || d2(pts[pts.length - 1], p) > 0.5) pts.push(p);
      }
      if (pts.length > 1) out.set(`${f.attributes.NUMERO}|${f.attributes.SUUNTA}`, pts);
    }
  }
  return out;
}

async function run(kaikki: boolean) {
  const segs = await sivuittain(() => db.from("v_lupa_segmentit").select("from_stop,to_stop,from_lat,from_lon,to_lat,to_lon,linjat,viiva").order("lupa_id").order("from_stop").order("to_stop"));
  const uniq = new Map<string, any>();
  for (const s of segs ?? []) {
    if (!kaikki && s.viiva) continue;
    const k = `${s.from_stop}|${s.to_stop}`;
    const e = uniq.get(k) ?? { ...s, linjat: new Set<string>() };
    (s.linjat ?? []).forEach((r: string) => e.linjat.add(r));
    uniq.set(k, e);
  }
  const routes = [...new Set([...uniq.values()].flatMap((s) => [...s.linjat]))];
  const reitit = await haeReitit(routes);
  const cums = new Map<string, number[]>();
  for (const [k, line] of reitit) { const c = [0]; for (let i = 1; i < line.length; i++) c.push(c[i - 1] + d2(line[i - 1], line[i])); cums.set(k, c); }

  const rows: any[] = [];
  let ohi = 0;
  for (const s of uniq.values()) {
    const A: P = [s.from_lon, s.from_lat], B: P = [s.to_lon, s.to_lat];
    let best: any = null;
    for (const r of s.linjat) for (const dir of ["1", "2"]) {
      const k = `${r}|${dir}`, line = reitit.get(k), cum = cums.get(k);
      if (!line || !cum) continue;
      const pa = proj(line, cum, A), pb = proj(line, cum, B);
      if (pa.dist > MAX_POIKKEAMA || pb.dist > MAX_POIKKEAMA || pb.pos <= pa.pos) continue;
      // reitin pituus välillä ei saa olla järjetön suhteessa linnuntiehen (silmukat, väärä haara)
      const pit = pb.pos - pa.pos, suora = d2(A, B);
      if (pit > Math.max(3 * suora, suora + 600)) continue;
      const score = pa.dist + pb.dist;
      if (!best || score < best.score) best = { score, route: r, line, pa, pb };
    }
    if (!best) { ohi++; continue; }
    const { line, pa, pb } = best;
    const pts: P[] = [lerp(line[pa.i], line[pa.i + 1], pa.t)];
    for (let i = pa.i + 1; i <= pb.i; i++) pts.push(line[i]);
    pts.push(lerp(line[pb.i], line[pb.i + 1], pb.t));
    // tallennetaan [lat, lon], 5 desimaalia (~1 m)
    const coords = pts.map((p) => [Math.round(p[1] * 1e5) / 1e5, Math.round(p[0] * 1e5) / 1e5]);
    rows.push({ from_stop: s.from_stop, to_stop: s.to_stop, route: best.route, coords, poikkeama_m: Math.round(best.score), paivitetty: new Date().toISOString() });
  }
  for (let i = 0; i < rows.length; i += 500) {
    const { error: e } = await db.from("vali_viiva").upsert(rows.slice(i, i + 500));
    if (e) throw e;
  }
  const tulos = { valeja: uniq.size, reitteja: reitit.size, viivoja: rows.length, ilman_viivaa: ohi };
  await db.from("tallennin_loki").insert({ funktio: "reittiviivat", rivit: rows.length, virhe: ohi ? `ilman viivaa ${ohi}` : null });
  return tulos;
}

Deno.serve(async (req) => {
  try {
    const kaikki = new URL(req.url).searchParams.get("kaikki") === "1";
    return new Response(JSON.stringify(await run(kaikki)), { headers: { "content-type": "application/json" } });
  } catch (e) {
    return new Response(JSON.stringify({ virhe: String(e) }), { status: 500, headers: { "content-type": "application/json" } });
  }
});
