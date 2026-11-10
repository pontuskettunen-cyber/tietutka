// Työmaatutka – päivittäinen tilannekuva Helsingin luvista ja Digitrafficin tietöistä.
// Ajastus: pg_cron kerran päivässä. Luvanhaltijan tietoja ei tallenneta.
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";

const WFS = "https://kartta.hel.fi/ws/geoserver/avoindata/wfs";
const LAYERS = ["Tilapainen_liikennejarjestely_alue", "Kaivuilmoitus_alue"];
const DIGITRAFFIC =
  "https://tie.digitraffic.fi/api/traffic-message/v1/messages?inactiveHours=0&includeAreaGeometry=false&situationType=ROAD_WORK";
// Pääkaupunkiseutu + kehyskunnat, karkea rajaus (lon/lat)
const BBOX = { minLon: 24.4, maxLon: 25.4, minLat: 60.1, maxLat: 60.45 };

const db = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
);

function today(): string {
  return new Date().toLocaleDateString("sv-SE", { timeZone: "Europe/Helsinki" });
}

function pick(p: Record<string, unknown>, keys: string[]): string | null {
  for (const k of keys) if (p[k] != null && p[k] !== "") return String(p[k]);
  return null;
}

function toTs(v: string | null): string | null {
  if (!v) return null;
  const d = new Date(v);
  return isNaN(d.getTime()) ? null : d.toISOString();
}

async function snapLayer(layer: string, snap: string): Promise<number> {
  const url = `${WFS}?service=WFS&version=2.0.0&request=GetFeature&typeNames=avoindata:${layer}` +
    `&outputFormat=application/json&srsName=EPSG:4326`;
  const res = await fetch(url);
  if (!res.ok) throw new Error(`${layer}: HTTP ${res.status}`);
  const fc = await res.json();
  const rows = (fc.features ?? []).map((f: any) => {
    const p = f.properties ?? {};
    return {
      snap_date: snap,
      layer,
      lupa_id: pick(p, ["hakemustunnus", "tunnus", "id"]) ?? String(f.id),
      hakemuksen_laji: pick(p, ["hakemuksen_laji", "tyyppi"]),
      alkaa: toTs(pick(p, ["liikennejarjestely_alkaa", "tyo_alkaa", "alkaa", "voimassaolo_alkaa"])),
      paattyy: toTs(pick(p, ["liikennejarjestely_paattyy", "tyo_paattyy", "paattyy", "voimassaolo_paattyy"])),
      tarkoitus: pick(p, ["tyon_tarkoitus", "tarkoitus"]),
      osoite: pick(p, ["osoite"]),
      kaupunginosa: pick(p, ["kaupunginosa"]),
      status: pick(p, ["status"]),
      geom: f.geometry ?? null,
      // hakija ja tyon_suorittaja jätetään tarkoituksella pois
    };
  });
  for (let i = 0; i < rows.length; i += 500) {
    const { error } = await db.from("luvat_snapshot").upsert(rows.slice(i, i + 500));
    if (error) throw new Error(`${layer}: ${error.message}`);
  }
  return rows.length;
}

function inBbox(geom: any): boolean {
  const flat: number[][] = [];
  const walk = (c: any) => {
    if (typeof c?.[0] === "number") flat.push(c);
    else if (Array.isArray(c)) c.forEach(walk);
  };
  walk(geom?.coordinates);
  return flat.some(([lon, lat]) =>
    lon >= BBOX.minLon && lon <= BBOX.maxLon && lat >= BBOX.minLat && lat <= BBOX.maxLat
  );
}

async function snapTietyot(snap: string): Promise<number> {
  const res = await fetch(DIGITRAFFIC, {
    headers: { "Digitraffic-User": "Tyomaatutka/0.1", "Accept-Encoding": "gzip" },
  });
  if (!res.ok) throw new Error(`Digitraffic: HTTP ${res.status}`);
  const fc = await res.json();
  const rows = (fc.features ?? [])
    .filter((f: any) => !f.geometry || inBbox(f.geometry))
    .map((f: any) => {
      const p = f.properties ?? {};
      const a = p.announcements?.[0] ?? {};
      return {
        snap_date: snap,
        tietyo_id: String(p.situationId ?? f.id),
        alkaa: toTs(a.timeAndDuration?.startTime ?? null),
        paattyy: toTs(a.timeAndDuration?.endTime ?? null),
        otsikko: a.title ?? null,
        data: { properties: p, geometry: f.geometry ?? null },
      };
    });
  if (rows.length) {
    const { error } = await db.from("tietyot_snapshot").upsert(rows);
    if (error) throw new Error(`Digitraffic: ${error.message}`);
  }
  return rows.length;
}

Deno.serve(async () => {
  const snap = today();
  const result: Record<string, number | string> = {};
  const errors: string[] = [];
  for (const layer of LAYERS) {
    try { result[layer] = await snapLayer(layer, snap); }
    catch (e) { errors.push(String(e)); }
  }
  try { result.tietyot = await snapTietyot(snap); }
  catch (e) { errors.push(String(e)); }

  const total = Object.values(result).reduce((s: number, v) => s + (typeof v === "number" ? v : 0), 0);
  await db.from("tallennin_loki").insert({
    funktio: "snapshot-luvat", rivit: total, virhe: errors.length ? errors.join(" | ") : null,
  });
  return new Response(JSON.stringify({ snap, result, errors }), {
    headers: { "Content-Type": "application/json" },
  });
});
