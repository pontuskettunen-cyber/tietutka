"""Linjojen nimet (päätepysäkiltä päätepysäkille) hakua varten: data/ajantasaus.json -> data/linjanimet.json.
Ajetaan ajantasaus.py:n jälkeen. Nimi muodostetaan suunnan 1 ensimmäisestä ja viimeisestä ajantasauspysäkistä."""
import json, re
d = json.load(open("data/ajantasaus.json"))
L, P = d["linjat"], d["pysakit"]
def ln(r):
    r = str(r)
    return (r[1:].lstrip("0") or r) if re.match(r"^\d{4}", r) else r
out = {}
for k, e in sorted(L.items(), key=lambda kv: (kv[0].split("|")[1] != "1", -int(kv[1].get("vuoroja") or 0))):
    route, suunta = k.split("|")
    if " " in route: continue          # erikoisvariantit (esim. "1005 4")
    n = ln(route)
    if not re.match(r"^\d{1,3}[A-Z]?$", n) or n in out: continue
    ps = [p for p in e["pysakit"] if str(p[0]) in P]
    if len(ps) < 2: continue
    a, b = P[str(ps[0][0])][0], P[str(ps[-1][0])][0]
    if a == b: continue
    out[n] = a + " – " + b if suunta == "1" else b + " – " + a
json.dump({"lahde": "HSL GTFS (CC BY 4.0)", "nimet": out}, open("data/linjanimet.json", "w"), ensure_ascii=False, separators=(",", ":"))
print(len(out), "linjaa;", {k: out.get(k) for k in ("5T", "55", "4", "550", "6T", "9T", "15")})
