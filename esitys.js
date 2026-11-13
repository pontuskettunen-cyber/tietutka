/* Esittely: tervetuloikkunan "Katso miten se toimii" (window.ttOpastus) tai tallennustila osoitteella ?demo.
   Kierros käyttää sivun oikeita toimintoja: jokainen klikkaus avaa jotain. Hyväksy- ja kuittausnappeja ei paineta.
   Käyttö: avaa ?demo, käynnistä näytöntallennus, paina välilyöntiä (tai nappia). Esc keskeyttää. */
(() => {
  "use strict";
  const $ = (s, r = document) => r.querySelector(s);
  const $$ = (s, r = document) => [...r.querySelectorAll(s)];
  const TAHTI = 0.9;   // rauhallinen tahti: pitkät tauot pidemmiksi, jotta katsoja ehtii lukea ja katsoa
  // Esityksen oma kello: pysähtyy tauon ajaksi. Hyppy (toiseen kohtaan) ja Lopeta keskeyttävät odotukset.
  let seis = false, hyppy = null, tauko = false, taukoAlku = 0, taukoYht = 0;
  const aika = () => performance.now() - taukoYht - (tauko ? performance.now() - taukoAlku : 0);
  const kesken = () => seis || hyppy !== null;
  const tarkista = () => { if (seis) throw new Error("keskeytetty"); if (hyppy !== null) throw new Error("hyppy"); };
  async function odota(ms) { const kesto = ms >= 900 ? ms * TAHTI : ms, t0 = aika();
    while (aika() - t0 < kesto) { tarkista(); await new Promise(r => setTimeout(r, 40)); } tarkista(); }
  const ease = t => t < .5 ? 4 * t * t * t : 1 - Math.pow(-2 * t + 2, 3) / 2;

  /* ---------- tyylit ja peite-elementit ---------- */
  const css = document.createElement("style");
  css.textContent = `
  html.esitys.es-hiljaa, html.esitys.es-hiljaa *{cursor:none !important}
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
    const pohja = (!palkki || document.documentElement.classList.contains("es-hiljaa")) ? 34 : 84, h = teksti.offsetHeight || 90, ala = innerHeight - pohja - h - 12;
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
    return new Promise(res => { const t0 = aika();
      const askel = t => { if (kesken()) return res(); const q = Math.min(1, (aika() - t0) / kesto), e = ease(q), b = Math.sin(Math.PI * e) * kaari;
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
    return new Promise(res => { const t0 = aika();
      const askel = t => { if (kesken()) return res(); const q = Math.min(1, (aika() - t0) / kesto); kohde.scrollTop = y0 + dy * ease(q); q < 1 ? requestAnimationFrame(askel) : res(); };
      requestAnimationFrame(askel); });
  }
  const sisaY = (kont, el, vara = 20) => kont.scrollTop + el.getBoundingClientRect().top - kont.getBoundingClientRect().top - vara;
  const sivunY = (el, vara = 96) => Math.max(0, el.getBoundingClientRect().top + scrollY - vara);
  async function odotaEl(fn, ms = 9000) { const t0 = Date.now(); for (;;) { tarkista(); const v = fn(); if (v) return v; if (Date.now() - t0 > ms) return null; await odota(120); } }
  const tekstinMukaan = (sel, re) => $$(sel).find(e => re.test(e.textContent.trim()) && e.getBoundingClientRect().height > 0);

  /* ---------- kuvatekstit ja kortit ---------- */
  async function kerro(tag, t, ylos = false) {
    if (teksti.classList.contains("on")) { teksti.classList.remove("on"); await odota(450); }
    const n = LUVUT.findIndex(l => l.t === tag);
    teksti.innerHTML = `<i>${tag}${n >= 0 ? `<small>${n + 1} / ${LUVUT.length}</small>` : ""}</i><span>${t}</span>`;
    teksti.classList.add("on"); hamaru.classList.add("on"); sijoitaTeksti();
    await odota(800 + t.length * 30);   // lukuaika ennen kuin jotain tapahtuu
  }
  const piilotaTeksti = () => { teksti.classList.remove("on"); hamaru.classList.remove("on"); poistaKorostus(); };
  async function kortti(luokka, html, kesto) {
    const k = document.createElement("div"); k.className = "es-kortti " + luokka; k.innerHTML = html; document.body.appendChild(k);
    try { await odota(30); k.classList.add("on"); await odota(kesto); k.classList.remove("on"); await odota(750); } finally { k.remove(); }
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
    await new Promise(res => { const t0 = aika(), kesto = 1300;
      const askel = t => { if (kesken()) return res(); const q = Math.min(1, (aika() - t0) / kesto), e = ease(q);
        el.style.left = (x0 + dx * e) + "px"; el.style.top = (y0 + dy * e) + "px"; aseta(kx0 + dx * e, ky0 + dy * e);
        q < 1 ? requestAnimationFrame(askel) : res(); }; requestAnimationFrame(askel); });
    el.classList.remove("raahaa"); kursori.classList.remove("painuu");
  }
  // koon muutos oikeasta alakulmasta
  async function venyta(el, dw, dh) {
    const b = el.getBoundingClientRect();
    await liiku({ x: b.right - 8, y: b.bottom - 8 }); await odota(300); kursori.classList.add("painuu");
    const w0 = el.offsetWidth, h0 = el.offsetHeight, kx0 = kx, ky0 = ky;
    await new Promise(res => { const t0 = aika(), kesto = 1200;
      const askel = t => { if (kesken()) return res(); const q = Math.min(1, (aika() - t0) / kesto), e = ease(q);
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

  /* ---------- luvut: jokainen alkaa omasta lähtötilastaan, joten niihin voi hypätä ---------- */
  async function naytto(h) { if (location.hash !== h) { location.hash = h; await odota(1000); } }
  const Y = {};   // kierroksen yhteiset tiedot (valittu työmaa ja linja)
  let pinnattu = null;
  function siivoa() {
    piilotaTeksti(); poistaKorostus(); $$(".es-kortti, #esKansi").forEach(k => k.remove());
    const q = $("#omaQ"), dd = $("#hakuDD"); if (q) { q.value = ""; q.blur(); } if (dd) dd.hidden = true;
    try { if (pinnattu && LV.pinned.has(pinnattu)) togglePin(pinnattu); } catch (e) {} pinnattu = null;
    try { if (typeof hLinjaPois === "function") hLinjaPois(true); } catch (e) {}
  }
  const LUVUT = [
    { t: "TILANNE", nimi: "Tilanne nyt", s: 26, f: async () => {
      await naytto("#/");
      const palauta = rail('[data-tp="palauta"]'); if (palauta) palauta.click(); await odota(300);
      if (Y.kansi) Y.kansi = false; else await kortti("sin", `${logo}<h1>Mitä katutyöt maksavat<br>joukkoliikenteelle?</h1><p>Esittely noin kolmessa minuutissa · oikea data tältä päivältä</p>`, 2600);
      const til = ws("tilanne");
      await kerro("TILANNE", "Tutka on yksi kartta ja sen päällä paletteja. Tilanne nyt kertoo, mikä työ hidastaa eniten ja paljonko lisäaikaa syntyy vuorokaudessa.");
      const kpi = til && til.querySelector("#kpis [data-bd]"); if (kpi) { await liiku(kpi); await odota(1800); }
      const r0 = $$(".tp-rail").find(nakyy);
      if (r0) { await kerro("TILANNE", "Vasemmasta työkalupalkista vaihdetaan näkymää, avataan paletteja ja kytketään karttatasoja."); await liiku(r0); await odota(1600); }
    } },
    { t: "PALETIT", nimi: "Paletit", s: 22, f: async () => {
      await naytto("#/");
      const til = ws("tilanne"); if (!til || !nakyy(til)) return;
      await kerro("PALETIT", "Paletin voi raahata otsikosta, venyttää kulmasta ja pienentää viivasta. Palauta vie kaiken takaisin.");
      await raahaa(til, 200, 50); await venyta(til, 80, -110);
      const mn = til.querySelector(".tp-min"); if (mn) { await klikkaa(mn, { jalkeen: 900 }); const ph = ws("tilanne") && ws("tilanne").querySelector(".tp-ph"); if (ph) await klikkaa(ph, { jalkeen: 900 }); }
      const pal = rail('[data-tp="palauta"]'); if (pal) await klikkaa(pal, { jalkeen: 1200 });
    } },
    { t: "LIVE", nimi: "Live", s: 28, f: async () => {
      await naytto("#/");
      const m = typeof M !== "undefined" && M.home; if (!m || typeof LV === "undefined") return;
      const lv = rail('[data-ker="live"]'); if (lv && !LV.on) lv.click();
      const c = Y.l1 && Y.l1.geom && typeof centroid === "function" ? centroid(Y.l1.geom) : null;
      if (c) m.flyTo(c, 16, { duration: 2 });
      await kerro("LIVE", "Live: jokainen bussi (sininen) ja ratikka (vihreä) liikkuu kartalla. Keltainen reunus = auto on työmaalla juuri nyt, harmaa = seisoo.");
      await odotaEl(() => [...LV.veh.values()].some(v => keskelle(m, [v.lat, v.lon])), 6000);
      await odota(1500);
      const ehd = [...LV.veh.entries()].filter(([, v]) => keskelle(m, [v.lat, v.lon]) && typeof vTila === "function" && vTila(v).k !== "seis");
      const val = ehd.find(([, v]) => typeof nearSite === "function" && nearSite(v.lat, v.lon)) || ehd[0];
      if (!val) return;
      const [id, v] = val, p = ruutu(m, [v.lat, v.lon]);
      await kerro("LIVE", "Klikkaa autoa: linja, myöhästyminen ja työmaa, jonka kohdalla se on.");
      await liiku(p); korosta({ left: p.x - 16, top: p.y - 16, right: p.x + 16, bottom: p.y + 16, width: 32, height: 32 });
      kursori.classList.add("painuu"); const rr = document.createElement("div"); rr.className = "es-rengas"; rr.style.left = p.x + "px"; rr.style.top = p.y + "px";
      document.body.appendChild(rr); setTimeout(() => rr.remove(), 800); await odota(140); kursori.classList.remove("painuu");
      if (typeof togglePin === "function") { togglePin(id); pinnattu = id; } poistaKorostus(); await odota(3600);
      siivoa();
    } },
    { t: "TYÖMAA", nimi: "Työmaa", s: 22, f: async () => {
      await naytto("#/");
      const l1 = Y.l1, m = typeof M !== "undefined" && M.home; if (!l1 || typeof select !== "function") return;
      const c = typeof centroid === "function" ? centroid(l1.geom) : null;
      if (c && m) { m.setView(c, Math.max(m.getZoom(), 14)); await odota(300); const p = ruutu(m, c); await liiku(p); kursori.classList.add("painuu"); await odota(140); kursori.classList.remove("painuu"); }
      select(l1.lupa_id, false); await odota(1200);
      const f = await odotaEl(() => $$("#detail .facts > div").find(nakyy), 4000);
      if (f) { const im = typeof impact === "function" ? impact(l1) : null;
        await kerro("TYÖMAA", "Klikkaa työmaata: lisäaika jokaista ohi ajavaa bussia kohden. " + (im && im.tod ? "Mitattu = sama katu ilman töitä vs. työn aikana." : "Harmaa luku on arvio, joka mitataan työn päätyttyä."));
        await liiku(f); await odota(1800); }
      const siru = $$("#detail .lsiru").find(nakyy);
      if (siru) { await kerro("TYÖMAA", "Linjan numerosta reitti ja sen kaikki työmaat kartalle."); await klikkaa(siru, { jalkeen: 2200 }); siivoa(); }
    } },
    { t: "LINJA", nimi: "Linja", s: 28, f: async () => {
      await naytto("#/");
      const q = $("#omaQ");
      if (q && nakyy(q)) {
        await kerro("LINJA", "Haku löytää linjat, kadut ja luvat.");
        await klikkaa(q, { jalkeen: 300 }); await kirjoita(q, Y.linja); await odota(900);
        const eka = await odotaEl(() => $$("#hakuDD .hk").find(nakyy), 3000);
        if (eka) await klikkaa(eka, { alas: true, jalkeen: 1800 }); else { q.value = ""; await naytto("#/linjat"); }
      }
      if (!location.hash.startsWith("#/linjat")) return;
      const k = await odotaEl(() => $$("#lCock .lc-k").find(nakyy), 5000);
      if (k) { await kerro("LINJA", "Linjan ohjaamo: tavallinen vuoro, huonoimmat vuorot ja mahtuuko lisäaika aikataulun viivevaraan. Oikealla reitin työmaat.");
        await liiku(k); await odota(1600); }
      const sug = $$("#lTabs .ltab-h button").find(b => b.dataset.t === "sug" && nakyy(b));
      if (sug) { await kerro("LINJA", "Tekoälyagentti ehdottaa aikataulumuutosta. Ihminen hyväksyy tai hylkää."); await klikkaa(sug, { jalkeen: 2200 }); }
    } },
    { t: "ENNAKOI", nimi: "Ennakkoarvio", s: 25, f: async () => {
      if (!$$(".tp-rail").find(nakyy)) await naytto("#/");
      const arv = rail('[data-nak="#/ennakko"]'); if (!arv) return;
      await kerro("ENNAKOI", "Ennakkoarvio: valitse alkava lupa tai piirrä työalue, niin tutka arvioi vaikutuksen etukäteen.");
      await klikkaa(arv, { jalkeen: 1500 });
      if (typeof tpAvaaWs === "function") { tpAvaaWs("ennakko", "tyo"); tpAvaaWs("ennakko", "arvio"); }
      const sel = await odotaEl(() => { const x = $("#enLupa"); return x && x.options.length > 1 ? x : null; }, 6000);
      if (!(sel && nakyy(sel) && typeof valitseLupaEn === "function")) return;
      await liiku(sel); sel.value = sel.options[1].value; valitseLupaEn(sel.value); await odota(2200);
      const rec = await odotaEl(() => $$("#enOut .rec").find(nakyy), 6000);
      if (rec) { await kerro("ENNAKOI", "Tulos: lisäaika, kärsivät linjat ja ajoitus, joka haittaa joukkoliikennettä vähiten."); await liiku(rec); await odota(2000); }
    } },
    { t: "VALVOMO", nimi: "Valvomo", s: 20, f: async () => {
      const vm = tekstinMukaan(".top nav a", /^Valvomo/);
      if (vm) { piilotaTeksti(); await klikkaa(vm, { jalkeen: 1200 });
        await kerro("VALVOMO", "Valvomo hälyttää, kun työmaa alkaa hidastaa liikennettä. Tietoa-sivulla menetelmä ja miten tätä kokeiltaisiin HSL:ssä.");
        const r = $$("#hList .hrow").find(nakyy); if (r) await liiku(r); await odota(1800); }
      piilotaTeksti(); await odota(200);
      await kortti("val", `${logo}<h1>Mittaa. Ennakoi. Ehdottaa.<br><em>Ihminen päättää.</em></h1><p>Avoin data · ei henkilötietoja · ${NIMI === "Työmaatutka" ? "konsepti, ei HSL:n eikä kaupungin virallinen palvelu" : "itsenäinen palvelu"}</p>`, 3000);
    } },
  ];
  const VAIHEET = LUVUT.map(l => l.t);
  const KOKO = LUVUT.reduce((a, l) => a + l.s, 0);
  let luku = 0, lukuAlku = 0;

  async function kierros(alku = 0) {
    document.documentElement.classList.add("esitys");
    tallennaAsettelu();
    await odotaEl(() => typeof S !== "undefined" && S.loaded, 30000);
    await naytto("#/"); await odota(300);
    const k1 = $$("#cards .card").find(nakyy);
    Y.l1 = k1 && S.byId ? S.byId[k1.dataset.id] : null;
    Y.linja = (Y.l1 && typeof lines === "function" && lines(Y.l1.linjat).find(n => !/N$/.test(n))) || "55";
    // aloituskortti näkyi jo klikkauksesta asti: valmistelut tehtiin sen takana, nyt se häivytetään
    const kansi = $("#esKansi");
    if (kansi) { if (alku === 0) { const p = $('.tp-rail [data-tp="palauta"]'); if (p) p.click(); Y.kansi = true; }
      try { await odota(2200); kansi.style.opacity = "0"; await odota(700); } finally { kansi.remove(); } }
    luku = alku;
    while (luku < LUVUT.length) {
      lukuAlku = aika(); paivitaPalkki();
      try { await LUVUT[luku].f(); luku++; }
      catch (e) { if (e.message !== "hyppy") throw e; const k = hyppy; hyppy = null; siivoa(); luku = Math.max(0, Math.min(LUVUT.length - 1, k)); }
    }
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

  /* ---------- soitinpalkki: edistyminen kohdittain, tauko, kelaus kohtaan, lopetus ---------- */
  const mmss = sek => `${Math.floor(sek / 60)}:${String(Math.floor(sek % 60)).padStart(2, "0")}`;
  let palkki = null, pallo = null, vihje = null, hiiriAjastin = 0;
  function paivitaPalkki() {
    if (!palkki) return;
    const kulunut = Math.min(LUVUT[luku] ? LUVUT[luku].s : 0, Math.max(0, (aika() - lukuAlku) / 1000));
    LUVUT.forEach((l, i) => { const t = palkki.querySelector(`.es-seg[data-i="${i}"] b`); if (t) t.style.width = (i < luku ? 100 : i > luku ? 0 : Math.min(100, kulunut / l.s * 100)) + "%"; });
    const ennen = LUVUT.slice(0, luku).reduce((a, l) => a + l.s, 0) + kulunut;
    if (!palkki.classList.contains("raahaa")) pallo.style.left = (ennen / KOKO * 100) + "%";
    palkki.querySelector(".es-aika").textContent = `${mmss(ennen)} / ${mmss(KOKO)}`;
    palkki.querySelector(".es-luku").textContent = LUVUT[luku] ? `${LUVUT[luku].nimi} · ${luku + 1}/${LUVUT.length}` : "";
    palkki.querySelector(".es-play").innerHTML = tauko ? "▶" : "❚❚";
    palkki.querySelector(".es-play").setAttribute("aria-label", tauko ? "Jatka" : "Tauko");
  }
  const kohtaan = x => { const r = palkki.querySelector(".es-rata").getBoundingClientRect(), f = Math.max(0, Math.min(.999, (x - r.left) / r.width));
    let kertyma = 0; for (let i = 0; i < LUVUT.length; i++) { kertyma += LUVUT[i].s; if (f * KOKO < kertyma) return { i, f }; } return { i: LUVUT.length - 1, f }; };
  const hyppaa = i => { if (i < 0 || i >= LUVUT.length) return; if (tauko) asetaTauko(false); hyppy = i; };
  function asetaTauko(on) { if (on === tauko) return; if (on) taukoAlku = performance.now(); else taukoYht += performance.now() - taukoAlku; tauko = on;
    document.documentElement.classList.toggle("es-tauolla", on); paivitaPalkki(); }
  function hiiriLiikkui() { document.documentElement.classList.remove("es-hiljaa"); clearTimeout(hiiriAjastin);
    hiiriAjastin = setTimeout(() => { if (!tauko && !(palkki && palkki.matches(":hover"))) document.documentElement.classList.add("es-hiljaa"); }, 2600); }
  function luoPalkki() {
    palkki = document.createElement("div"); palkki.className = "es-palkki";
    palkki.innerHTML = `<div class="es-rata" role="slider" aria-label="Esittelyn kohta" tabindex="0">${LUVUT.map((l, i) => `<div class="es-seg" data-i="${i}" style="flex:${l.s}"><b></b></div>`).join("")}<span class="es-pallo"></span><span class="es-vihje" hidden></span></div>
      <div class="es-ohj"><button type="button" class="es-play" aria-label="Tauko">❚❚</button><button type="button" class="es-ed" aria-label="Edellinen kohta">⏮</button><button type="button" class="es-seur" aria-label="Seuraava kohta">⏭</button>
      <span class="es-aika"></span><span class="es-luku"></span><span class="es-tyhja"></span><button type="button" class="es-lop">Lopeta ✕</button></div>`;
    document.body.appendChild(palkki);
    pallo = palkki.querySelector(".es-pallo"); vihje = palkki.querySelector(".es-vihje");
    palkki.querySelector(".es-play").onclick = () => asetaTauko(!tauko);
    palkki.querySelector(".es-ed").onclick = () => hyppaa((aika() - lukuAlku > 4000) ? luku : luku - 1);
    palkki.querySelector(".es-seur").onclick = () => hyppaa(luku + 1);
    palkki.querySelector(".es-lop").onclick = () => { seis = true; asetaTauko(false); };
    const rata = palkki.querySelector(".es-rata");
    const nayta = e => { const k = kohtaan(e.clientX), r = rata.getBoundingClientRect(); vihje.hidden = false; vihje.textContent = `${k.i + 1}. ${LUVUT[k.i].nimi}`; vihje.style.left = (e.clientX - r.left) + "px"; return k; };
    rata.addEventListener("pointermove", e => { nayta(e); if (palkki.classList.contains("raahaa")) pallo.style.left = (kohtaan(e.clientX).f * 100) + "%"; });
    rata.addEventListener("pointerleave", () => { if (!palkki.classList.contains("raahaa")) vihje.hidden = true; });
    rata.addEventListener("pointerdown", e => { e.preventDefault(); try { rata.setPointerCapture(e.pointerId); } catch (x) {} palkki.classList.add("raahaa"); pallo.style.left = (kohtaan(e.clientX).f * 100) + "%"; nayta(e); });
    rata.addEventListener("pointerup", e => { if (!palkki.classList.contains("raahaa")) return; palkki.classList.remove("raahaa"); vihje.hidden = true; const k = kohtaan(e.clientX); if (k.i !== luku || aika() - lukuAlku > 3000) hyppaa(k.i); else paivitaPalkki(); });
    rata.addEventListener("keydown", e => { if (e.key === "ArrowRight") { e.preventDefault(); hyppaa(luku + 1); } if (e.key === "ArrowLeft") { e.preventDefault(); hyppaa(luku - 1); } });
  }
  const css2 = document.createElement("style");
  css2.textContent = `.es-suoja{position:fixed;inset:0;z-index:99990}
  html.esitys.es-hiljaa .es-suoja, html.esitys.es-hiljaa .es-suoja *{cursor:none!important}
  html.esitys:not(.es-hiljaa) .es-suoja{cursor:default!important}
  .es-palkki{position:fixed;left:0;right:0;bottom:0;z-index:100004;padding:10px 18px 10px;background:linear-gradient(to top,rgba(8,14,26,.92),rgba(8,14,26,.78));color:#fff;font:600 14px Nunito,system-ui,sans-serif;transition:transform .35s, opacity .35s}
  .es-palkki, .es-palkki *{cursor:pointer!important}
  .es-rata{position:relative;display:flex;gap:3px;height:16px;align-items:center;margin:0 0 6px;outline:none}
  .es-seg{position:relative;height:4px;background:rgba(255,255,255,.28);border-radius:1px;transition:height .15s}
  .es-seg b{position:absolute;left:0;top:0;bottom:0;width:0;background:#E5322D;border-radius:1px}
  .es-rata:hover .es-seg, .es-palkki.raahaa .es-seg{height:7px}
  .es-pallo{position:absolute;top:50%;width:14px;height:14px;margin:-7px 0 0 -7px;border-radius:50%;background:#E5322D;transform:scale(0);transition:transform .15s}
  .es-rata:hover .es-pallo, .es-palkki.raahaa .es-pallo{transform:scale(1)}
  .es-vihje{position:absolute;bottom:22px;transform:translateX(-50%);white-space:nowrap;background:#0F1B2D;border:1px solid rgba(255,255,255,.15);padding:5px 9px;border-radius:6px;font:700 13px Nunito,system-ui;pointer-events:none}
  .es-ohj{display:flex;align-items:center;gap:6px}
  .es-ohj button{background:none;border:0;color:#fff;font:700 16px Nunito,system-ui;padding:4px 9px;border-radius:6px;min-width:36px}
  .es-ohj button:hover{background:rgba(255,255,255,.12)}
  .es-ohj .es-lop{font-size:14px}
  .es-aika{margin-left:8px;font-variant-numeric:tabular-nums;opacity:.9}.es-luku{margin-left:14px;opacity:.75}.es-tyhja{flex:1}
  html.es-hiljaa .es-palkki{transform:translateY(calc(100% - 6px));background:transparent}
  html.es-hiljaa .es-palkki .es-ohj{opacity:0}
  html.esitys .es-teksti{bottom:84px} html.esitys .es-teksti.ylos{bottom:auto}
  html.es-hiljaa .es-teksti{bottom:34px} html.es-hiljaa .es-teksti.ylos{bottom:auto}`;
  document.head.appendChild(css2);

  // Opastus tervetuloikkunasta: läpinäkyvä suoja estää vahinkoklikkaukset sivulla; ohjaus palkista tai näppäimillä.
  window.ttOpastus = async () => {
    if (document.documentElement.classList.contains("esitys")) return;
    seis = false; hyppy = null; tauko = false; taukoYht = 0;
    const suoja = document.createElement("div"); suoja.className = "es-suoja";
    suoja.addEventListener("click", () => asetaTauko(!tauko));   // klikkaus kuvaan = tauko, kuten videossa
    document.body.appendChild(suoja); luoPalkki();
    addEventListener("mousemove", hiiriLiikkui); hiiriLiikkui();
    const ajastin = setInterval(paivitaPalkki, 250);
    try { await kierros(); } catch (e) { if (e.message !== "keskeytetty") console.warn("Esittely:", e.message); siivoa(); lopeta(); if (location.hash !== "#/") location.hash = "#/"; }
    clearInterval(ajastin); removeEventListener("mousemove", hiiriLiikkui);
    suoja.remove(); if (palkki) { palkki.remove(); palkki = null; }
    document.documentElement.classList.remove("es-hiljaa", "es-tauolla");
  };
  addEventListener("keydown", e => {
    if (!document.documentElement.classList.contains("esitys") || !palkki) return;
    if (e.key === "Escape") { seis = true; asetaTauko(false); }
    else if (e.key === " " || e.code === "Space") { e.preventDefault(); asetaTauko(!tauko); }
    else if (e.key === "ArrowRight") { e.preventDefault(); hyppaa(luku + 1); }
    else if (e.key === "ArrowLeft") { e.preventDefault(); hyppaa((aika() - lukuAlku > 4000) ? luku : luku - 1); }
  });
  if (!new URLSearchParams(location.search).has("demo")) return;

  // ?demo: tallennustila ilman palkkia (näytöntallennusta varten)
  const alku = document.createElement("div"); alku.className = "es-alku";
  alku.innerHTML = `<div><button type="button" disabled>Ladataan tietoja…</button><p>Käynnistä ensin näytöntallennus. Älä liikuta hiirtä esityksen aikana. Välilyönti käynnistää, Esc keskeyttää.</p></div>`;
  document.body.appendChild(alku);
  let valmis = false;
  (async () => { while (!(typeof S !== "undefined" && S.loaded)) await new Promise(r => setTimeout(r, 200)); await new Promise(r => setTimeout(r, 1500)); valmis = true;
    const b = alku.querySelector("button"); b.disabled = false; b.textContent = "▶ Käynnistä esitys"; })();
  const kaynnista = async () => { if (!alku.isConnected || !valmis) return; alku.remove(); document.documentElement.classList.add("es-hiljaa"); await new Promise(r => setTimeout(r, 400));
    try { await kierros(); } catch (e) { console.warn("Esitys:", e.message); lopeta(); } };
  alku.querySelector("button").onclick = kaynnista;
  addEventListener("keydown", e => { if (e.code === "Space" && alku.isConnected) { e.preventDefault(); kaynnista(); } if (e.key === "Escape") seis = true; });
})();
