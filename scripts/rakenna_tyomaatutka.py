"""Rakentaa Työmaatutkan (HSL-haun demo) Tietutkan koodista.

Käyttö: python scripts/rakenna_tyomaatutka.py ../tyomaatutka

Sama käyttöliittymä ja mittaus kuin Tietutkassa, mutta
- nimi, osoitteet ja hakukonetiedot ovat Työmaatutkan
- kaupallistamiseen liittyvät osat on poistettu: esittelypyyntö, urakoitsijan
  kustannuslaskuri (työn lisäkulu, alueenkäyttömaksu) ja lukittava haitta-arvio-PDF
"""
import pathlib, re, shutil, sys

SRC = pathlib.Path(__file__).resolve().parent.parent
DST = pathlib.Path(sys.argv[1]).resolve()
s = (SRC / "index.html").read_text(encoding="utf-8")

def R(a, b, n=1):
    global s
    c = s.count(a)
    assert c == n, f"{c} osumaa (odotettiin {n}): {a[:80]!r}"
    s = s.replace(a, b)

# --- Hakukone- ja jakotiedot ---------------------------------------------------
s = re.sub(r"<title>.*?</title>", "<title>Työmaatutka · katutöiden vaikutus joukkoliikenteeseen</title>", s, count=1)
s = re.sub(r'<meta name="description" content="[^"]*">',
           '<meta name="description" content="Työmaatutka mittaa, paljonko Helsingin katutyöt hidastavat busseja ja ratikoita, ja varoittaa etukäteen töistä, jotka osuvat joukkoliikenteen reiteille.">', s, count=1)
s = re.sub(r'<link rel="canonical" href="[^"]*">', '<link rel="canonical" href="https://pontuskettunen-cyber.github.io/tyomaatutka/">', s, count=1)
s = re.sub(r'<meta property="og:title" content="[^"]*">', '<meta property="og:title" content="Työmaatutka · katutöiden vaikutus joukkoliikenteeseen">', s, count=1)
s = re.sub(r'<meta property="og:url" content="[^"]*">', '<meta property="og:url" content="https://pontuskettunen-cyber.github.io/tyomaatutka/">', s, count=1)
R('<meta name="robots" content="noindex,nofollow">',
  '<meta name="robots" content="index,follow">\n<meta name="msvalidate.01" content="BF64DF159C58EAE6C980EEA07254E5FF" />')

# --- Logo: Tietutka-sanamerkki -> Työmaatutka-teksti ------------------------------
n_logo = len(re.findall(r'<svg class="tlogo"[\s\S]*?</svg>', s))
assert n_logo == 2, n_logo
s = re.sub(r'<svg class="tlogo"[\s\S]*?</svg>', '<span class="tmlogo">Työmaa<b>tutka</b></span>', s)

# --- Nimi teksteissä (pienellä kirjoitetut tunnisteet, kuten rpc/tietutka_*, eivät muutu) ---
s = s.replace("Tietutka", "Työmaatutka")

# --- Kaupallistamiseen liittyvät osat pois -----------------------------------------
R('<b>Arvioi työn liikennehaitta ennen kaivuilmoitusta.</b> Valitse alkava lupa tai piirrä työalue kartalle.<span id="ttEsittely"></span>',
  '<b>Arvioi alkavan työn vaikutus joukkoliikenteeseen etukäteen.</b> Valitse alkava lupa tai piirrä työalue kartalle.')
R('<b>Ajoitus ja kustannus</b>', '<b>Ajoitus</b>')
R('["ajo","Ajoitus ja kustannus"]', '["ajo","Ajoitus"]')
R(',["pdf","PDF: haitta-arvio liitteeksi"]', '')


# Muutosmerkintä Tietoa-sivulle: hakemuksen jälkeen tehdyt parannukset
lead_end = s.index("</p>", s.index("Työmaatutka on prototyyppi, ei valmis järjestelmä.")) + 4
s = s[:lead_end] + """
    <div class="paiv"><b>Päivitetty 14.11.2026.</b> Vaikutus mitataan nyt samalta kadulta ennen töitä ja työn aikana (todennettu tai alustava, vaihteluväleineen). Aiempi vertailu linjan muihin osuuksiin näkyy enää harmaana arviona, koska se antoi puolelle töistä negatiivisen luvun. Lisäksi: karttatyöpöytä siirrettävine paletteineen, yksi haku linjoille, kaduille ja luville, seisovat autot erotellaan livenäkymässä, sekä puhelin- ja saavutettavuuskorjaukset.</div>""" + s[lead_end:]

TM = r'''
<script>
/* ===== Työmaatutka (HSL-haun demo): ei urakoitsijan kustannuslaskentaa eikä esittelypyyntöä =====
   Ajoitusvaihtoehdot verrataan pelkän joukkoliikenteen haitan mukaan. */
(function(){
  const pr = (r, p) => Math.round((1 - r.yht / Math.max(1e-9, p.yht)) * 100);
  const pienin = K => { const p = K.pohja, m = K.rivit.reduce((a, r) => r.yht < a.yht ? r : a, p); return m !== p && pr(m, p) >= 15 ? m : null; };
  haSuositus = function(K){
    const p = K.pohja;
    if(K.puuttuu && K.puuttuu.length) return `<b>Ajoitussuositus tarkentuu</b>, kun liikennemäärät on mitattu kaikille vuorokaudenajoille. Nyt osa jaksoista puuttuu, joten vaihtoehtojen vertailu olisi harhaanjohtava.`;
    if(K.rivit.every(r => !(r.yht > 1e-6))) return `<b>Työ ei arvion mukaan hidasta joukkoliikennettä</b>, joten ajoituksella ei ole joukkoliikenteen kannalta merkitystä.`;
    if(!(p.yht > 1e-6)) return `<b>Päivätyö klo 7–16 on joukkoliikenteelle haitaton</b>; ilta- ja yötyö hidastaisi liikennettä.`;
    const m = pienin(K);
    if(m) return `<b>Pienin haitta: ${esc(m.t.toLowerCase())}</b>, kokonaishaitta ${haH(m.yht)} h vs. ${haH(p.yht)} h päivätyönä (−${nf(pr(m, p))} %).`;
    return `<b>Ajoitus ei juuri muuta kokonaishaittaa</b> (ero alle 15 %).`;
  };
  haTaulukko = function(K, pitka){
    const p = K.pohja, m = pienin(K);
    return `<table class="t hat"><thead><tr><th>Vaihtoehto</th><th class="r">Kesto</th><th class="r">Lisäaika / vrk</th><th class="r">Haitta yht.</th><th class="r">Ero</th></tr></thead><tbody>
    ${K.rivit.map(r => `<tr class="${r === (m || p) ? "best" : ""}"><td>${esc(pitka ? r.t : r.lyh)}${r === p ? ' <span class="note">suunniteltu</span>' : ""}${r === m ? ' <span class="hatag">pienin haitta</span>' : ""}</td>
      <td class="r">${nf(r.pv)} pv</td><td class="r">${nf(r.vrk, 1)} h</td><td class="r"><b>${haH(r.yht)} h</b></td><td class="r">${r === p ? "–" : `<b>${pr(r, p) > 0 ? "−" : "+"}${nf(Math.abs(pr(r, p)))} %</b>`}</td></tr>`).join("")}</tbody></table>`;
  };
  esittely = function(){};
  tpAjoSub = function(){ const s = document.getElementById("enAjoSub"); if(s){ s.textContent = ""; s.onclick = null; } };
})();
</script>
<style>
/* Työmaatutka-sanamerkki ja piilotetut kaupalliset osat */
.tmlogo{font:800 25px/1 "Nunito",system-ui,sans-serif;letter-spacing:-.01em;color:#fff;white-space:nowrap}
.tmlogo b{font-weight:800;color:#8CC8FF}
.tt-brand .tmlogo{color:var(--i);font-size:28px}.tt-brand .tmlogo b{color:#1F5FBF}
#haAvaa,#enOlet,.ha-esit,#haEsit{display:none!important}
.paiv{background:#EEF6FF;border-left:3px solid #1F5FBF;padding:9px 12px;margin:4px 0 18px;font-size:14px;line-height:1.5;max-width:820px;border-radius:0 6px 6px 0}
</style>
'''
R("</body>", TM + "</body>")

# Tietosuoja: esittelypyyntöjä ei kerätä tässä versiossa
s = re.sub(r"\s*Yhteydenottopyynnöt[^<]*?12 kk[^<]*?\.", "", s)

(DST / "index.html").write_text(s, encoding="utf-8")
for f in ["esitys.js", "data/linjanimet.json", "scripts/linjanimet.py", "scripts/ajantasaus.py"]:
    shutil.copy2(SRC / f, DST / f)
print("Työmaatutka rakennettu:", DST / "index.html", len(s), "merkkiä")
