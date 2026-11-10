// Työmaatutka – HSL:n HFP-pysäkkitapahtumien tallennin.
// Ajastus: pg_cron joka minuutti. Jokainen ajo kuuntelee ~115 s, joten peräkkäiset
// ajot menevät päällekkäin eikä aukkoja synny. Tuplat karsitaan perusavaimella.
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";
import mqtt from "npm:mqtt@5";

const BROKER = "wss://mqtt.hsl.fi:443/";
const LISTEN_MS = 115_000;
const FLUSH_MS = 15_000;
const EVENTS = ["dep", "ars", "pas"]; // lähtö, saapuminen, ohitus

const db = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
);

type Row = Record<string, unknown>;

function toRow(payload: any): Row | null {
  const ev = Object.keys(payload ?? {})[0];
  const p = payload?.[ev];
  if (!p || p.oper == null || p.veh == null || !p.tst) return null;
  return {
    oper: p.oper, veh: p.veh, tst: p.tst, event: ev,
    route: p.route ?? null, dir: p.dir != null ? Number(p.dir) : null,
    oday: p.oday ?? null, start: p.start ?? null,
    stop: p.stop != null ? Number(p.stop) : null,
    lat: p.lat ?? null, lon: p.long ?? null,
    dl: p.dl ?? null, spd: p.spd ?? null,
  };
}

async function record(cells: string[]): Promise<{ rows: number; error: string | null }> {
  let buffer: Row[] = [];
  let total = 0;
  let lastError: string | null = null;

  const flush = async () => {
    if (!buffer.length) return;
    const batch = buffer; buffer = [];
    const { error } = await db.from("hfp_events")
      .upsert(batch, { onConflict: "oper,veh,tst,event", ignoreDuplicates: true });
    if (error) lastError = error.message; else total += batch.length;
  };

  const client = mqtt.connect(BROKER, { reconnectPeriod: 2000, connectTimeout: 10_000 });
  client.on("connect", () => {
    // .../<event>/<mode>/<oper>/<veh>/<route>/<dir>/<headsign>/<start>/<next_stop>/<geohash_level>/<geohash>/#
    const topics = cells.flatMap((c) => EVENTS.map((e) => `/hfp/v2/journey/ongoing/${e}/+/+/+/+/+/+/+/+/+/${c}/#`));
    client.subscribe(topics, { qos: 0 });
  });
  client.on("message", (_t: string, msg: Uint8Array) => {
    try {
      const row = toRow(JSON.parse(new TextDecoder().decode(msg)));
      if (row) buffer.push(row);
    } catch { /* rikkinäinen viesti ohitetaan */ }
  });
  client.on("error", (e: Error) => { lastError = e.message; });

  const timer = setInterval(flush, FLUSH_MS);
  await new Promise((r) => setTimeout(r, LISTEN_MS));
  clearInterval(timer);
  client.end(true);
  await flush();
  return { rows: total, error: lastError };
}

Deno.serve(async () => {
  const { data, error } = await db.from("seuranta_alueet").select("cell").eq("aktiivinen", true);
  const cells = (data ?? []).map((r: any) => r.cell);
  if (error || !cells.length) {
    return new Response(JSON.stringify({ ok: false, reason: error?.message ?? "ei seurattavia alueita" }), { status: 200 });
  }
  const job = record(cells).then((r) =>
    db.from("tallennin_loki").insert({ funktio: "hfp-recorder", rivit: r.rows, virhe: r.error })
  );
  // Vastataan heti, tallennus jatkuu taustalla
  // @ts-ignore EdgeRuntime on Supabasen ajoympäristön globaali
  EdgeRuntime.waitUntil(job);
  return new Response(JSON.stringify({ ok: true, cells }), { headers: { "Content-Type": "application/json" } });
});
