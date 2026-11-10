"""Työmaatutka – ajantasauspysäkit HSL:n GTFS-aineistosta.

Tuottaa data/ajantasaus.json:
  { "paivitetty": ..., "linjat": { "1004|1": { "pysakit": [[stop, tp], ...],      # yleisimmän ajoreitin pysäkit järjestyksessä, tp=1 ajantasauspysäkki
                                              "vuoroja": n, "arki_vrk": vuoroja arkipäivässä, "arki_h": [lähtöjä tunneittain 0–23],
                                              "ajat": { "aamu": [min, ...], "ilta": [...], "paiva": [...] } } } }
  ajat = aikataulun mukainen ajoaika (min, mediaani) peräkkäisten rajapisteiden (ajantasauspysäkit + päätepysäkki) välillä arkipäivän vuoroissa.
  pysakit-merkintä: 1 = ajantasauspysäkki, 2 = päätepysäkki ilman ajantasausta, 0 = muu.
Reittitunnus ja suunta luetaan trip_id:stä (muoto ROUTE_PVM_PÄIVÄTYYPPI_SUUNTA_LÄHTÖAIKA), samat kuin HFP:ssä.
"""
import os, csv, io, json, statistics, sys, urllib.request, zipfile, datetime, collections

URL = "https://infopalvelut.storage.hsldev.com/gtfs/hsl.zip"
path = sys.argv[1] if len(sys.argv) > 1 else "hsl.zip"
if len(sys.argv) <= 1:
    urllib.request.urlretrieve(URL, path)

def mins(t):
    h, m, s = (int(x) for x in t.split(":"))
    return h * 60 + m + s / 60

def jakso(start):
    h = int(start[:2])
    return "aamu" if 7 <= h < 9 else "paiva" if 9 <= h < 15 else "ilta" if 15 <= h < 18 else None

patterns = collections.Counter()          # (route, dir, pattern) -> trips
esim = {}                                 # (route, dir, pattern) -> esimerkkivuoro (muodon hakuun)
ajat = collections.defaultdict(list)      # (route, dir, pattern, jakso) -> [[min between tps], ...]
tunti = collections.Counter()             # (route, dir, tunti) -> lähdöt yhtenä tavallisena arkipäivänä
ajo_t = {}                                # trip -> (lähtö min, perillä min) vertailupäivän vuoroille (kääntöajat)

# Yksi tavallinen arkipäivä (tiistai, 1–2 viikon päästä): mitkä vuorot ajetaan sinä päivänä (calendar + calendar_dates)
def _rivit(z, nimi):
    with z.open(nimi) as f:
        rd = csv.reader(io.TextIOWrapper(f, encoding="utf-8-sig", newline=""))
        h = next(rd)
        for r in rd:
            yield dict(zip(h, r))
with zipfile.ZipFile(path) as z:
    nimet = set(z.namelist())
    paiva0 = datetime.date.today() + datetime.timedelta(days=7)
    while paiva0.weekday() != 1:
        paiva0 += datetime.timedelta(days=1)
    pv = paiva0.strftime("%Y%m%d"); viikonpaiva = ["monday","tuesday","wednesday","thursday","friday","saturday","sunday"][paiva0.weekday()]
    palvelut = set()
    if "calendar.txt" in nimet:
        for c in _rivit(z, "calendar.txt"):
            if c.get(viikonpaiva) == "1" and c["start_date"] <= pv <= c["end_date"]:
                palvelut.add(c["service_id"])
    if "calendar_dates.txt" in nimet:
        for c in _rivit(z, "calendar_dates.txt"):
            if c["date"] == pv:
                (palvelut.add if c["exception_type"] == "1" else palvelut.discard)(c["service_id"])
    aktiiviset = {t["trip_id"] for t in _rivit(z, "trips.txt") if t["service_id"] in palvelut}
print("vertailupäivä", pv, "vuoroja", len(aktiiviset), file=sys.stderr)

def flush(trip, rows):
    if not trip or not rows:
        return
    parts = trip.split("_")
    if len(parts) < 5:
        return
    route, dtype, d, start = parts[0], parts[2], parts[3], parts[4]
    rows.sort(key=lambda r: r[0])
    pat = tuple((r[1], r[2]) for r in rows)
    key = (route, d, pat)
    patterns[key] += 1
    esim.setdefault(key, trip)
    if trip in aktiiviset:
        tunti[(route, d, int(start[:2]) % 24)] += 1
        ajo_t[trip] = (rows[0][3], rows[-1][3])
    j = jakso(start)
    if j and dtype not in ("La", "Su"):       # arkipäivät
        # rajapisteet: ajantasauspysäkit + päätepysäkki (HSL:n ratikoilla ajantasaus on vain lähtöpäässä)
        tp = [r[3] for i, r in enumerate(rows) if r[2] == 1 or i == len(rows) - 1]
        if len(tp) >= 2:
            ajat[key + (j,)].append([round(tp[i + 1] - tp[i], 2) for i in range(len(tp) - 1)])

with zipfile.ZipFile(path) as z, z.open("stop_times.txt") as f:
    rd = csv.reader(io.TextIOWrapper(f, encoding="utf-8-sig", newline=""))
    hdr = next(rd)
    I = {k: hdr.index(k) for k in ("trip_id", "departure_time", "stop_id", "stop_sequence", "timepoint")}
    cur, rows = None, []
    for r in rd:
        t = r[I["trip_id"]]
        if t != cur:
            flush(cur, rows)
            cur, rows = t, []
        try:
            stop = int(r[I["stop_id"]])
        except ValueError:
            continue
        rows.append((int(r[I["stop_sequence"]]), stop, 1 if r[I["timepoint"]] == "1" else 0, mins(r[I["departure_time"]])))
    flush(cur, rows)

best = {}
for (route, d, pat), n in patterns.items():
    k = f"{route}|{d}"
    if k not in best or n > best[k][1]:
        best[k] = (pat, n)

# Viivevara (puskuri): HSL:n trips2.txt kertoo jokaiselle vuorolle max_delay (0–5 min) ja ratikoille autokierron (block_id).
# Tarkistettu 2.11.2026: ratikoilla max_delay ≈ kääntöaika − 3–4 min (81 % vuoropareista), eli kuinka paljon vuoro voi
# myöhästyä ennen kuin seuraava lähtö myöhästyy. Lasketaan päiväajan (7–18) vuoroista vertailupäivänä.
puskuri = collections.defaultdict(list)    # (route, dir) -> [max_delay]
kierrot = collections.defaultdict(list)    # (route_id_gtfs, block) -> [(lähtö, perillä, route, dir)]
if "trips2.txt" in nimet:
    with zipfile.ZipFile(path) as z:
        for t in _rivit(z, "trips2.txt"):
            tid = t["trip_id"]
            if tid not in aktiiviset: continue
            parts = tid.split("_")
            if len(parts) < 5: continue
            route, d, h = parts[0], parts[3], int(parts[4][:2])
            if 7 <= h < 18 and t.get("max_delay", "") != "":
                puskuri[(route, d)].append(int(t["max_delay"]))
            if t.get("block_id") and tid in ajo_t:
                kierrot[(t["route_id"], t["block_id"])].append((*ajo_t[tid], route, d))
kaanto = collections.defaultdict(list)     # (route, dir) -> kääntöaika (min) tämän suunnan vuoron jälkeen, päiväaika
for L in kierrot.values():
    L.sort()
    for a, c in zip(L, L[1:]):
        k = c[0] - a[1]
        if 0 <= k < 20 and 7 * 60 <= a[0] < 18 * 60:
            kaanto[(a[2], a[3])].append(k)

out = {}
for k, (pat, n) in best.items():
    route, d = k.split("|")
    # merkintä: 1 = ajantasauspysäkki, 2 = päätepysäkki (ei ajantasausta), 0 = muu
    e = {"pysakit": [[p[0], p[1] or (2 if i == len(pat) - 1 else 0)] for i, p in enumerate(pat)], "vuoroja": n, "ajat": {}}
    # arkipäivän vuoromäärä ja lähdöt tunneittain: poikkeusreitin tunnistukseen (odotetut vs. havaitut ohitukset)
    th = [tunti[(route, d, h)] for h in range(24)]
    if sum(th):
        e["arki_vrk"] = sum(th)
        e["arki_h"] = th
    P = sorted(puskuri.get((route, d), []))
    if P:
        e["puskuri"] = {"md": statistics.median(P), "md10": P[len(P) // 10], "tiukka": round(sum(1 for x in P if x <= 1) / len(P), 2), "n": len(P)}
        K = sorted(kaanto.get((route, d), []))
        if len(K) >= 5:
            e["puskuri"]["kaanto"] = round(statistics.median(K), 1)
    for j in ("aamu", "paiva", "ilta"):
        L = [x for x in ajat.get((route, d, pat, j), []) if x]
        if L:
            e["ajat"][j] = [round(statistics.median(x[i] for x in L), 1) for i in range(len(L[0]))]
    out[k] = e

# reittiviivat GTFS:n shapes.txt:stä (ajankohtaisempi kuin ArcGIS-linjasto), yksi tiedosto per linjasuunta
def dp(pts, tol):
    """Douglas–Peucker-yksinkertaistus, tol metreinä."""
    if len(pts) < 3:
        return pts
    kx, ky = 55600, 111320
    stack, keep = [(0, len(pts) - 1)], {0, len(pts) - 1}
    while stack:
        a, b = stack.pop()
        ax, ay, bx, by = pts[a][1] * kx, pts[a][0] * ky, pts[b][1] * kx, pts[b][0] * ky
        dx, dy = bx - ax, by - ay
        L2 = dx * dx + dy * dy or 1e-9
        best, bi = 0, None
        for i in range(a + 1, b):
            px, py = pts[i][1] * kx - ax, pts[i][0] * ky - ay
            t = max(0, min(1, (px * dx + py * dy) / L2))
            d = ((px - t * dx) ** 2 + (py - t * dy) ** 2) ** 0.5
            if d > best:
                best, bi = d, i
        if bi is not None and best > tol:
            keep.add(bi)
            stack += [(a, bi), (bi, b)]
    return [pts[i] for i in sorted(keep)]

trip_for = {k: esim[(k.split("|")[0], k.split("|")[1], v[0])] for k, v in best.items()}
want = set(trip_for.values())
shape_of = {}
with zipfile.ZipFile(path) as z, z.open("trips.txt") as f:
    for r in csv.DictReader(io.TextIOWrapper(f, encoding="utf-8-sig", newline="")):
        if r["trip_id"] in want:
            shape_of[r["trip_id"]] = r["shape_id"]
need = set(shape_of.values())
shp = collections.defaultdict(list)
with zipfile.ZipFile(path) as z, z.open("shapes.txt") as f:
    for r in csv.DictReader(io.TextIOWrapper(f, encoding="utf-8-sig", newline="")):
        if r["shape_id"] in need:
            shp[r["shape_id"]].append((int(r["shape_pt_sequence"]), float(r["shape_pt_lat"]), float(r["shape_pt_lon"])))
os.makedirs("data/reitit", exist_ok=True)
nr = 0
for k, trip in trip_for.items():
    sid = shape_of.get(trip)
    if not sid or sid not in shp:
        continue
    pts = [[round(a, 5), round(b, 5)] for _, a, b in sorted(shp[sid])]
    json.dump(dp(pts, 4), open(f"data/reitit/{k.replace('|', '_').replace(' ', '-')}.json", "w"), separators=(",", ":"))
    nr += 1
print(f"reittiviivoja {nr}")

# ajantasauspysäkkien nimet ja sijainnit (kartta ja agentin tekstit)
tps = {p[0] for e in out.values() for p in e["pysakit"] if p[1] >= 1}
pys = {}
with zipfile.ZipFile(path) as z, z.open("stops.txt") as f:
    for r in csv.DictReader(io.TextIOWrapper(f, encoding="utf-8-sig", newline="")):
        try:
            sid = int(r["stop_id"])
        except ValueError:
            continue
        if sid in tps:
            pys[sid] = [r["stop_name"], round(float(r["stop_lat"]), 5), round(float(r["stop_lon"]), 5), r.get("stop_code") or ""]

os.makedirs("data", exist_ok=True)
json.dump({"paivitetty": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%MZ"), "lahde": "HSL GTFS (CC BY 4.0)", "linjat": out, "pysakit": pys},
          open("data/ajantasaus.json", "w"), ensure_ascii=False, separators=(",", ":"))
print("puskuri esim.", {k: out[k].get("puskuri") for k in ("1007|1", "1007|2", "1001|1", "1055|1", "1500|1") if k in out})
print(f"linjasuuntia {len(out)}, ajantasauspysäkkejä {len(pys)}, suunnat {collections.Counter(k.split('|')[1] for k in out)}")
print(json.dumps({k: out[k] for k in list(out)[:1]}, ensure_ascii=False)[:1500])
