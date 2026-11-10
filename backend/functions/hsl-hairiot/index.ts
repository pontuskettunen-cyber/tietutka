// Työmaatutka – HSL:n häiriötiedotteet (Digitransit, CC BY 4.0).
// Käytetään poikkeusreittimerkintöjen ("kiertää?") varmistamiseen: onko HSL itse tiedottanut linjalle poikkeuksen.
// Avain luetaan palvelimen salaisuudesta DIGITRANSIT_KEY, eikä se koskaan päädy sivustolle.
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";

const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
const URL_ = "https://api.digitransit.fi/routing/v2/hsl/gtfs/v1";
const Q = `{ alerts(feeds: ["HSL"]) {
  id alertHeaderText alertDescriptionText alertEffect alertCause alertSeverityLevel effectiveStartDate effectiveEndDate
  entities { __typename ... on Route { gtfsId shortName } ... on Stop { gtfsId } }
} }`;

Deno.serve(async () => {
  const key = Deno.env.get("DIGITRANSIT_KEY");
  if (!key) return new Response(JSON.stringify({ virhe: "DIGITRANSIT_KEY puuttuu" }), { status: 500 });
  const r = await fetch(URL_, { method: "POST", headers: { "content-type": "application/json", "digitransit-subscription-key": key }, body: JSON.stringify({ query: Q }) });
  if (!r.ok) return new Response(JSON.stringify({ virhe: "Digitransit " + r.status, teksti: (await r.text()).slice(0, 300) }), { status: 502 });
  const j = await r.json();
  if (j.errors) return new Response(JSON.stringify({ virhe: j.errors }), { status: 502 });
  const rows = (j.data?.alerts ?? []).map((a: any) => {
    const ent = a.entities ?? [];
    return {
      id: a.id,
      otsikko: a.alertHeaderText ?? null,
      kuvaus: a.alertDescriptionText ?? null,
      vaikutus: a.alertEffect ?? null,
      syy: a.alertCause ?? null,
      vakavuus: a.alertSeverityLevel ?? null,
      alkaa: a.effectiveStartDate ? new Date(a.effectiveStartDate * 1000).toISOString() : null,
      paattyy: a.effectiveEndDate ? new Date(a.effectiveEndDate * 1000).toISOString() : null,
      reitit: ent.filter((e: any) => e.__typename === "Route").map((e: any) => String(e.gtfsId).replace(/^HSL:/, "")),
      pysakit: ent.filter((e: any) => e.__typename === "Stop").map((e: any) => String(e.gtfsId).replace(/^HSL:/, "")),
      paivitetty: new Date().toISOString(),
    };
  });
  for (let i = 0; i < rows.length; i += 500) {
    const { error } = await db.from("hsl_hairiot").upsert(rows.slice(i, i + 500), { onConflict: "id" });
    if (error) return new Response(JSON.stringify({ virhe: error.message }), { status: 500 });
  }
  // tiedotteet, jotka eivät enää ole voimassa syötteessä: merkitään poistuneiksi (historia säilyy vertailua varten)
  const ids = rows.map((x: any) => x.id);
  await db.from("hsl_hairiot").update({ poistunut: new Date().toISOString() }).is("poistunut", null).not("id", "in", `(${ids.map((x: string) => `"${x}"`).join(",") || '""'})`);
  return new Response(JSON.stringify({ tiedotteita: rows.length, linjoja: new Set(rows.flatMap((x: any) => x.reitit)).size }), { headers: { "content-type": "application/json" } });
});
