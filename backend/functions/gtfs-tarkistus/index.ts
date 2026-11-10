// Työmaatutka – kertaluonteinen tarkistus: onko HSL:n GTFS:n stop_times.txt:ssä ajantasauspysäkkitieto (timepoint).
// Lukee zip-tiedostosta vain hakemiston ja stop_times.txt:n alun HTTP Range -pyynnöillä (koko tiedostoa ei ladata).
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
const URL_ = "https://infopalvelut.storage.hsldev.com/gtfs/hsl.zip";

async function range(a: number, b: number) {
  const r = await fetch(URL_, { headers: { Range: `bytes=${a}-${b}` } });
  return new Uint8Array(await r.arrayBuffer());
}
async function inflatePart(buf: Uint8Array, maxOut = 2_000_000) {
  const ds = new DecompressionStream("deflate-raw");
  const w = ds.writable.getWriter(); w.write(buf).catch(() => {}); w.close().catch(() => {});
  const r = ds.readable.getReader(); const parts: Uint8Array[] = []; let n = 0;
  try { while (n < maxOut) { const { value, done } = await r.read(); if (done) break; parts.push(value); n += value.length; } } catch { /* katkaistu syöte */ }
  const out = new Uint8Array(n); let o = 0; for (const p of parts) { out.set(p.subarray(0, Math.min(p.length, n - o)), o); o += p.length; if (o >= n) break; }
  return new TextDecoder().decode(out);
}

Deno.serve(async () => {
  try {
    const head = await fetch(URL_, { method: "HEAD" });
    const size = Number(head.headers.get("content-length"));
    const tail = await range(size - 65536, size - 1);
    const dv = new DataView(tail.buffer);
    let e = -1; for (let i = tail.length - 22; i >= 0; i--) if (dv.getUint32(i, true) === 0x06054b50) { e = i; break; }
    const cdSize = dv.getUint32(e + 12, true), cdOff = dv.getUint32(e + 16, true);
    const cd = await range(cdOff, cdOff + cdSize - 1); const cv = new DataView(cd.buffer);
    const files: any[] = []; let p = 0;
    while (p < cd.length && cv.getUint32(p, true) === 0x02014b50) {
      const comp = cv.getUint32(p + 20, true), unc = cv.getUint32(p + 24, true), nl = cv.getUint16(p + 28, true), xl = cv.getUint16(p + 30, true), cl = cv.getUint16(p + 32, true), lo = cv.getUint32(p + 42, true);
      files.push({ name: new TextDecoder().decode(cd.subarray(p + 46, p + 46 + nl)), comp, unc, lo });
      p += 46 + nl + xl + cl;
    }
    const st = files.find((f) => f.name === "stop_times.txt");
    const lh = await range(st.lo, st.lo + 29); const lv = new DataView(lh.buffer);
    const start = st.lo + 30 + lv.getUint16(26, true) + lv.getUint16(28, true);
    const txt = await inflatePart(await range(start, start + 400_000));
    const lines = txt.split("\n"); const hdr = lines[0].trim().split(",");
    const ti = hdr.indexOf("timepoint");
    const cnt: Record<string, number> = {};
    const rows = lines.slice(1, -1);
    if (ti >= 0) rows.forEach((l) => { const v = l.split(",")[ti] ?? ""; cnt[v] = (cnt[v] ?? 0) + 1; });
    return new Response(JSON.stringify({ zip_mb: Math.round(size / 1e6), tiedostot: files.map((f) => `${f.name} ${Math.round(f.unc / 1e6)} MB`), otsikko: hdr, rivejä_näyte: rows.length, timepoint_arvot: cnt, esimerkki: rows.slice(0, 40) }, null, 1), { headers: { "content-type": "application/json" } });
  } catch (err) { return new Response(JSON.stringify({ virhe: String(err) }), { status: 500 }); }
});
