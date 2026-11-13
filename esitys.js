/* Esittely: tervetuloikkunan "Katso miten se toimii" (window.ttOpastus) tai tallennustila osoitteella ?demo.
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
    border:3px solid #1F5FBF;background:rgba(31,95,191,.25);animation:esRengas .7s ease-out forwards}
  @keyframes esRengas{to{transform:scale(4.2);opacity:0}}
  .es-teksti{position:fixed;left:50%;bottom:26px;z-index:99998;pointer-events:none;transform:translate(-50%,16px);opacity:0;
    display:flex;align-items:center;gap:14px;max-width:min(980px,calc(100vw - 60px));padding:14px 22px 14px 16px;background:#fff;
    border-radius:14px;box-shadow:0 10px 34px rgba(0,30,55,.22),0 0 0 1px rgba(0,0,0,.04);font:600 19px/1.35 Nunito,system-ui,sans-serif;color:#003456;
    transition:opacity .45s, transform .45s}
  .es-teksti.on{opacity:1;transform:translate(-50%,0)}
  .es-teksti.ylos{bottom:auto;top:84px}
  .es-teksti i{font-style:normal;flex:none;background:#1F5FBF;color:#fff;font:800 13px Nunito,system-ui;letter-spacing:.06em;padding:6px 10px;border-radius:4px}
  .es-kortti{position:fixed;inset:0;z-index:100001;display:flex;flex-direction:column;justify-content:center;padding:0 9vw;
    font-family:Nunito,system-ui,sans-serif;opacity:0;transition:opacity .7s;pointer-events:none}
  .es-kortti.on{opacity:1}
  .es-kortti.sin{background:#0F1B2D;color:#fff}.es-kortti.val{background:#fff;color:#003456}
  .es-kortti .lg{display:flex;align-items:center;gap:14px;font:800 34px Nunito}
  .es-kortti .lg span{width:44px;height:44px;border-radius:11px;display:grid;place-items:center}
  .es-kortti.sin .lg span{background:#fff}.es-kortti.val .lg span{background:#1F5FBF}
  .es-kortti .lg span b{width:26px;height:26px;border-radius:50%;border:4px solid;display:grid;place-items:center;box-sizing:border-box}
  .es-kortti.sin .lg b{border-color:#1F5FBF}.es-kortti.val .lg b{border-color:#fff}
  .es-kortti .lg b::after{content:"";width:8px;height:8px;border-radius:50%;background:currentColor}
  .es-kortti.sin .lg b{color:#1F5FBF}.es-kortti.val .lg b{color:#fff}
  .es-kortti h1{font:800 clamp(40px,5.6vw,84px)/1.08 Nunito;margin:34px 0 0;letter-spacing:-.01em}
  .es-kortti h1 em{font-style:normal;color:#1F5FBF}
  .es-kortti p{font:400 clamp(17px,1.7vw,26px)/1.4 Nunito;margin:26px 0 0;opacity:.9}
  .es-kortti small{font:400 15px Nunito;margin-top:36px;opacity:.75}
  .es-alku{position:fixed;inset:0;z-index:100002;display:grid;place-items:center;background:rgba(0,30,55,.55);backdrop-filter:blur(3px)}
  .es-alku button{font:800 22px Nunito;padding:18px 30px;border-radius:14px;border:0;background:#1F5FBF;color:#fff;cursor:pointer !important;box-shadow:0 10px 30px rgba(0,0,0,.3)}
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
    } else if (opts.alas) el.dispatchEvent(new MouseEvent("mousedown", { bubbles: true, cancelable: true, clientX: kx, clientY: ky, button: 0 }));
    else if (typeof el.click === "function") el.click();
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
  const NIMI = /Työmaatutka/.test(document.title) ? "Työmaatutka" : "Tietutka";
  const logo = `<div class="lg"><span><b></b></span>${NIMI}</div>`;
  const nf = n => Number(n).toLocaleString("fi-FI");

  /* ---------- kierros (karttatyöpöytä, n. 70 s) ---------- */
  const ws = k => document.querySelector(`.tp-pal[data-pal="${k}"]`);
  const nakyy = el => el && el.getBoundingClientRect().height > 0 && el.getBoundingClientRect().width > 0;
  async function kirjoita(input, txt) { input.focus(); input.value = "";
    for (const c of txt) { tarkista(); input.value += c; input.dispatchEvent(new Event("input", { bubbles: true })); await odota(230); } }
  async function kierros() {
    document.documentElement.classList.add("esitys");
    await odotaEl(() => typeof S !== "undefined" && S.loaded, 30000);
    if (location.hash !== "#/") { location.hash = "#/"; await odota(900); }
    if (typeof tpAvaaWs === "function") { tpAvaaWs("home", "tilanne"); tpAvaaWs("home", "tyomaa"); }
    await odota(400);

    // 0. aloituskortti
    await kortti("sin", `${logo}<h1>Mitä katutyöt maksavat<br>joukkoliikenteelle?</h1><p>Esittely noin minuutissa · oikea data tältä päivältä</p>`, 2600);

    // 1. MITTAA
    await kerro("MITTAA", "Tutka mittaa joka päivä avoimesta datasta, paljonko katutyöt hidastavat busseja ja ratikoita.");
    const tilanne = ws("tilanne");
    const kpi = tilanne && (tilanne.querySelector("#kpis [data-bd] b") || tilanne.querySelector(".tp-pb b"));
    if (kpi) { await liiku(kpi); await odota(2200); }

    // 2. TYÖMAA
    const kortti1 = $$("#cards .card").find(nakyy);
    if (kortti1) {
      await kerro("TYÖMAA", "Lista näyttää työt, jotka aiheuttavat eniten lisäaikaa. Klikkaa työmaata.");
      await klikkaa(kortti1, { jalkeen: 1600 });
      const f = await odotaEl(() => $$("#detail .facts > div").find(nakyy), 4000);
      if (f) { await kerro("TYÖMAA", "Lisäaika jokaista ohi ajavaa bussia tai ratikkaa kohden. Mitattu = sama katu ilman töitä vs. työn aikana.");
        await liiku(f); await odota(2600); }
      const siru = $$("#detail .lsiru").find(nakyy);
      if (siru) { await kerro("KARTTA", "Linjan numerosta reitti ja sen työmaat tulevat kartalle.");
        await klikkaa(siru, { jalkeen: 2600 }); }
    }

    // 3. HAKU
    const q = $("#omaQ");
    const linja = (S.hLinja && /^\d/.test(S.hLinja)) ? S.hLinja : "55";
    if (q && nakyy(q)) {
      await kerro("HAKU", "Yksi haku linjoille, kaduille ja luville.", true);
      await klikkaa(q, { jalkeen: 500 }); await kirjoita(q, linja); await odota(1300);
      const eka = await odotaEl(() => $$("#hakuDD .hk").find(nakyy), 3000);
      if (eka) await klikkaa(eka, { alas: true, jalkeen: 2200 }); else { q.value = ""; location.hash = "#/linjat"; await odota(1500); }
    }

    // 4. LINJA
    if (location.hash.startsWith("#/linjat")) {
      if (typeof tpAvaaWs === "function") tpAvaaWs("linjat", "kulku");
      const k = await odotaEl(() => $$("#lCock .lc-k").find(nakyy), 5000);
      if (k) { await kerro("LINJA", "Linjan ohjaamo: tavallinen vuoro, huonoimmat vuorot ja aikataulun viivevara.");
        await liiku(k); await odota(1800);
        const vv = $$("#lCock .lc-k").filter(nakyy).pop(); if (vv && vv !== k) { await liiku(vv); await odota(1600); } }
      const sug = $$("#lTabs .ltab-h button").find(b => b.dataset.t === "sug" && nakyy(b));
      if (sug) { await kerro("TEKOÄLYAGENTTI", "Agentti ehdottaa aikataulumuutosta mitattujen lukujen perusteella.");
        await klikkaa(sug, { jalkeen: 1800 });
        const hyv = tekstinMukaan("#lTabs button", /^Hyväksy$/);
        if (hyv) { await kerro("IHMINEN PÄÄTTÄÄ", "Agentti ei muuta aikatauluja itse. Suunnittelija hyväksyy tai hylkää, ja syy kirjataan.");
          await liiku(hyv); await odota(2800); } }   // ei klikata: kirjoittaisi oikean arvion
      else { const t = $$("#lTabs .ltab-h button").find(nakyy);
        if (t) { await kerro("LINJA", "Reitin työmaat ja niiden vaikutus tällä linjalla."); await liiku(t); await odota(2000); } }
    }

    // 5. ENNAKOI
    const arv = $$('.tp-rail [data-nak="#/ennakko"]').find(nakyy);
    if (arv) {
      await kerro("ENNAKOI", "Alkava työ arvioidaan ennen kuin se alkaa.");
      await klikkaa(arv, { jalkeen: 1800 });
      if (typeof tpAvaaWs === "function") { tpAvaaWs("ennakko", "tyo"); tpAvaaWs("ennakko", "arvio"); }
      const sel = await odotaEl(() => { const s = $("#enLupa"); return s && s.options.length > 1 ? s : null; }, 6000);
      if (sel && nakyy(sel) && typeof valitseLupaEn === "function") {
        await liiku(sel); await odota(500);
        sel.value = sel.options[1].value; valitseLupaEn(sel.value); await odota(2600);
        const tulos = await odotaEl(() => $$("#enOut .enkp > div").find(nakyy), 6000);
        if (tulos) { await kerro("ENNAKOI", "Arvio: paljonko työ lisää ajoaikaa, mitkä linjat kärsivät ja mikä ajoitus haittaa vähiten.");
          await liiku(tulos); await odota(2600);
          const rec = $$("#enOut .rec").find(nakyy); if (rec) { await liiku(rec); await odota(2400); } }
      }
    }
    piilotaTeksti(); await odota(300);

    // 6. loppukortti
    await kortti("val", `${logo}<h1>Mittaa. Ennakoi. Ehdottaa.<br><em>Ihminen päättää.</em></h1><p>Avoin data · ei henkilötietoja · ${NIMI === "Työmaatutka" ? "konsepti, ei HSL:n eikä kaupungin virallinen palvelu" : "itsenäinen palvelu"}</p>`, 3200);
    location.hash = "#/";
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

  function lopeta() { const q = $("#omaQ"), dd = $("#hakuDD"); if (q) { q.value = ""; q.blur(); } if (dd) dd.hidden = true;
    piilotaTeksti(); kursori.style.transform = "translate(-100px,-100px)"; document.documentElement.classList.remove("esitys"); }

  /* ---------- käynnistys ---------- */
  // Opastus tervetuloikkunasta: läpinäkyvä suoja estää vahinkoklikkaukset, Lopeta-nappi ja Esc keskeyttävät.
  window.ttOpastus = async () => {
    if (document.documentElement.classList.contains("esitys")) return;
    seis = false;
    const suoja = document.createElement("div"); suoja.className = "es-suoja";
    suoja.innerHTML = `<button type="button">Lopeta esittely ✕</button>`;
    suoja.querySelector("button").onclick = () => { seis = true; };
    document.body.appendChild(suoja);
    try { await kierros(); } catch (e) { console.warn("Esittely:", e.message); lopeta(); if (location.hash !== "#/") location.hash = "#/"; }
    suoja.remove();
  };
  addEventListener("keydown", e => { if (e.key === "Escape") seis = true; });
  const css2 = document.createElement("style");
  css2.textContent = `.es-suoja{position:fixed;inset:0;z-index:99990;cursor:default}
  .es-suoja button{position:fixed;top:14px;right:16px;font:700 14px Nunito,system-ui,sans-serif;padding:9px 14px;border-radius:8px;border:0;background:#0F1B2D;color:#fff;cursor:pointer!important;box-shadow:0 4px 14px rgba(0,0,0,.25);z-index:100003}
  html.esitys .es-suoja button, html.esitys .es-suoja button *{cursor:pointer!important}`;
  document.head.appendChild(css2);
  if (!new URLSearchParams(location.search).has("demo")) return;

  const alku = document.createElement("div"); alku.className = "es-alku";
  alku.innerHTML = `<div><button type="button" disabled>Ladataan tietoja…</button><p>Käynnistä ensin näytöntallennus. Älä liikuta hiirtä esityksen aikana. Välilyönti käynnistää, Esc keskeyttää.</p></div>`;
  document.body.appendChild(alku);
  let valmis = false;
  (async () => { while (!(typeof S !== "undefined" && S.loaded)) await odota(200); await odota(1500); valmis = true;
    const b = alku.querySelector("button"); b.disabled = false; b.textContent = "▶ Käynnistä esitys"; })();
  const kaynnista = async () => { if (!alku.isConnected || !valmis) return; alku.remove(); await odota(400);
    try { await kierros(); } catch (e) { console.warn("Esitys:", e.message); lopeta(); } };
  alku.querySelector("button").onclick = kaynnista;
  addEventListener("keydown", e => { if (e.code === "Space" && alku.isConnected) { e.preventDefault(); kaynnista(); } });
})();
