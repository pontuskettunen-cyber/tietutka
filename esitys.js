/* Työmaatutka – esitysajo videota varten. Käynnistyy vain osoitteella ?demo (ei näy muille).
   Kierros käyttää sivun oikeita toimintoja: jokainen klikkaus avaa jotain. Hyväksy- ja kuittausnappeja ei paineta.
   Käyttö: avaa ?demo, käynnistä näytöntallennus, paina välilyöntiä (tai nappia). Esc keskeyttää. */
(() => {
  "use strict";
  const $ = (s, r = document) => r.querySelector(s);
  const $$ = (s, r = document) => [...r.querySelectorAll(s)];
  const TAHTI = 0.85;   // pitkät tauot hieman lyhyemmiksi; liikkeet ja klikkaukset ennallaan
  const odota = ms => new Promise(r => setTimeout(r, ms >= 900 ? ms * TAHTI : ms));
  let seis = false;
  const tarkista = () => { if (seis) throw new Error("keskeytetty"); };
  const ease = t => t < .5 ? 4 * t * t * t : 1 - Math.pow(-2 * t + 2, 3) / 2;

  /* ---------- tyylit ja peite-elementit ---------- */
  const css = document.createElement("style");
  css.textContent = `
  html.esitys, html.esitys *{cursor:none !important}
  html.esitys #ttModal, html.esitys #intro, html.esitys #ttHelp{display:none !important}
  .es-kursori{position:fixed;left:0;top:0;z-index:100000;pointer-events:none;width:30px;height:30px;transform:translate(-100px,-100px);
    filter:drop-shadow(0 2px 3px rgba(0,0,0,.35));transition:scale .12s}
  .es-kursori.painuu{scale:.82}
  .es-rengas{position:fixed;z-index:99999;pointer-events:none;width:16px;height:16px;margin:-8px 0 0 -8px;border-radius:50%;
    border:3px solid #0074BF;background:rgba(0,116,191,.25);animation:esRengas .7s ease-out forwards}
  @keyframes esRengas{to{transform:scale(4.2);opacity:0}}
  .es-teksti{position:fixed;left:50%;bottom:26px;z-index:99998;pointer-events:none;transform:translate(-50%,16px);opacity:0;
    display:flex;align-items:center;gap:14px;max-width:min(980px,calc(100vw - 60px));padding:14px 22px 14px 16px;background:#fff;
    border-radius:14px;box-shadow:0 10px 34px rgba(0,30,55,.22),0 0 0 1px rgba(0,0,0,.04);font:600 19px/1.35 Nunito,system-ui,sans-serif;color:#003456;
    transition:opacity .45s, transform .45s}
  .es-teksti.on{opacity:1;transform:translate(-50%,0)}
  .es-teksti.ylos{bottom:auto;top:84px}
  .es-teksti i{font-style:normal;flex:none;background:#0074BF;color:#fff;font:800 13px Nunito,system-ui;letter-spacing:.06em;padding:6px 11px;border-radius:999px}
  .es-kortti{position:fixed;inset:0;z-index:100001;display:flex;flex-direction:column;justify-content:center;padding:0 9vw;
    font-family:Nunito,system-ui,sans-serif;opacity:0;transition:opacity .7s;pointer-events:none}
  .es-kortti.on{opacity:1}
  .es-kortti.sin{background:#0074BF;color:#fff}.es-kortti.val{background:#fff;color:#003456}
  .es-kortti .lg{display:flex;align-items:center;gap:14px;font:800 34px Nunito}
  .es-kortti .lg span{width:44px;height:44px;border-radius:11px;display:grid;place-items:center}
  .es-kortti.sin .lg span{background:#fff}.es-kortti.val .lg span{background:#0074BF}
  .es-kortti .lg span b{width:26px;height:26px;border-radius:50%;border:4px solid;display:grid;place-items:center;box-sizing:border-box}
  .es-kortti.sin .lg b{border-color:#0074BF}.es-kortti.val .lg b{border-color:#fff}
  .es-kortti .lg b::after{content:"";width:8px;height:8px;border-radius:50%;background:currentColor}
  .es-kortti.sin .lg b{color:#0074BF}.es-kortti.val .lg b{color:#fff}
  .es-kortti h1{font:800 clamp(40px,5.6vw,84px)/1.08 Nunito;margin:34px 0 0;letter-spacing:-.01em}
  .es-kortti h1 em{font-style:normal;color:#0074BF}
  .es-kortti p{font:400 clamp(17px,1.7vw,26px)/1.4 Nunito;margin:26px 0 0;opacity:.9}
  .es-kortti small{font:400 15px Nunito;margin-top:36px;opacity:.75}
  .es-alku{position:fixed;inset:0;z-index:100002;display:grid;place-items:center;background:rgba(0,30,55,.55);backdrop-filter:blur(3px)}
  .es-alku button{font:800 22px Nunito;padding:18px 30px;border-radius:14px;border:0;background:#0074BF;color:#fff;cursor:pointer !important;box-shadow:0 10px 30px rgba(0,0,0,.3)}
  .es-alku p{color:#fff;font:400 16px Nunito;text-align:center;margin-top:14px}`;
  document.head.appendChild(css);

  const kursori = document.createElement("div");
  kursori.className = "es-kursori";
  kursori.innerHTML = `<svg viewBox="0 0 24 24" width="30" height="30"><path d="M3 2.5v17.2l4.6-4.3 3 6.9 3.2-1.4-3-6.8h6.3z" fill="#14181D" stroke="#fff" stroke-width="1.6" stroke-linejoin="round"/></svg>`;
  const teksti = document.createElement("div"); teksti.className = "es-teksti";
  document.body.append(kursori, teksti);

  /* ---------- liike ---------- */
  let kx = innerWidth * .55, ky = innerHeight * .55;
  const aseta = (x, y) => { kx = x; ky = y; kursori.style.transform = `translate(${x - 4}px,${y - 3}px)`; };
  aseta(kx, ky);
  const keski = el => { const b = el.getBoundingClientRect(); return { x: b.left + b.width / 2, y: b.top + b.height / 2 }; };
  function liiku(kohde, kesto) {
    tarkista();
    const p = kohde instanceof Element ? keski(kohde) : kohde;
    const x0 = kx, y0 = ky, dx = p.x - x0, dy = p.y - y0, d = Math.hypot(dx, dy);
    kesto = kesto || Math.min(1300, Math.max(520, d * 1.15));
    const kaari = Math.min(70, d * .12), nx = -dy / (d || 1), ny = dx / (d || 1);   // pieni kaari, ei suoraa viivaa
    return new Promise(res => { const t0 = performance.now();
      const askel = t => { const q = Math.min(1, (t - t0) / kesto), e = ease(q), b = Math.sin(Math.PI * e) * kaari;
        aseta(x0 + dx * e + nx * b, y0 + dy * e + ny * b);
        q < 1 ? requestAnimationFrame(askel) : res(); };
      requestAnimationFrame(askel); });
  }
  async function klikkaa(el, opts = {}) {
    tarkista();
    if (!el) throw new Error("kohdetta ei löytynyt");
    await liiku(opts.piste || el); await odota(opts.ennen ?? 260);
    kursori.classList.add("painuu");
    const r = document.createElement("div"); r.className = "es-rengas"; r.style.left = kx + "px"; r.style.top = ky + "px";
    document.body.appendChild(r); setTimeout(() => r.remove(), 800);
    await odota(120); kursori.classList.remove("painuu");
    if (opts.kartta) {   // Leafletin canvas: klikkaus kartan pintaan oikeissa koordinaateissa
      const t = document.elementFromPoint(kx, ky) || el;
      ["mousedown", "mouseup", "click"].forEach(tp => t.dispatchEvent(new MouseEvent(tp, { bubbles: true, cancelable: true, clientX: kx, clientY: ky, button: 0 })));
    } else if (typeof el.click === "function") el.click();
    else el.dispatchEvent(new MouseEvent("click", { bubbles: true, cancelable: true, clientX: kx, clientY: ky }));   // SVG-elementit
    await odota(opts.jalkeen ?? 700);
  }
  async function vieri(y, kesto = 1400, el = null) {
    tarkista();
    const kohde = el || document.scrollingElement, y0 = kohde.scrollTop, dy = Math.max(0, y) - y0;
    if (Math.abs(dy) < 4) return;
    return new Promise(res => { const t0 = performance.now();
      const askel = t => { const q = Math.min(1, (t - t0) / kesto); kohde.scrollTop = y0 + dy * ease(q); q < 1 ? requestAnimationFrame(askel) : res(); };
      requestAnimationFrame(askel); });
  }
  const sisaY = (kont, el, vara = 20) => kont.scrollTop + el.getBoundingClientRect().top - kont.getBoundingClientRect().top - vara;
  const sivunY = (el, vara = 96) => Math.max(0, el.getBoundingClientRect().top + scrollY - vara);
  async function odotaEl(fn, ms = 9000) { const t0 = Date.now(); for (;;) { tarkista(); const v = fn(); if (v) return v; if (Date.now() - t0 > ms) return null; await odota(120); } }
  const tekstinMukaan = (sel, re) => $$(sel).find(e => re.test(e.textContent.trim()) && e.getBoundingClientRect().height > 0);

  /* ---------- kuvatekstit ja kortit ---------- */
  async function kerro(tag, t, ylos = false) {
    if (teksti.classList.contains("on")) { teksti.classList.remove("on"); await odota(380); }
    teksti.classList.toggle("ylos", ylos);
    teksti.innerHTML = `<i>${tag}</i><span>${t}</span>`; teksti.classList.add("on");
  }
  const piilotaTeksti = () => teksti.classList.remove("on");
  async function kortti(luokka, html, kesto) {
    const k = document.createElement("div"); k.className = "es-kortti " + luokka; k.innerHTML = html; document.body.appendChild(k);
    await odota(30); k.classList.add("on"); await odota(kesto); k.classList.remove("on"); await odota(750); k.remove();
  }
  const logo = `<div class="lg"><span><b></b></span>Työmaatutka</div>`;
  const nf = n => Number(n).toLocaleString("fi-FI");

  /* ---------- kierros ---------- */
  async function kierros() {
    document.documentElement.classList.add("esitys");
    await odotaEl(() => typeof S !== "undefined" && S.loaded, 30000);
    // lähtötila: Yleiskuva, erittely kiinni, ylälaita
    S.bdOpen = false; if (location.hash !== "#/") location.hash = "#/"; await odota(600); renderBrief(); scrollTo(0, 0);

    // 0. aloituskortti peittää lähtötilan
    const alkuK = kortti("sin", `${logo}<h1>Mitä katutyöt maksavat<br>joukkoliikenteelle?</h1><p>Konsepti HSL:lle · avoin data · mitattu joka päivä</p>`, 3300);
    await alkuK;

    // 1. MITTAA
    await kerro("MITTAA", "Työmaatutka mittaa joka päivä, paljonko katutyöt hidastavat busseja ja ratikoita.");
    const otsikko = $("#v-home .nowrow") || $("#v-home h2");
    await liiku(otsikko); await odota(1300);
    const kpi = $("#kpis [data-bd]"); await liiku(kpi.querySelector("b") || kpi); await odota(1500);
    // 2. TYÖMAA: valitaan kärkikortti, jonka lupa koskee pysäkkiä (muuten kolmas)
    const kortit = $$("#v-home button.card").filter(b => b.getBoundingClientRect().width > 0);
    const r = (typeof ranked === "function" ? ranked() : []).slice(0, kortit.length);
    let ki = r.findIndex(x => (x.l.ai_sulkee || []).includes("pysakki")); if (ki < 1) ki = Math.min(2, kortit.length - 1);
    await kerro("TYÖMAA", "Klikkaa työmaata: lisäaika ohitusta kohden ja koko vuorokaudelta.");
    await klikkaa(kortit[ki], { jalkeen: 1400 });
    const det = $("#detail");
    await vieri(sivunY($("#v-home .map") || det, 84), 1500); await odota(500);
    const fakta = $("#detail .facts > div"); if (fakta) { await liiku(fakta); await odota(1700); }
    // kartan hidas pysäkkiväli: etsitään punainen kohta kartan canvasilta valitun työmaan läheltä
    const kartta = $("#map");
    const piste = punainenPiste(kartta);
    if (piste) { await kerro("KARTTA", "Punainen väli on hidas pysäkkiväli. Klikkaus kertoo linjat ja lisäviiveen.");
      await klikkaa(kartta, { piste, kartta: true, jalkeen: 2600 });
      const sulje = $("#map .leaflet-popup-close-button"); if (sulje) await liiku(sulje); await odota(250);
      if (typeof M !== "undefined" && M.home) { M.home.closePopup(); M.home.eachLayer(l => l.closeTooltip && l.closeTooltip()); }
      // hiiren "poistuminen" viivalta sulkee myös leijuvan vihjeen (canvas-kartta)
      const kb = kartta.getBoundingClientRect(), cvs = kartta.querySelector("canvas");
      if (cvs) cvs.dispatchEvent(new MouseEvent("mousemove", { bubbles: true, clientX: kb.left + 8, clientY: kb.bottom - 8 }));
      await odota(400); }
    const nous = await odotaEl(() => { const b = $("#nousBox .nous b"); return b && b.getBoundingClientRect().height ? b : null; }, 6000);
    if (nous) {
      await kerro("KETÄ SE KOSKEE", `${nous.textContent} nousua arkipäivässä työmaan pysäkeillä, HSL:n nousijamäärien mukaan.`);
      const sec = () => $("#nousSec"); await vieri(sisaY(det, sec(), 16), 1300, det); await odota(500);
      if (sec() && Math.abs(sec().getBoundingClientRect().top - det.getBoundingClientRect().top - 16) > 40) await vieri(sisaY(det, sec(), 16), 600, det);   // sivu piirsi tiedot uudelleen
      await liiku($("#nousBox .nous b") || nous); await odota(2600);
    }

    // 3. MITÄ SE MAKSAA
    await vieri(0, 1300, det); await vieri(0, 1300);
    const koostuu = $("#kpis [data-bd] .tmore");
    await kerro("MITÄ SE MAKSAA", "Mistä lisäaika koostuu ja mitä se maksaa euroina.");
    await klikkaa(koostuu, { jalkeen: 1200 });
    const eur = $$(".eurn")[0]; if (eur) { await liiku(eur); await odota(1700); }
    const linjoittain = tekstinMukaan("button, a", /^Linjoittain$/);
    await kerro("LINJOITTAIN", "Mikä linja kärsii katutöistä eniten?");
    await klikkaa(linjoittain, { jalkeen: 1300 });
    const ekaLinja = await odotaEl(() => $$('a[href="#/linjat"]').find(a => /^\d+[A-Z]?$/.test(a.textContent.trim()) && a.getBoundingClientRect().height > 0));
    await liiku({ x: keski(ekaLinja).x + 520, y: keski(ekaLinja).y }, 900); await odota(1100);

    // 4. LINJA
    await klikkaa(ekaLinja, { jalkeen: 2600 });
    await kerro("LINJA", "Linjan ohjaamo: lisäaika, viivevara ja kaikki reitin työmaat.");
    const vara = tekstinMukaan("#lCock *", /^viivevara/); if (vara) { await liiku(vara.parentElement || vara); await odota(1700); }
    const dd = $("#lCock .lc-dd") || tekstinMukaan("#lCock button", /Vaihda linjaa/);
    await kerro("LINJAT", "Kaikki linjat lisäajan mukaan: montako työmaata kullakin reitillä.");
    await klikkaa(dd, { jalkeen: 900 });
    const rivit = $$("#lList .lrow").filter(x => x.getBoundingClientRect().height > 0).slice(0, 5);
    for (const rv of rivit.slice(0, 3)) { await liiku(rv, 650); await odota(450); }
    const nyky = S.lSel;
    const valinta = rivit.find(x => x.dataset.n !== nyky && /ehdotus/.test(x.textContent)) || rivit.find(x => x.dataset.n !== nyky);
    await kerro("LINJA", "Linjan valinta: reitti ja sen työmaat vilkkuvat kartalla.");
    await klikkaa(valinta, { jalkeen: 3400 });
    // 5. TEKOÄLYAGENTTI
    const tab = await odotaEl(() => $$("#lTabs .ltab-h button").find(b => b.dataset.t === "sug"), 3000);
    if (tab) {
      await kerro("TEKOÄLYAGENTTI", "Agentti ehdottaa aikataulumuutosta mitattujen lukujen perusteella.");
      await klikkaa(tab, { jalkeen: 1400 });
      const ehd = $$("#lTabs .ltab-b td b, #lTabs .ltab-b b").find(b => /min$/.test(b.textContent.trim()));
      if (ehd) { await liiku(ehd); await odota(1600); }
      const miksi = $$("#lTabs summary").find(s => /Miksi agentti/.test(s.textContent));
      if (miksi) { await klikkaa(miksi, { jalkeen: 700 }); const lb = $("#lTabs .ltab-b");
        await vieri(sisaY(lb, miksi, 12), 1500, lb); await liiku(miksi.parentElement.querySelector("p, div:not(summary)") || miksi); await odota(2800); }
      const hyv = tekstinMukaan("#lTabs button", /^Hyväksy$/);
      if (hyv) { const lb = $("#lTabs .ltab-b"); await vieri(lb.scrollHeight, 1100, lb);
        await kerro("IHMINEN PÄÄTTÄÄ", "Agentti ei muuta aikatauluja itse. Suunnittelija hyväksyy tai hylkää, ja syy kirjataan.", true);
        await liiku(hyv); await odota(3200); }   // ei klikata: kirjoittaisi oikean arvion
    }

    // 6. ENNAKOI
    await kerro("ENNAKOI", "Suuren haitan työmaat, joista HSL:n häiriötiedotteissa ei ole mitään.");
    S.bdOpen = false;
    await klikkaa(tekstinMukaan("nav a", /^Tilannekuva$/), { jalkeen: 1500 });
    const tarkLinkki = await odotaEl(() => $$('#v-home a[href="#/tyot"]').find(a => /tarkistettavaa/.test(a.textContent) && a.getBoundingClientRect().height > 0));
    if (tarkLinkki) { await klikkaa(tarkLinkki, { jalkeen: 1600 });
      const siru = await odotaEl(() => $("#tark .aitag, #tark [class*=mitattu], #tark span"), 3000);
      const mit = $$("#tark span").find(s => /^mitattu/.test(s.textContent.trim())); if (mit) { await liiku(mit); await odota(1800); }
      const ekaTyo = $('#tark a[href^="#/?l="]');
      if (ekaTyo) { await kerro("ENNAKOI", "Työmaan tiedoista näkee, miksi se on listalla: mitattu viive on suuri, tiedotetta ei ole.");
        await klikkaa(ekaTyo, { jalkeen: 2400 });
        const f = $("#detail .facts > div"); if (f) { await liiku(f); await odota(2000); } } }

    // 7. TUOTANNOSSA
    await kerro("TUOTANNOSSA", "Valvottu: Vahti tarkistaa joka aamu datan, ajot ja tekoälykutsut. Kustannukset näkyvät.");
    await klikkaa(tekstinMukaan("nav a", /^Pilotti ja menetelmä$/), { jalkeen: 1300 });
    await klikkaa(tekstinMukaan("a, button", /^Tekoäly tuotannossa$/), { jalkeen: 1600 });
    const rivitV = $$("#v-kehitys tr, #v-kehitys .vrow").filter(x => x.getBoundingClientRect().height > 0).slice(0, 3);
    for (const rv of rivitV) { await liiku(rv.firstElementChild || rv, 650); await odota(500); }
    const kust = tekstinMukaan("#v-kehitys h3", /Käyttö ja kustannukset|Tuoteseloste/);
    if (kust) { await vieri(sivunY(kust, 110), 1800); await liiku(kust); await odota(2600); }
    piilotaTeksti(); await odota(400);

    // 8. loppukortti
    await kortti("val", `${logo}<h1>Mittaa. Ennakoi. Ehdottaa.<br><em>Ihminen päättää.</em></h1><p>pontuskettunen-cyber.github.io/tyomaatutka</p><small>Pontus Kettunen · konsepti, ei HSL:n eikä kaupungin virallinen palvelu · avoin data, ei henkilötietoja</small>`, 5200);
    lopeta();
  }

  // punainen kohta kartan canvasilta: lähimpänä kartan keskustaa oleva selvästi punainen pikseli
  function punainenPiste(kartta) {
    const cv = kartta && kartta.querySelector("canvas.leaflet-zoom-animated, canvas"); if (!cv) return null;
    try {
      const ctx = cv.getContext("2d"), w = cv.width, h = cv.height, d = ctx.getImageData(0, 0, w, h).data;
      const b = cv.getBoundingClientRect(), sx = b.width / w, sy = b.height / h, cx = w / 2, cy = h / 2;
      let best = null, bd = Infinity;
      const pun = (x, y) => { if (x < 0 || y < 0 || x >= w || y >= h) return false; const i = (y * w + x) * 4; return d[i] > 150 && d[i + 1] < 70 && d[i + 2] < 70 && d[i + 3] > 200; };
      const r0 = 40 * (w / b.width);   // valitun työmaan rengas ja pysäkit keskellä: vältetään
      for (let y = 0; y < h; y += 3) for (let x = 0; x < w; x += 3) {
        if (!pun(x, y)) continue;
        const dd = (x - cx) ** 2 + (y - cy) ** 2; if (dd < r0 * r0 || dd >= bd) continue;
        let n = 0; for (let a = -4; a <= 4; a += 2) for (let c = -4; c <= 4; c += 2) n += pun(x + a, y + c);   // paksu viiva, ei reunapikseli
        if (n >= 12) { bd = dd; best = { x, y }; } }
      return best && { x: b.left + best.x * sx, y: b.top + best.y * sy };
    } catch (e) { return null; }
  }

  function lopeta() { piilotaTeksti(); kursori.style.transform = "translate(-100px,-100px)"; document.documentElement.classList.remove("esitys"); }

  /* ---------- käynnistys ---------- */
  const alku = document.createElement("div"); alku.className = "es-alku";
  alku.innerHTML = `<div><button type="button" disabled>Ladataan tietoja…</button><p>Käynnistä ensin näytöntallennus. Älä liikuta hiirtä esityksen aikana. Välilyönti käynnistää, Esc keskeyttää.</p></div>`;
  document.body.appendChild(alku);
  let valmis = false;
  (async () => { while (!(typeof S !== "undefined" && S.loaded)) await odota(200); await odota(1500); valmis = true;
    const b = alku.querySelector("button"); b.disabled = false; b.textContent = "▶ Käynnistä esitys"; })();
  const kaynnista = async () => { if (!alku.isConnected || !valmis) return; alku.remove(); await odota(400);
    try { await kierros(); } catch (e) { console.warn("Esitys:", e.message); lopeta(); } };
  alku.querySelector("button").onclick = kaynnista;
  addEventListener("keydown", e => { if (e.code === "Space" && alku.isConnected) { e.preventDefault(); kaynnista(); } if (e.key === "Escape") seis = true; });
})();
