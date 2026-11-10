// Työmaatutka – pysäkkien sijaintien keruu koko HSL-alueelta.
// Kuuntelee bussien ja ratikoiden lähtötapahtumia (DEP) ~90 s ja tallentaa jokaiselle
// pysäkille ajoneuvon ilmoittaman sijainnin lähtöhetkellä. Ajetaan 30 min välein,
// jolloin vuorokaudessa kertyy käytännössä kaikki liikennöidyt pysäkit.
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";
import mqtt from "npm:mqtt@5";

const BROKER = "wss://mqtt.hsl.fi:443/";
const LISTEN_MS = 90_000;

const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

async function collect() {
  const stops = new Map<number, { lat: number[]; lon: number[] }>();
  let msgs = 0;
  let lastError: string | null = null;
  const client = mqtt.connect(BROKER, { reconnectPeriod: 2000, connectTimeout: 10_000 });
  client.on("connect", () => client.subscribe(["/hfp/v2/journey/ongoing/dep/bus/#", "/hfp/v2/journey/ongoing/dep/tram/#"], { qos: 0 }));
  client.on("message", (_t: string, msg: Uint8Array) => {
    msgs++;
    try {
      const p = JSON.parse(new TextDecoder().decode(msg))?.DEP;
      if (!p || p.stop == null || p.lat == null || p.long == null) return;
      const s = Number(p.stop);
      const e = stops.get(s) ?? { lat: [], lon: [] };
      if (e.lat.length < 9) { e.lat.push(p.lat); e.lon.push(p.long); }
      stops.set(s, e);
    } catch { /* ohitetaan */ }
  });
  client.on("error", (e: Error) => { lastError = e.message; });
  await new Promise((r) => setTimeout(r, LISTEN_MS));
  client.end(true);

  const med = (a: number[]) => { const b = [...a].sort((x, y) => x - y); return b[Math.floor(b.length / 2)]; };
  const rows = [...stops.entries()].map(([stop, e]) => ({ stop, lat: med(e.lat), lon: med(e.lon), n: e.lat.length, paivitetty: new Date().toISOString() }));
  for (let i = 0; i < rows.length; i += 1000) {
    const { error } = await db.from("pysakit").upsert(rows.slice(i, i + 1000), { onConflict: "stop" });
    if (error) lastError = error.message;
  }
  await db.from("tallennin_loki").insert({ funktio: "pysakit-kerays", rivit: rows.length, virhe: lastError ?? `viestejä ${msgs}` });
}

Deno.serve(() => {
  // @ts-ignore EdgeRuntime on Supabasen ajoympäristön globaali
  EdgeRuntime.waitUntil(collect());
  return new Response(JSON.stringify({ ok: true }), { headers: { "content-type": "application/json" } });
});
