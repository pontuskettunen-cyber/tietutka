// Työmaatutka – pysäkkien nimet HSL:n avoimesta pysäkkirekisteristä (ArcGIS, CC BY 4.0).
// SOLMUTUNNU = sama pysäkkitunnus kuin HFP:n "stop"-kentässä. Ajetaan kerran kuussa.
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";

const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
const URL_ = "https://services1.arcgis.com/sswNXkUiRoWtrx0t/ArcGIS/rest/services/HSL_linjasto_ja_pysakit/FeatureServer/3/query";

async function run() {
  const rows: any[] = [];
  let virhe: string | null = null;
  for (let offset = 0; offset < 20000; offset += 2000) {
    const q = new URLSearchParams({ where: "1=1", outFields: "SOLMUTUNNU,LYHYTTUNNU,NIMI1", returnGeometry: "false",
      resultOffset: String(offset), resultRecordCount: "2000", f: "json" });
    const r = await fetch(`${URL_}?${q}`);
    if (!r.ok) { virhe = `ArcGIS ${r.status}`; break; }
    const d = await r.json();
    const f = d.features ?? [];
    for (const x of f) {
      const a = x.attributes ?? {};
      const stop = parseInt(a.SOLMUTUNNU, 10);
      if (stop && a.NIMI1) rows.push({ stop, nimi: String(a.NIMI1).trim(), lyhyt: a.LYHYTTUNNU ? String(a.LYHYTTUNNU).trim() : null });
    }
    if (f.length < 2000 && !d.exceededTransferLimit) break;
  }
  const uniq = [...new Map(rows.map((r) => [r.stop, r])).values()];
  for (let i = 0; i < uniq.length; i += 1000) {
    const { error } = await db.from("pysakki_nimet").upsert(uniq.slice(i, i + 1000));
    if (error) virhe = error.message;
  }
  await db.from("tallennin_loki").insert({ funktio: "pysakit-nimet", rivit: uniq.length, virhe });
  return { nimia: uniq.length, virhe };
}

Deno.serve(async () => new Response(JSON.stringify(await run()), { headers: { "content-type": "application/json" } }));
