"""Koe 4: max_delay vs. kääntöaika vuoro kerrallaan (ratikat, joilla block_id)."""
import csv, io, urllib.request, zipfile, collections, datetime
urllib.request.urlretrieve("https://infopalvelut.storage.hsldev.com/gtfs/hsl.zip", "/tmp/hsl.zip")
z = zipfile.ZipFile("/tmp/hsl.zip")
def rows(n):
    with z.open(n) as f: yield from csv.DictReader(io.TextIOWrapper(f, "utf-8-sig"))
routes = {r["route_id"]: (r["route_short_name"], r["route_type"]) for r in rows("routes.txt")}
cal = {c["service_id"]: c for c in rows("calendar.txt")}
d = datetime.date.today() + datetime.timedelta(days=7)
while d.weekday() != 1: d += datetime.timedelta(days=1)
ds = d.strftime("%Y%m%d")
act = {s for s,c in cal.items() if c["start_date"] <= ds <= c["end_date"] and c["tuesday"] == "1"}
for c in rows("calendar_dates.txt"):
    if c["date"] == ds: (act.add if c["exception_type"] == "1" else act.discard)(c["service_id"])
tsel = {t["trip_id"]: t for t in rows("trips2.txt") if t["service_id"] in act}
tyypit = collections.Counter(); blk = collections.Counter()
for t in tsel.values():
    ty = routes[t["route_id"]][1]; tyypit[ty] += 1
    if t["block_id"]: blk[ty] += 1
print("VUOROT tyypeittäin", dict(tyypit), "block_id:llä", dict(blk))
tram = {k:v for k,v in tsel.items() if v["block_id"]}
first, last = {}, {}
for st in rows("stop_times.txt"):
    tid = st["trip_id"]
    if tid not in tram: continue
    sq = int(st["stop_sequence"])
    if tid not in first or sq < first[tid][0]: first[tid] = (sq, st["departure_time"])
    if tid not in last or sq > last[tid][0]: last[tid] = (sq, st["arrival_time"])
sec = lambda h: sum(int(x)*m for x,m in zip(h.split(":"), (3600,60,1)))
blocks = collections.defaultdict(list)
for tid, t in tram.items():
    if tid in first: blocks[(t["route_id"], t["block_id"])].append((sec(first[tid][1]), sec(last[tid][1]), int(t["max_delay"] or -1), routes[t["route_id"]][0]))
tab = collections.defaultdict(collections.Counter); ero = collections.Counter(); viim = collections.Counter(); n=0
for L in blocks.values():
    L.sort()
    for a, c in zip(L, L[1:]):
        k = round((c[0]-a[1])/60)
        if 0 <= k < 60:
            tab[a[2]][k] += 1; n += 1
            ero[min(k,8) - a[2]] += 1
    viim[L[-1][2]] += 1
print("PARIT", n)
for md in sorted(tab): print(f"MD {md}: kääntöajat {sorted(tab[md].items())[:14]}")
print("KÄÄNTÖ(max8) - MD jakauma", sorted(ero.items()))
print("PÄIVÄN VIIMEISEN VUORON MD", sorted(viim.items()))
