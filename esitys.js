/* Esittely: tervetuloikkunan "Katso miten se toimii" (window.ttOpastus) tai tallennustila osoitteella ?demo.
   Kierros käyttää sivun oikeita toimintoja: jokainen klikkaus avaa jotain. Hyväksy- ja kuittausnappeja ei paineta.
   Käyttö: avaa ?demo, käynnistä näytöntallennus, paina välilyöntiä (tai nappia). Esc keskeyttää. */
(() => {
  "use strict";
  const $ = (s, r = document) => r.querySelector(s);
  const $$ = (s, r = document) => [...r.querySelectorAll(s)];
  const TAHTI = 1.35;   // rauhallinen tahti: pitkät tauot pidemmiksi, jotta katsoja ehtii lukea ja katsoa
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
  .es-teksti{position:fixed;left:50%;bottom:34px;z-index:99998;pointer-events:none;transform:translate(-50%,18px);opacity:0;
    display:flex;align-items:center;gap:18px;width:min(940px,calc(100vw - 80px));padding:20px 28px 20px 20px;background:#0F1B2D;
    border-radius:12px;box-shadow:0 18px 50px rgba(5,12,25,.45),0 0 0 1px rgba(255,255,255,.08);font:700 23px/1.4 Nunito,system-ui,sans-serif;color:#fff;
    transition:opacity .6s, transform .6s}
  .es-teksti span{text-wrap:balance}
  .es-hamaru{position:fixed;left:0;right:0;bottom:0;height:220px;z-index:99997;pointer-events:none;opacity:0;transition:opacity .6s;
    background:linear-gradient(to top,rgba(10,18,32,.45),rgba(10,18,32,0))}
  .es-hamaru.on{opacity:1}
  .es-kohde{position:fixed;z-index:99996;pointer-events:none;border:3px solid #F5A524;border-radius:10px;box-shadow:0 0 0 6px rgba(245,165,36,.22),0 0 0 9999px rgba(10,18,32,.18);
    opacity:0;transition:opacity .5s, left .6s, top .6s, width .6s, height .6s}
  .es-kohde.on{opacity:1}
  .es-teksti.on{opacity:1;transform:translate(-50%,0)}
  .es-teksti.ylos{bottom:auto;top:96px}
  .es-teksti i{font-style:normal;flex:none;display:flex;flex-direction:column;align-items:center;gap:2px;background:#F5A524;color:#0F1B2D;font:800 14px Nunito,system-ui;letter-spacing:.06em;padding:8px 12px;border-radius:6px}
  .es-teksti i small{font:700 11px Nunito,system-ui;letter-spacing:.04em;opacity:.75}
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
  const hamaru = document.createElement("div"); hamaru.className = "es-hamaru";
  const kohde = document.createElement("div"); kohde.className = "es-kohde";
  document.body.append(hamaru, kohde, kursori, teksti);
  // korostus: kehys kohteen ympärille ja muu näkymä hieman himmeämmäksi
  let fokus = null;   // korostettu alue (viewportin koordinaatit)
  function korosta(el) {
    const b = el && (el.getBoundingClientRect ? el.getBoundingClientRect() : el);
    if (!b || !b.width) { poistaKorostus(); return; }
    const v = 8; fokus = { left: b.left - v, top: b.top - v, right: b.right + v, bottom: b.bottom + v };
    Object.assign(kohde.style, { left: fokus.left + "px", top: fokus.top + "px", width: (fokus.right - fokus.left) + "px", height: (fokus.bottom - fokus.top) + "px" });
    kohde.classList.add("on"); sijoitaTeksti(); }
  function poistaKorostus() { kohde.classList.remove("on"); fokus = null; }
  // tekstitys alas, paitsi jos se peittäisi korostetun kohdan (tai kursorin): silloin ylös
  function sijoitaTeksti() {
    if (!teksti.classList.contains("on")) return;
    const h = teksti.offsetHeight || 90, ala = innerHeight - 34 - h - 12;
    const peittaa = r => r && r.bottom > ala && r.top < innerHeight;
    const yla = peittaa(fokus) || (ky > ala - 20);
    teksti.classList.toggle("ylos", !!yla); }

  /* ---------- liike ---------- */
  let kx = innerWidth * .55, ky = innerHeight * .55;
  const aseta = (x, y) => { kx = x; ky = y; kursori.style.transform = `translate(${x - 4}px,${y - 3}px)`; };
  aseta(kx, ky);
  const keski = el => { const b = el.getBoundingClientRect(); return { x: b.left + b.width / 2, y: b.top + b.height / 2 }; };
  async function liiku(kohde, kesto) {
    tarkista();
    if (kohde instanceof Element) {
      const pb = kohde.closest(".tp-pb");
      if (pb) { const kb = kohde.getBoundingClientRect(), pbb = pb.getBoundingClientRect();
        if (kb.top < pbb.top + 10 || kb.bottom > pbb.bottom - 10) { await vieri(sisaY(pb, kohde, Math.max(20, (pbb.height - kb.height) / 3)), 900, pb); await odota(250); } }
      korosta(kohde); } else poistaKorostus();
    const p = kohde instanceof Element ? keski(kohde) : kohde;
    const x0 = kx, y0 = ky, dx = p.x - x0, dy = p.y - y0, d = Math.hypot(dx, dy);
    kesto = kesto || Math.min(1800, Math.max(800, d * 1.6));
    const kaari = Math.min(70, d * .12), nx = -dy / (d || 1), ny = dx / (d || 1);   // pieni kaari, ei suoraa viivaa
    return new Promise(res => { const t0 = performance.now();
      const askel = t => { const q = Math.min(1, (t - t0) / kesto), e = ease(q), b = Math.sin(Math.PI * e) * kaari;
        aseta(x0 + dx * e + nx * b, y0 + dy * e + ny * b); if (q === 1) sijoitaTeksti();
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
    poistaKorostus();
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
  const VAIHEET = ["NÄKYMÄ", "TILANNE NYT", "PALETIT", "LIVE", "TYÖMAA", "TÄNÄÄN", "LINJA", "ENNAKOI", "VALVOMO"];
  async function kerro(tag, t, ylos = false) {
    if (teksti.classList.contains("on")) { teksti.classList.remove("on"); await odota(450); }
    const n = VAIHEET.findIndex(v => tag === v || (v === "NÄKYMÄ" && tag === "TYÖKALUT") || (v === "TÄNÄÄN" && tag === "TEKOÄLY") || (v === "LINJA" && /HAKU|AGENTTI|IHMINEN/.test(tag)) || (v === "VALVOMO" && tag === "TIETOA"));
    teksti.innerHTML = `<i>${tag}${n >= 0 ? `<small>${n + 1} / ${VAIHEET.length}</small>` : ""}</i><span>${t}</span>`;
    teksti.classList.add("on"); hamaru.classList.add("on"); sijoitaTeksti();
    await odota(1400 + t.length * 38);   // lukuaika ennen kuin jotain tapahtuu
  }
  const piilotaTeksti = () => { teksti.classList.remove("on"); hamaru.classList.remove("on"); poistaKorostus(); };
  async function kortti(luokka, html, kesto) {
    const k = document.createElement("div"); k.className = "es-kortti " + luokka; k.innerHTML = html; document.body.appendChild(k);
    await odota(30); k.classList.add("on"); await odota(kesto); k.classList.remove("on"); await odota(750); k.remove();
  }
  const NIMI = /Työmaatutka/.test(document.title) ? "Työmaatutka" : "Tietutka";
  const logo = `<div class="lg"><span><b></b></span>${NIMI}</div>`;
  const nf = n => Number(n).toLocaleString("fi-FI");

  /* ---------- kierros: koko tutka noin 4–5 minuutissa ---------- */
  const ws = k => document.querySelector(`.tp-pal[data-pal="${k}"]`);
  const nakyy = el => el && el.getBoundingClientRect().height > 0 && el.getBoundingClientRect().width > 0;
  const rail = sel => $$(".tp-rail " + sel).find(nakyy);
  async function kirjoita(input, txt) { input.focus(); input.value = "";
    for (const c of txt) { tarkista(); input.value += c; input.dispatchEvent(new Event("input", { bubbles: true })); await odota(420); } }
  const ruutu = (m, ll) => { const p = m.latLngToContainerPoint(ll), r = m.getContainer().getBoundingClientRect(); return { x: r.left + p.x, y: r.top + p.y }; };
  const keskelle = (m, ll) => { const r = m.getContainer().getBoundingClientRect(), p = ruutu(m, ll); return p.x > r.left + 60 && p.x < r.right - 60 && p.y > r.top + 60 && p.y < r.bottom - 60; };
  // paletin raahaus: kursori tarttuu otsikkoon ja paletti seuraa
  async function raahaa(el, dx, dy) {
    const ph = el.querySelector(".tp-ph"), b = el.getBoundingClientRect(), hb = ph.getBoundingClientRect();
    await liiku({ x: hb.left + 70, y: hb.top + hb.height / 2 }); poistaKorostus(); await odota(300);
    kursori.classList.add("painuu"); el.classList.add("raahaa");
    const x0 = b.left - el.parentElement.getBoundingClientRect().left, y0 = b.top - el.parentElement.getBoundingClientRect().top, kx0 = kx, ky0 = ky;
    el.style.right = el.style.bottom = "";
    await new Promise(res => { const t0 = performance.now(), kesto = 1700;
      const askel = t => { const q = Math.min(1, (t - t0) / kesto), e = ease(q);
        el.style.left = (x0 + dx * e) + "px"; el.style.top = (y0 + dy * e) + "px"; aseta(kx0 + dx * e, ky0 + dy * e);
        q < 1 ? requestAnimationFrame(askel) : res(); }; requestAnimationFrame(askel); });
    el.classList.remove("raahaa"); kursori.classList.remove("painuu");
  }
  // koon muutos oikeasta alakulmasta
  async function venyta(el, dw, dh) {
    const b = el.getBoundingClientRect();
    await liiku({ x: b.right - 8, y: b.bottom - 8 }); await odota(300); kursori.classList.add("painuu");
    const w0 = el.offsetWidth, h0 = el.offsetHeight, kx0 = kx, ky0 = ky;
    await new Promise(res => { const t0 = performance.now(), kesto = 1600;
      const askel = t => { const q = Math.min(1, (t - t0) / kesto), e = ease(q);
        el.style.width = (w0 + dw * e) + "px"; el.style.height = (h0 + dh * e) + "px"; aseta(kx0 + dw * e, ky0 + dh * e);
        q < 1 ? requestAnimationFrame(askel) : res(); }; requestAnimationFrame(askel); });
    kursori.classList.remove("painuu");
  }
  // käyttäjän oma palettiasettelu talteen ja takaisin esittelyn jälkeen
  const AVAIMET = ["tt_tp", "tt_tp_home", "tt_tp_linja"];
  let talletettu = null;
  const tallennaAsettelu = () => { try { talletettu = AVAIMET.map(k => [k, localStorage.getItem(k)]); } catch (e) {} };
  function palautaAsettelu() {
    try { (talletettu || []).forEach(([k, v]) => v == null ? localStorage.removeItem(k) : localStorage.setItem(k, v)); } catch (e) {}
    try { if (typeof TPS !== "undefined" && typeof tpLue === "function") ["home", "linjat", "ennakko"].forEach(w => { if (TPS[w]) { TPS[w] = tpLue(w); if (typeof tpPiirraWs === "function") tpPiirraWs(w); } }); } catch (e) {}
  }

  async function kierros() {
    document.documentElement.classList.add("esitys");
    tallennaAsettelu();
    await odotaEl(() => typeof S !== "undefined" && S.loaded, 30000);
    if (location.hash !== "#/") { location.hash = "#/"; await odota(900); }
    const palauta = rail('[data-tp="palauta"]'); if (palauta) palauta.click();   // oletusasettelu
    await odota(500);

    await kortti("sin", `${logo}<h1>Mitä katutyöt maksavat<br>joukkoliikenteelle?</h1><p>Esittely noin neljässä minuutissa · oikea data tältä päivältä</p>`, 3200);

    // 1. NÄKYMÄ
    await kerro("NÄKYMÄ", "Tutka on yksi kartta, jonka päällä on siirrettäviä paletteja. Käydään ensin läpi, mistä löytyy mitäkin.");
    await liiku($(".top nav") || $(".top")); await odota(2200);
    await kerro("NÄKYMÄ", "Yläpalkissa ovat näkymät: tilannekuva, linjat, ennakkoarvio, valvomo ja tietoa. Hakukenttä löytää linjat, kadut ja luvat.");
    const q0 = $("#omaQ"); if (q0) { await liiku(q0); await odota(2200); }
    const r0 = $$(".tp-rail").find(nakyy);
    if (r0) { await kerro("TYÖKALUT", "Vasemman reunan työkalupalkista vaihdetaan näkymää, avataan paletteja, valitaan karttatasot ja zoomataan.");
      await liiku(r0); await odota(3200); }

    // 2. TILANNE NYT
    const til = ws("tilanne");
    if (til) {
      await kerro("TILANNE NYT", "Tilanne nyt kertoo yhdellä silmäyksellä, mikä työmaa hidastaa eniten ja paljonko lisäaikaa syntyy vuorokaudessa.");
      const ots = til.querySelector(".tp-pb") && til.querySelector(".tp-pb").firstElementChild; if (ots) { await liiku(ots); await odota(2600); }
      const kpi = til.querySelector("#kpis [data-bd]");
      if (kpi) { await liiku(kpi); await odota(2000);
        const mk = kpi.querySelector(".tmore");
        if (mk) { await kerro("TILANNE NYT", "Mistä koostuu: lisäaika eriteltynä työmaittain, linjoittain ja työtyypeittäin.");
          await klikkaa(mk, { jalkeen: 2600 }); const er = $$("#bdTabs").find(nakyy); if (er) { await liiku(er); await odota(2400); }
          const mk2 = til.querySelector("#kpis [data-bd] .tmore"); if (mk2) await klikkaa(mk2, { jalkeen: 900 }); } }
      const lista = $$("#cards .card").find(nakyy);
      if (lista) { await kerro("TILANNE NYT", "Alla lista töistä, jotka vaikuttavat eniten. Punainen luku on lisäaika vuorokaudessa, pienempi luku per ohi ajava bussi.");
        await liiku(lista); await odota(3000); }
    }

    // 3. PALETIT
    const pTyo = ws("tyomaa"), pTil = ws("tilanne");
    if (pTil && nakyy(pTil)) {
      await kerro("PALETIT", "Paletteja voi siirtää: tartu otsikkoriviin ja raahaa.");
      await raahaa(pTil, 220, 60); await odota(1200);
      await kerro("PALETIT", "Kokoa muutetaan oikeasta alakulmasta.");
      await venyta(pTil, 90, -120); await odota(1200);
      await kerro("PALETIT", "Viiva pienentää paletin otsikoksi. Otsikkoa klikkaamalla se avautuu taas.");
      const mn = pTil.querySelector(".tp-min"); if (mn) { await klikkaa(mn, { jalkeen: 1800 });
        const ph = ws("tilanne") && ws("tilanne").querySelector(".tp-ph"); if (ph) { await liiku(ph); await odota(1400); await klikkaa(ph, { jalkeen: 1500 }); } }
      await kerro("PALETIT", "Ruksi sulkee paletin, ja työkalupalkista sen saa takaisin. Palauta vie kaiken oletuspaikoille.");
      const pal = rail('[data-tp="palauta"]'); if (pal) await klikkaa(pal, { jalkeen: 1800 });
    }

    // 4. LIVE
    const m = typeof M !== "undefined" && M.home;
    const k1 = $$("#cards .card").find(nakyy), l1 = k1 && S.byId && S.byId[k1.dataset.id];
    if (m && typeof LV !== "undefined") {
      await kerro("LIVE", "Live-kerros näyttää jokaisen bussin ja ratikan sijainnin noin sekunnin välein.");
      const lv = rail('[data-ker="live"]'); if (lv && !LV.on) await klikkaa(lv, { jalkeen: 1200 }); else if (lv) { await liiku(lv); await odota(1200); }
      const c = l1 && l1.geom && typeof centroid === "function" ? centroid(l1.geom) : null;
      if (c) { m.flyTo(c, 16, { duration: 2.2 }); await odota(4200); }
      await odotaEl(() => [...LV.veh.values()].some(v => keskelle(m, [v.lat, v.lon])), 9000);
      await kerro("LIVE", "Sininen on bussi, vihreä ratikka. Keltainen reunus: auto on työmaan kohdalla juuri nyt. Harmaa auto seisoo, eikä sitä lasketa myöhästymiseksi.");
      await odota(2500);
      const ehd = [...LV.veh.entries()].filter(([, v]) => keskelle(m, [v.lat, v.lon]) && typeof vTila === "function" && vTila(v).k !== "seis");
      const val = ehd.find(([, v]) => typeof nearSite === "function" && nearSite(v.lat, v.lon)) || ehd[0];
      if (val) {
        const [id, v] = val, p = ruutu(m, [v.lat, v.lon]);
        await kerro("LIVE", "Klikkaa autoa: näet linjan, myöhästymisen ja työmaan, jonka kohdalla se on. Linjan reitti tulee kartalle.");
        await liiku(p); korosta({ left: p.x - 16, top: p.y - 16, right: p.x + 16, bottom: p.y + 16, width: 32, height: 32 }); await odota(500);
        kursori.classList.add("painuu"); const rr = document.createElement("div"); rr.className = "es-rengas"; rr.style.left = p.x + "px"; rr.style.top = p.y + "px";
        document.body.appendChild(rr); setTimeout(() => rr.remove(), 800); await odota(140); kursori.classList.remove("painuu");
        if (typeof togglePin === "function") togglePin(id); poistaKorostus(); await odota(5200);
        if (typeof togglePin === "function" && LV.pinned.has(id)) togglePin(id);
        if (typeof hLinjaPois === "function") hLinjaPois(true);
      }
    }

    // 5. TYÖMAA
    if (l1 && typeof select === "function") {
      await kerro("TYÖMAA", "Työmaat näkyvät kartalla alueina. Väri kertoo vaikutuksen: punainen hidastaa, harmaa ei, oranssi odottaa mittausta.");
      const c = typeof centroid === "function" ? centroid(l1.geom) : null;
      if (c && m) { const p = ruutu(m, c); await liiku(p); await odota(700); kursori.classList.add("painuu"); await odota(140); kursori.classList.remove("painuu"); }
      select(l1.lupa_id, false); await odota(1800);
      const f = await odotaEl(() => $$("#detail .facts > div").find(nakyy), 4000);
      if (f) { const im = typeof impact === "function" ? impact(l1) : null;
        await kerro("TYÖMAA", im && im.tod ? "Lisäaika jokaista ohi ajavaa bussia tai ratikkaa kohden, mitattuna: sama katu ilman töitä vs. työn aikana."
          : "Lisäaika jokaista ohi ajavaa bussia tai ratikkaa kohden. Harmaa luku on arvio, joka mitataan, kun työ päättyy.");
        await liiku(f); await odota(3000); }
      const alue = $$("#detail .alue").find(nakyy);
      if (alue) { await kerro("TYÖMAA", "Jos samalla kohdalla on useita töitä, ne mitataan yhdessä. Tutka kertoo, milloin osuudet selviävät."); await liiku(alue); await odota(3000); }
      const taulu = $$("#detail table.t").find(nakyy);
      if (taulu) { await kerro("TYÖMAA", "Linjat työmaan kohdalla: ohitukset ja lisäaika suunnittain."); await liiku(taulu); await odota(3000); }
      const siru = $$("#detail .lsiru").find(nakyy);
      if (siru) { await kerro("TYÖMAA", "Linjan numerosta sen reitti ja kaikki reitin työmaat tulevat kartalle."); await klikkaa(siru, { jalkeen: 3200 });
        if (typeof hLinjaPois === "function") hLinjaPois(true); await odota(600); }
    }

    // 6. TÄNÄÄN JA TEKOÄLY
    const tn = rail('[data-tp="tanaan"]');
    // tilaa uudelle paletille: työmaan tiedot pienennetään otsikoksi
    try { if (TPS.home && TPS.home.pal.tyomaa && TPS.home.pal.tyomaa.auki) { TPS.home.pal.tyomaa.min = true; tpPiirraWs("home"); await odota(500); } } catch (e) {}
    if (tn) { await kerro("TÄNÄÄN", "Tänään huomioitavaa: alkavat työt, kasautumat ja työmaat, joista HSL:n tiedotteissa ei ole mainintaa.");
      await klikkaa(tn, { jalkeen: 1600 }); const p = ws("tanaan"); if (p && nakyy(p)) { await liiku(p.querySelector(".tp-pb") || p); await odota(3400); } }
    const ai = rail('[data-tp="ai"]');
    if (ai) { await kerro("TEKOÄLY", "Tekoälykatsaus kirjoittaa tilanteesta tiivistelmän. Luvut lasketaan SQL:llä, kielimalli vain kirjoittaa, ja siltä voi kysyä omin sanoin.");
      await klikkaa(ai, { jalkeen: 1600 }); const p = ws("ai"); if (p && nakyy(p)) { await liiku(p.querySelector(".tp-pb") || p); await odota(3600); } }

    // 7. HAKU JA LINJA
    const q = $("#omaQ");
    const linja = (l1 && typeof lines === "function" && lines(l1.linjat).find(n => !/N$/.test(n))) || "55";
    if (q && nakyy(q)) {
      await kerro("HAKU", "Haku: kirjoita linjan numero, katu tai lupatunnus.");
      await klikkaa(q, { jalkeen: 500 }); await kirjoita(q, linja); await odota(1600);
      const eka = await odotaEl(() => $$("#hakuDD .hk").find(nakyy), 3000);
      if (eka) await klikkaa(eka, { alas: true, jalkeen: 2600 }); else { q.value = ""; location.hash = "#/linjat"; await odota(1800); }
    }
    if (location.hash.startsWith("#/linjat")) {
      const k = await odotaEl(() => $$("#lCock .lc-k").find(nakyy), 5000);
      if (k) { await kerro("LINJA", "Linjan ohjaamo: tavallinen vuoro, huonoimmat 10 % vuoroista ja aikataulun viivevara, eli mahtuuko lisäaika aikatauluun.");
        await liiku(k); await odota(2400);
        const vv = $$("#lCock .lc-k").filter(nakyy)[2]; if (vv) { await liiku(vv); await odota(2400); } }
      const nauha = $$("#lNauha").find(nakyy);
      if (nauha) { await kerro("LINJA", "Reittinauha näyttää linjan pysäkit järjestyksessä ja missä kohtaa reittiä työmaat ovat."); await liiku(nauha); await odota(3000); }
      const tabs = $$("#lTabs .ltab-h button").filter(nakyy);
      if (tabs.length) { await kerro("LINJA", "Oikealla reitin työmaat, kellonajat ja ajantasausvälit."); await liiku(tabs[0]); await odota(1800);
        const kello = tabs.find(b => /Kellonaj/.test(b.textContent)); if (kello) { await klikkaa(kello, { jalkeen: 2600 }); }
        const sug = $$("#lTabs .ltab-h button").find(b => b.dataset.t === "sug" && nakyy(b));
        if (sug) { await kerro("TEKOÄLYAGENTTI", "Agentti ehdottaa aikataulumuutosta mitattujen lukujen perusteella."); await klikkaa(sug, { jalkeen: 2200 });
          const hyv = tekstinMukaan("#lTabs button", /^Hyväksy$/);
          if (hyv) { await kerro("IHMINEN PÄÄTTÄÄ", "Agentti ei muuta aikatauluja itse. Suunnittelija hyväksyy tai hylkää, ja syy kirjataan."); await liiku(hyv); await odota(3000); } }
        else { const eka = $$("#lTabs .ltab-h button").find(b => nakyy(b)); if (eka) eka.click(); }
      }
    }

    // 8. ENNAKOI
    const arv = rail('[data-nak="#/ennakko"]');
    if (arv) {
      await kerro("ENNAKOI", "Ennakkoarvio: valitse alkava lupa tai piirrä työalue kartalle, niin tutka arvioi vaikutuksen etukäteen.");
      await klikkaa(arv, { jalkeen: 2000 });
      if (typeof tpAvaaWs === "function") { tpAvaaWs("ennakko", "tyo"); tpAvaaWs("ennakko", "arvio"); }
      const sel = await odotaEl(() => { const x = $("#enLupa"); return x && x.options.length > 1 ? x : null; }, 6000);
      if (sel && nakyy(sel) && typeof valitseLupaEn === "function") {
        await liiku(sel); await odota(700); sel.value = sel.options[1].value; valitseLupaEn(sel.value); await odota(3000);
        const tulos = await odotaEl(() => $$("#enOut .enkp").find(nakyy), 6000);
        if (tulos) { await kerro("ENNAKOI", "Tulos: paljonko työ lisää ajoaikaa vuorokaudessa ja koko työn aikana, ja mitkä linjat kärsivät."); await liiku(tulos); await odota(3200);
          const rec = $$("#enOut .rec").find(nakyy); if (rec) { await kerro("ENNAKOI", "Suositus: mikä ajoitus haittaa joukkoliikennettä vähiten, ja muut työt samoilla linjoilla."); await liiku(rec); await odota(3200); } }
        const aj = rail('[data-tp="ajo"]');
        if (aj) { await kerro("ENNAKOI", "Ajoitus-paletti vertaa päivä-, ilta-, yö- ja kaksivuorotyötä."); await klikkaa(aj, { jalkeen: 1800 });
          const t = $$("#haTaul table").find(nakyy); if (t) { await liiku(t); await odota(3200); } }
      }
    }

    // 9. VALVOMO JA TIETOA
    const vm = tekstinMukaan(".top nav a", /^Valvomo/);
    if (vm) { await kerro("VALVOMO", "Valvomo: hälytykset, kun työmaa alkaa hidastaa liikennettä. Ne kuitataan, ja historia säilyy.");
      await klikkaa(vm, { jalkeen: 2200 }); const r = $$("#hList .hrow").find(nakyy) || $$("#v-halytykset h2").find(nakyy); if (r) { await liiku(r); await odota(3200); } }
    const tt = tekstinMukaan(".top nav a", /^Tietoa/);
    if (tt) { await kerro("TIETOA", "Tietoa-sivulla: miten tätä kokeiltaisiin HSL:ssä, mitä on jo löydetty ja miten tekoälyä valvotaan.");
      await klikkaa(tt, { jalkeen: 2000 }); await vieri(500, 2600); await odota(2400); await vieri(0, 1200); }
    piilotaTeksti(); await odota(300);

    await kortti("val", `${logo}<h1>Mittaa. Ennakoi. Ehdottaa.<br><em>Ihminen päättää.</em></h1><p>Avoin data · ei henkilötietoja · ${NIMI === "Työmaatutka" ? "konsepti, ei HSL:n eikä kaupungin virallinen palvelu" : "itsenäinen palvelu"}</p>`, 3600);
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

  function lopeta() { try { palautaAsettelu(); } catch (e) {} const q = $("#omaQ"), dd = $("#hakuDD"); if (q) { q.value = ""; q.blur(); } if (dd) dd.hidden = true;
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
