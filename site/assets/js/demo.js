/* The hero demo: Benito with sample data. State lives in memory only, nothing goes over the network, and a
   reload starts over. One store holds today's events; Home and Timeline totals are derived from it. Timers store
   when the running stretch began plus the time already banked, and every paint reads the clock. Nothing counts
   ticks, so tab switches, scroll, busy threads and background tabs cannot make a timer drift. */
(function () {
  var app = document.querySelector("[data-demo]");
  if (!app) return;
  var MIN = 60000;
  var mono = function () { return performance.now(); };
  var wall = function () { return Date.now(); };
  var $ = function (k) { return app.querySelector('[data-d="' + k + '"]'); };
  var each = function (sel, fn) { app.querySelectorAll(sel).forEach(fn); };
  var t0 = wall(), nid = 0;
  function seed(o, ago, by) { o.id = ++nid; o.at = t0 - ago * MIN; o.by = by || "Alex"; return o; }
  /* Since 12 AM, matching Home: 6 feeds (4 nursing, 1h 9m; 2 bottles, 6.5 oz), 4 diapers, 7h 40m of sleep. */
  var E = [
    seed({ kind: "nursing", dur: 20 * MIN, L: 12 * MIN, R: 8 * MIN, side: "R" }, 860),
    seed({ kind: "sleep", dur: 300 * MIN }, 840),
    seed({ kind: "nursing", dur: 17 * MIN, L: 9 * MIN, R: 8 * MIN, side: "L" }, 535, "You"),
    seed({ kind: "diaper", sub: "Wet" }, 530, "You"),
    seed({ kind: "med", name: "Vitamin D", dose: "1 ml" }, 520, "You"),
    seed({ kind: "nursing", dur: 15 * MIN, L: 0, R: 15 * MIN, side: "R" }, 440),
    seed({ kind: "sleep", dur: 90 * MIN }, 420),
    seed({ kind: "diaper", sub: "Dirty" }, 320),
    seed({ kind: "bottle", oz: 3 }, 300),
    seed({ kind: "nursing", dur: 17 * MIN, L: 10 * MIN, R: 7 * MIN, side: "L" }, 250, "You"),
    seed({ kind: "diaper", sub: "Wet" }, 230, "You"),
    seed({ kind: "sleep", dur: 70 * MIN }, 204),
    seed({ kind: "bottle", oz: 3.5 }, 109),
    seed({ kind: "diaper", sub: "Both" }, 84),
    seed({ kind: "walk", dur: 25 * MIN }, 70, "You")
  ];
  /* The six days before today, generated from a fixed seed so every visit shows the same week: night sleeps with
     feeds between them, naps, diapers, a daily vitamin, some walks, the odd pump and evening cry. */
  var d0 = new Date(t0); d0.setHours(0, 0, 0, 0);
  var midnight = d0.getTime();
  function dayAt(i) { var d = new Date(midnight); d.setDate(d.getDate() + i); return d.getTime(); }
  var W = (function () {
    var r = 11, out = [], t = dayAt(-6) - 150 * MIN, end = E[0].at - 10 * MIN, med = {}, n, h, night, l;
    function rnd(a, b) { r = r * 16807 % 2147483647; return a + r % (b - a + 1); }
    function push(o, at) { if (at < end) { o.id = ++nid; o.at = at; o.by = rnd(0, 2) ? "Alex" : "You"; out.push(o); } }
    while (t < end) {
      h = new Date(t).getHours(); night = h >= 19 || h < 6;
      if (rnd(0, 9) < (night ? 9 : 7)) { n = rnd(12, 24) * MIN; l = Math.min(n, rnd(4, 12) * MIN); push({ kind: "nursing", dur: n, L: l, R: n - l, side: rnd(0, 1) ? "L" : "R" }, t); }
      else { n = 10 * MIN; push({ kind: "bottle", oz: [2.5, 3, 3.5, 4][rnd(0, 3)] }, t); }
      t += n + 5 * MIN;
      if (rnd(0, 9) < (night ? 4 : 7)) push({ kind: "diaper", sub: ["Wet", "Wet", "Dirty", "Both"][rnd(0, 3)] }, t);
      if (h >= 8 && !night && !med[new Date(t).getDate()]) { med[new Date(t).getDate()] = 1; push({ kind: "med", name: "Vitamin D", dose: "1 ml" }, t + 10 * MIN); }
      if (night) {
        if (h >= 19 && h < 21 && !rnd(0, 2)) { n = rnd(10, 25) * MIN; push({ kind: "cry", dur: n }, t); t += n; }
        n = rnd(120, 220) * MIN;
      } else {
        if (h >= 9 && h < 17 && !rnd(0, 2)) push({ kind: "walk", dur: rnd(20, 45) * MIN }, t + 20 * MIN);
        if (!rnd(0, 5)) push({ kind: "pump", side: "Both", oz: "4 oz" }, t + 50 * MIN);
        t += rnd(70, 140) * MIN; n = rnd(35, 110) * MIN;
      }
      push({ kind: "sleep", dur: Math.min(n, end - t) }, t); t += n;
    }
    return out;
  })();
  var S = { tab: "home", view: "day", timer: null, tkind: "walk", mode: "nursing", oz: 4, ago: 0,
    pside: "Both", poz: "4 oz", mname: "Vitamin D", mdose: "1 ml", ev: null, ver: 0, sheet: null, opener: null };
  var SIDE = { L: "Left", R: "Right" };
  var K = { sleep: ["Sleep", "#i-moon", "Sleeping"], walk: ["Walk", "#i-walk", "Walk"], ride: ["Car ride", "#i-car", "Car ride"], cry: ["Crying", "#i-cry", "Crying"] };
  var EV = { nursing: ["Nursing", "#i-drop", "feed"], bottle: ["Bottle", "#i-drop", "bottle"], diaper: ["Diaper", "#i-diaper", "diaper"],
    sleep: ["Sleep", "#i-moon", "sleep"], walk: ["Walk", "#i-walk", "walk"], ride: ["Car ride", "#i-car", "walk"], cry: ["Crying", "#i-cry", "cry"],
    pump: ["Pump", "#i-pump", "pump"], med: ["Medicine", "#i-med", "med"] };

  function totals() {
    var T = { feeds: 0, nurse: 0, oz: 0, diapers: 0, sleep: 0, cry: 0, last: null, diaper: null, wake: 0 };
    E.forEach(function (e) {
      var k = e.kind;
      if (k === "nursing" || k === "bottle") { T.feeds++; if (k === "bottle") T.oz += e.oz; else T.nurse += e.dur; if (!T.last || e.at > T.last.at) T.last = e; }
      else if (k === "diaper") { T.diapers++; if (!T.diaper || e.at > T.diaper.at) T.diaper = e; }
      else if (k === "sleep") { T.sleep += e.dur; T.wake = Math.max(T.wake, e.at + e.dur); }
      else if (k === "cry") T.cry += e.dur;
    });
    return T;
  }
  var T = totals();
  function add(o) { o.id = ++nid; o.at = o.at || wall(); o.by = "You"; E.push(o); S.ver++; T = totals(); }

  /* ---- time ---- */
  function elapsed(t, at) { return t.acc + (t.seg === null ? 0 : at - t.seg); }
  function sideMs(t, s, at) { return t.sides[s] + (t.seg !== null && t.side === s ? at - t.seg : 0); }
  function bank(t) { var at = mono(), d = at - t.seg; t.acc += d; if (t.side) t.sides[t.side] += d; t.seg = null; }
  function p2(n) { return (n < 10 ? "0" : "") + n; }
  function clock(ms) { var s = Math.floor(ms / 1000), h = Math.floor(s / 3600), m = Math.floor(s / 60) % 60; return (h ? h + ":" + p2(m) : p2(m)) + ":" + p2(s % 60); }
  function hm(ms) { var m = Math.max(0, Math.floor(ms / MIN)), h = Math.floor(m / 60); return h ? h + "h " + (m % 60) + "m" : m + "m"; }
  function dur(ms) { return ms < MIN ? Math.floor(ms / 1000) + "s" : hm(ms); }
  function spoken(ms) {
    var s = Math.floor(ms / 1000), h = Math.floor(s / 3600), m = Math.floor(s / 60) % 60, x = s % 60, out = [];
    if (h) out.push(h + (h > 1 ? " hours" : " hour"));
    if (m) out.push(m + (m > 1 ? " minutes" : " minute"));
    if (!h && (x || !m)) out.push(x + (x === 1 ? " second" : " seconds"));
    return out.join(" ");
  }
  function tm(at) { return new Date(at).toLocaleTimeString("en-US", { hour: "numeric", minute: "2-digit" }); }
  function today(at) {
    var d = at >= midnight ? "Today" : at >= dayAt(-1) ? "Yesterday" : new Date(at).toLocaleDateString("en-US", { weekday: "short", month: "short", day: "numeric" });
    return d + ", " + tm(at);
  }
  function detail(e) {
    var k = e.kind;
    return k === "nursing" ? "L " + dur(e.L) + " · R " + dur(e.R) : k === "bottle" ? e.oz + " oz" : k === "diaper" ? e.sub
      : k === "pump" ? e.side + " · " + e.oz : k === "med" ? e.name + " · " + e.dose : dur(e.dur);
  }

  /* ---- paint: text only, written only when the string changes, no layout reads ---- */
  var els = {};
  "clock since diaperago awake bartime fh fm fs tL tR stime".split(" ").forEach(function (k) { els[k] = $(k); });
  function put(el, s) { if (el && el._v !== s) { el._v = s; el.textContent = s; } }
  function paint() {
    var w = wall(), at = mono(), t = S.timer, d = new Date(w), L = T.last;
    put(els.clock, ((d.getHours() + 11) % 12 + 1) + ":" + p2(d.getMinutes()));
    put(els.since, L ? hm(w - L.at) : "None");
    put(els.diaperago, T.diaper ? hm(w - T.diaper.at) : "None");
    put(els.awake, t && t.kind === "sleep" ? hm(elapsed(t, at)) : T.wake ? hm(w - T.wake) : "None");
    var e = t ? elapsed(t, at) : 0, s = Math.floor(e / 1000), f = t && t.kind === "feed";
    put(els.bartime, clock(e));
    put(els.fh, p2(f ? Math.floor(s / 3600) : 0)); put(els.fm, p2(f ? Math.floor(s / 60) % 60 : 0)); put(els.fs, p2(f ? s % 60 : 0));
    put(els.tL, clock(f ? sideMs(t, "L", at) : 0)); put(els.tR, clock(f ? sideMs(t, "R", at) : 0));
    put(els.stime, clock(t && !f ? e : 0));
    if (S.tab === "timeline" && S.view === "week") tick(w);
  }

  /* One timeout per displayed second, aimed just past the moment the shown second changes. */
  var tid = 0, onScreen = true;
  function loop() {
    clearTimeout(tid);
    paint();
    if (!onScreen || document.hidden) return;
    var t = S.timer, delay = t && t.seg !== null ? 1000 - (elapsed(t, mono()) % 1000) : 1000 - (wall() % 1000);
    tid = setTimeout(loop, delay + 8);
  }
  document.addEventListener("visibilitychange", loop);
  if ("IntersectionObserver" in window) new IntersectionObserver(function (es) { onScreen = es[0].isIntersecting; loop(); }).observe(app);

  /* ---- timeline list: rebuilt only when the events or the view change ---- */
  var drawn = "";
  function draw() {
    if (S.view === "week") return week();
    var key = S.ver + S.view; if (key === drawn) return; drawn = key;
    var ul = $("events"); ul.textContent = "";
    E.slice().sort(function (a, b) { return b.at - a.at; }).forEach(function (e) {
      var m = EV[e.kind], li = document.createElement("li"), b = document.createElement("button");
      b.type = "button"; b.className = "app__ev"; b.setAttribute("data-act", "event"); b.setAttribute("data-id", e.id); b.setAttribute("data-kind", m[2]);
      b.innerHTML = '<span class="app__coin" aria-hidden="true"><svg><use href="' + m[1] + '"/></svg></span><span class="app__rt"><b></b><small></small></span><span class="app__evtime num"></span>';
      b.querySelector("b").textContent = m[0];
      b.querySelector("small").textContent = detail(e) + (e.kind === "nursing" ? " · " + dur(e.dur) : "");
      b.querySelector(".app__evtime").textContent = tm(e.at);
      li.appendChild(b); ul.appendChild(li);
    });
    $("empty").hidden = E.length > 0;
  }

  /* ---- week grid, after the app's TimelineWeekView: a rolling 7 days ending today, one block per event per day,
     overlaps packed side by side, instants stretched to 15 minutes so they stay tappable, the running timer as an
     open dashed block that grows to now. Blocks are buttons with one tab stop; arrow keys move between them. ---- */
  var HH = 44, wkDrawn = "", rove = "", runEl = null, nowEl = null;
  var mins = function (at) { var d = new Date(at); return d.getHours() * 60 + d.getMinutes() + d.getSeconds() / 60; };
  var px = function (m) { return m * HH / 60; };
  var fmt = function (at, o) { return new Date(at).toLocaleDateString("en-US", o); };
  function oz(e) { return typeof e.oz === "number" ? e.oz + " oz" : e.oz; }
  function label(e) {
    var k = e.kind, a = [k === "nursing" ? "Nursing " + SIDE[e.side].toLowerCase() : k === "diaper" ? "Diaper, " + e.sub.toLowerCase() : k === "med" ? e.name : EV[k][0]], wd = { weekday: "long" }, day = fmt(e.at, e.at < dayAt(-6) ? { weekday: "long", month: "long", day: "numeric" } : wd), end = e.at + (e.dur || 0);
    if (e.run) return a + " timer " + (e.paused ? "paused" : "running") + ", started " + tm(e.at);
    a.push(day, tm(e.at) + (tm(end) === tm(e.at) ? "" : " to " + (new Date(end).getDate() === new Date(e.at).getDate() ? "" : fmt(end, wd) + " ") + tm(end)) + (e.dur ? ", " + spoken(e.dur) : ""));
    if (e.oz) a.push(oz(e));
    return a.join(", ");
  }
  function pack(sp) {
    var cl = [], ends = [], last = -1;
    function flush() { cl.forEach(function (x) { x.n = ends.length; }); cl = []; ends = []; }
    sp.sort(function (x, y) { return x.s - y.s || y.f - x.f; }).forEach(function (x) {
      if (cl.length && x.s >= last) { flush(); last = -1; }
      var c = ends.findIndex(function (v) { return v <= x.s; });
      if (c < 0) c = ends.length;
      ends[c] = x.f; x.c = c; cl.push(x); last = Math.max(last, x.f);
    });
    flush();
  }
  function week() {
    var t = S.timer, w = wall(), key = S.ver + (t ? t.kind + t.side + t.startWall + (t.seg === null) : "");
    if (key === wkDrawn) return; wkDrawn = key;
    var grid = $("wkgrid"), heads = "", items = W.concat(E).map(function (e) { return { e: e, a: e.at, b: e.at + (e.dur || 0) }; });
    if (t) items.push({ run: 1, a: t.startWall, b: w, e: { kind: t.kind === "feed" ? "nursing" : t.kind, side: t.side, at: t.startWall, run: 1, paused: t.seg === null } });
    var back = app.contains(document.activeElement) && document.activeElement.classList.contains("app__wb");
    grid.querySelectorAll(".app__wkcol").forEach(function (c) { c.remove(); });
    runEl = nowEl = null;
    for (var i = -6; i <= 0; i++) {
      var ds = dayAt(i), de = dayAt(i + 1), col = document.createElement("div"), sp = [];
      col.className = "app__wkcol" + (i ? "" : " is-today"); col.setAttribute("role", "group");
      col.setAttribute("aria-label", fmt(ds, { weekday: "long", month: "long", day: "numeric" }) + (i ? "" : ", today"));
      heads += '<span' + (i ? "" : ' class="is-today"') + ">" + fmt(ds, { weekday: "short" }) + "<b>" + new Date(ds).getDate() + "</b></span>";
      items.forEach(function (x) {
        if (x.a >= de || (x.b <= ds && x.a < ds)) return;
        var s0 = x.a <= ds ? 0 : mins(x.a), f = x.b >= de ? 1440 : Math.max(s0, mins(x.b));
        if (f - s0 < 15) { f = Math.min(1440, s0 + 15); s0 = f - 15; }
        sp.push({ x: x, s: s0, f: f });
      });
      pack(sp);
      sp.forEach(function (p) {
        var e = p.x.e, m = EV[e.kind], b = document.createElement("button"), h = px(p.f - p.s) - 1, ic = h < 24 || 354 / 7 / p.n < 32;
        b.type = "button"; b.className = "app__wb" + (e.run ? " is-run" : "") + (ic ? " is-icon" : "");
        b.setAttribute("data-kind", m[2]); b.setAttribute("data-act", e.run ? "open" : "event"); b.tabIndex = -1;
        b.setAttribute("data-id", e.run ? "run" : e.id); b.setAttribute("data-key", (e.run ? "run" : e.id) + "@" + i);
        b.setAttribute("data-day", i + 6); b.setAttribute("data-m", p.s);
        b.style.cssText = "top:" + px(p.s) + "px;height:" + h + "px;left:calc(" + p.c + " * 100% / " + p.n + " + 1px);width:calc(100% / " + p.n + " - 2px)";
        var ttl = e.run ? (e.kind === "nursing" ? "Nursing: " + SIDE[e.side] : K[e.kind][0]) : e.kind === "nursing" ? "Nursing: " + SIDE[e.side] : e.kind === "diaper" ? e.sub : e.kind === "med" ? e.name : m[0];
        var det = e.oz ? oz(e).replace(" ", "") : e.dur ? hm(e.dur) : "";
        b.innerHTML = '<span class="app__wbt"><svg aria-hidden="true"><use href="' + (e.paused ? "#i-pause" : m[1]) + '"/></svg><span></span></span>' + (h >= 38 && det && !ic ? '<span class="app__wbd"></span>' : "");
        b.querySelector(".app__wbt span").textContent = ttl; if (b.children[1]) b.children[1].textContent = det;
        b.setAttribute("aria-label", label(e));
        if (e.run && !i) { runEl = b; runEl._s = p.s; }
        col.appendChild(b);
      });
      if (!i) { nowEl = document.createElement("div"); nowEl.className = "app__now"; col.appendChild(nowEl); }
      grid.appendChild(col);
    }
    $("wkdays").innerHTML = "<span></span>" + heads;
    var all = grid.querySelectorAll(".app__wb"), on = grid.querySelector('[data-key="' + rove + '"]') || all[all.length - 1];
    if (on) { on.tabIndex = 0; rove = on.getAttribute("data-key"); if (back) on.focus({ preventScroll: true }); }
    tick(w);
  }
  /* Per second while the week shows: the now line and the running block's height. Writes only, no layout reads. */
  function tick(w) {
    if (nowEl) nowEl.style.top = px(mins(w)) - 0.75 + "px";
    if (runEl) runEl.style.height = px(Math.max(15, Math.min(1440, mins(w)) - runEl._s)) - 1 + "px";
  }
  function hours() {
    var out = "";
    for (var h = 0; h < 24; h++) out += '<span style="top:' + (h * HH - 7) + 'px">' + ((h + 11) % 12 + 1) + "\u202f" + (h < 12 ? "AM" : "PM") + "</span>";
    $("wkhours").innerHTML = out;
    var a = dayAt(-6), m = { month: "short" };
    put($("wkrange"), fmt(a, m) + " " + new Date(a).getDate() + "\u2009\u2013\u2009" + (fmt(a, m) === fmt(midnight, m) ? "" : fmt(midnight, m) + " ") + d0.getDate());
  }
  hours();
  /* Arrow keys: up and down within a day, left and right to the nearest block in the next day, Home and End. */
  $("wkgrid").addEventListener("keydown", function (ev) {
    var b = ev.target, k = ev.key; if (!b.classList.contains("app__wb")) return;
    var all = [].slice.call($("wkgrid").querySelectorAll(".app__wb")), i = all.indexOf(b), d = +b.getAttribute("data-day"), m = +b.getAttribute("data-m"), to = null;
    if (k === "ArrowDown" || k === "ArrowUp") { to = all[i + (k === "ArrowDown" ? 1 : -1)]; if (to && +to.getAttribute("data-day") !== d) to = null; }
    else if (k === "ArrowRight" || k === "ArrowLeft") {
      for (var dd = d + (k === "ArrowRight" ? 1 : -1); dd >= 0 && dd < 7 && !to; dd += k === "ArrowRight" ? 1 : -1)
        all.forEach(function (x) { if (+x.getAttribute("data-day") === dd && (!to || Math.abs(x.getAttribute("data-m") - m) < Math.abs(to.getAttribute("data-m") - m))) to = x; });
    }
    else if (k === "Home" || k === "End") to = all[k === "Home" ? 0 : all.length - 1];
    else return;
    ev.preventDefault();
    if (to) { b.tabIndex = -1; to.tabIndex = 0; rove = to.getAttribute("data-key"); to.focus(); }
  });
  $("wkgrid").addEventListener("focusin", function (ev) {
    var b = ev.target; if (!b.classList.contains("app__wb") || b.tabIndex === 0) return;
    $("wkgrid").querySelectorAll('.app__wb[tabindex="0"]').forEach(function (x) { x.tabIndex = -1; });
    b.tabIndex = 0; rove = b.getAttribute("data-key");
  });

  /* ---- state changes ---- */
  function attr(el, k, v) { if (el) el.setAttribute(k, v); }
  function icon(k, id) { var u = $(k); if (u) u.setAttribute("href", id); }
  function pressed(act, key) { each('[data-act="' + act + '"]', function (b) { attr(b, "aria-pressed", String(b.getAttribute("data-v") === S[key])); }); }
  function sync() {
    var t = S.timer, run = t && t.seg !== null, f = t && t.kind === "feed", sl = t && t.kind === "sleep", k = t && K[t.kind], L = T.last;
    app.setAttribute("data-run", t ? t.kind : "");
    app.setAttribute("data-tab", S.tab);
    app.toggleAttribute("data-paused", !!t && !run);
    var bar = $("bar"); bar.hidden = !t;
    if (t) {
      bar.setAttribute("data-kind", t.kind);
      icon("baruse", f ? "#i-drop" : k[1]);
      put($("barlabel"), f ? (run ? "Nursing: " : "Paused: ") + SIDE[t.side] : run ? k[2] : k[0] + ": Paused");
      attr($("pausebtn"), "aria-label", run ? "Pause" : "Resume");
      icon("pauseuse", run ? "#i-pause" : "#i-play");
    }
    /* tabs */
    ["home", "log", "timeline"].forEach(function (n) { $(n).hidden = S.tab !== n; });
    $("quick").hidden = S.tab !== "home";
    each('[data-act="tab"]', function (b) {
      var on = b.getAttribute("data-tab") === S.tab; b.classList.toggle("is-on", on);
      if (on) b.setAttribute("aria-current", "page"); else b.removeAttribute("aria-current");
    });
    /* home */
    put($("state"), sl ? "Asleep" : "Awake"); $("state").toggleAttribute("data-asleep", !!sl);
    put($("awakeh"), sl ? "Asleep" : "Awake");
    put($("awakesub"), sl ? "Sleep timer" : "Since last wake");
    attr($("sleepq"), "aria-label", sl ? "Open the sleep timer" : "Start sleep");
    var fed = hm(T.nurse) + " nursing · " + T.oz + " oz bottle";
    put($("feeds"), String(T.feeds)); put($("diapers"), String(T.diapers)); put($("sleep"), hm(T.sleep)); put($("fed"), fed);
    var lk = $("lastkind"); lk.hidden = !L;
    if (L) { lk.setAttribute("data-kind", L.kind === "bottle" ? "bottle" : "feed"); put(lk, L.kind === "bottle" ? "Bottle" : L.side); }
    put($("lastamt"), L && L.kind === "bottle" ? L.oz + " oz" : "");
    put($("diaperkind"), T.diaper ? T.diaper.sub : "");
    /* timeline */
    put($("date"), new Date(t0).toLocaleDateString("en-US", { weekday: "short", month: "short", day: "numeric" }));
    put($("tsleep"), hm(T.sleep)); put($("tfeeds"), String(T.feeds)); put($("tdiapers"), String(T.diapers)); put($("tfed"), fed);
    $("tcryrow").hidden = !T.cry; put($("tcry"), hm(T.cry));
    $("timeline").setAttribute("data-view", S.view); $("tsum").hidden = S.view !== "day";
    each('[data-act="view"]', function (b) { attr(b, "aria-pressed", String(b.getAttribute("data-view") === S.view)); });
    draw();
    /* feed sheet */
    each('[data-act="mode"]', function (b) { attr(b, "aria-pressed", String(b.getAttribute("data-mode") === S.mode)); });
    $("nursing").hidden = S.mode !== "nursing"; $("bottle").hidden = S.mode !== "bottle";
    $("fstartrow").hidden = !f; $("fsave").hidden = !f;
    if (f) put($("fstart"), today(t.startWall));
    each(".app__side", function (b) {
      var s = b.getAttribute("data-side"), on = f && t.side === s, l = SIDE[s].toLowerCase();
      b.classList.toggle("is-on", !!(on && run)); b.classList.toggle("is-held", !!(on && !run));
      b.querySelector("use").setAttribute("href", on && run ? "#i-pause" : "#i-play");
      attr(b, "aria-label", !f ? "Start " + l + " side" : on ? (run ? "Pause " : "Resume ") + l + " side" : "Switch to " + l + " side");
    });
    each('[data-act="oz"]', function (b) { attr(b, "aria-pressed", String(+b.getAttribute("data-oz") === S.oz)); });
    each('[data-act="when"]', function (b) { attr(b, "aria-pressed", String(+b.getAttribute("data-ago") === S.ago)); });
    put($("whenlbl"), S.ago ? S.ago + "m ago" : "Now");
    /* timer sheet: shows the running timer of its kind, or the start buttons */
    var shown = t && !f && (t.kind === S.tkind || (S.tkind === "walk" && t.kind === "ride"));
    $("tidle").hidden = !!shown; $("trun").hidden = !shown;
    $("tidlewalk").hidden = S.tkind !== "walk"; $("tidlecry").hidden = S.tkind !== "cry";
    put($("ttitle"), S.tkind === "cry" ? "Crying" : "Timer");
    if (shown) {
      var tb = $("tbadge"); $("trun").setAttribute("data-kind", t.kind); put(tb, k[0]);
      put($("tnote"), "Shared " + k[0].toLowerCase() + " timer"); put($("sstart"), today(t.startWall));
    }
    put($("spauselbl"), run ? "Pause" : "Resume"); icon("spauseuse", run ? "#i-pause" : "#i-play");
    /* forms */
    pressed("pside", "pside"); pressed("poz", "poz"); pressed("mname", "mname"); pressed("mdose", "mdose");
    var ev = S.ev;
    if (ev) {
      var m = EV[ev.kind], end = ev.dur ? " to " + tm(ev.at + ev.dur) : "";
      put($("etitle"), m[0]); icon("euse", m[1]); $("ekind").setAttribute("data-kind", m[2]);
      put($("ewhen"), today(ev.at) + end);
      put($("ek"), ev.dur ? "Duration" : ev.kind === "diaper" ? "Type" : ev.kind === "med" ? "Dose" : "Amount");
      put($("edet"), ev.kind === "nursing" ? dur(ev.dur) + " (" + detail(ev) + ")" : detail(ev));
      put($("eby"), ev.by);
    }
    loop();
  }

  var live = $("live"), sayId = 0;
  function say(msg) { live.textContent = ""; clearTimeout(sayId); sayId = setTimeout(function () { live.textContent = msg; }, 60); }

  function start(kind, side) {
    var said = S.timer ? save() + " " : "";
    S.timer = { kind: kind, side: side || null, acc: 0, seg: mono(), sides: { L: 0, R: 0 }, startWall: wall() };
    say(said + (kind === "feed" ? "Feed started on the " + SIDE[side].toLowerCase() + " side." : K[kind][0] + " timer started."));
  }
  function save() {
    var t = S.timer; if (!t) return "";
    if (t.seg !== null) bank(t);
    S.timer = null;
    if (t.kind === "feed") {
      add({ kind: "nursing", at: t.startWall, dur: t.acc, L: t.sides.L, R: t.sides.R, side: t.side });
      return "Feed saved: " + spoken(t.acc) + " nursing. " + T.feeds + " feeds since 12 AM.";
    }
    add({ kind: t.kind, at: t.startWall, dur: t.acc });
    return K[t.kind][0] + " saved: " + spoken(t.acc) + ".";
  }
  function togglePause() {
    var t = S.timer; if (!t) return;
    if (t.seg !== null) { bank(t); say("Paused at " + spoken(t.acc) + "."); }
    else { t.seg = mono(); say("Resumed."); }
  }
  function side(s) {
    var t = S.timer;
    if (!t || t.kind !== "feed") return start("feed", s);
    if (t.side === s) return togglePause();
    if (t.seg !== null) bank(t);
    t.seg = mono(); t.side = s;
    say("Switched to the " + SIDE[s].toLowerCase() + " side.");
  }

  /* ---- sheets ---- */
  var behind = ["home", "log", "timeline", "bar", "quick"].map($).concat(app.querySelector(".app__tabs"));
  function sheetEl(n) { return app.querySelector('[data-sheet="' + n + '"]'); }
  function open(n) {
    if (S.sheet) close(true);
    S.opener = document.activeElement;
    S.sheet = n;
    var el = sheetEl(n);
    el.hidden = false; app.classList.add("has-sheet");
    behind.forEach(function (b) { b.inert = true; });
    sync();
    var first = n === "feed" ? (S.mode === "bottle" ? el.querySelector('[data-act="oz"][aria-pressed="true"]') : el.querySelector(".app__side.is-on, .app__side.is-held, .app__side"))
      : n === "diaper" ? el.querySelector(".app__rows button")
      : n === "timer" ? ($("trun").hidden ? el.querySelector('.app__tpick:not([hidden]) [data-act="tstart"]') : $("spause"))
      : n === "event" ? el.querySelector(".app__close") : el.querySelector('[aria-pressed="true"]');
    first.focus({ preventScroll: true });
  }
  function close(swap) {
    if (!S.sheet) return;
    sheetEl(S.sheet).hidden = true; S.sheet = null;
    app.classList.remove("has-sheet");
    behind.forEach(function (b) { b.inert = false; });
    if (swap) return;
    var o = S.opener;
    if (!o || !o.isConnected || o.closest("[hidden]") || !app.contains(o)) o = app.querySelector(S.tab === "home" ? ".app__q--feed" : S.tab === "log" ? ".app__row" : S.view === "week" ? '.app__wb[tabindex="0"]' : ".app__ev") || app.querySelector('[aria-current="page"]');
    o.focus({ preventScroll: true });
  }

  app.addEventListener("click", function (e) {
    var b = e.target.closest("[data-act]"); if (!b || !app.contains(b)) return;
    var a = b.getAttribute("data-act"), v = b.getAttribute("data-v"), t = S.timer, msg;
    if (a === "tab") S.tab = b.getAttribute("data-tab");
    else if (a === "view") {
      var was = S.view; S.view = b.getAttribute("data-view");
      if (S.view === "week" && was !== "week") { sync(); $("wkscroll").scrollTop = px(Math.max(0, new Date(wall()).getHours() - 2) * 60); return; }
    }
    else if (a === "wkprev") say("The demo keeps the last 7 days.");
    else if (a === "feed") open("feed");
    else if (a === "diaper") { S.ago = 0; open("diaper"); }
    else if (a === "sleep") { if (!t || t.kind !== "sleep") start("sleep"); S.tkind = "sleep"; open("timer"); }
    else if (a === "timer") { S.tkind = b.getAttribute("data-kind2"); open("timer"); }
    else if (a === "tstart") { start(b.getAttribute("data-kind")); sync(); var pz = app.querySelector('[data-sheet="timer"] [data-act="pause"]'); if (pz) pz.focus(); return; }
    else if (a === "pump" || a === "med") open(a);
    else if (a === "open") { if (t && t.kind !== "feed") S.tkind = t.kind === "ride" ? "walk" : t.kind; open(t && t.kind !== "feed" ? "timer" : "feed"); }
    else if (a === "close") close();
    else if (a === "side") side(b.getAttribute("data-side"));
    else if (a === "pause") togglePause();
    else if (a === "stop") { msg = save(); say(msg); close(); }
    else if (a === "mode") S.mode = b.getAttribute("data-mode");
    else if (a === "oz") S.oz = +b.getAttribute("data-oz");
    else if (a === "bottle") { add({ kind: "bottle", oz: S.oz }); say("Bottle saved: " + S.oz + " ounces. " + T.feeds + " feeds since 12 AM."); close(); }
    else if (a === "when") S.ago = +b.getAttribute("data-ago");
    else if (a === "nappy") {
      add({ kind: "diaper", sub: b.getAttribute("data-kind"), at: wall() - S.ago * MIN });
      say("Diaper logged: " + b.getAttribute("data-kind").toLowerCase() + ". " + T.diapers + " diapers since 12 AM."); close();
    }
    else if (a === "pside" || a === "poz" || a === "mname" || a === "mdose") S[a] = v;
    else if (a === "psave") { add({ kind: "pump", side: S.pside, oz: S.poz }); say("Pump saved: " + S.pside.toLowerCase() + ", " + S.poz + "."); close(); }
    else if (a === "msave") { add({ kind: "med", name: S.mname, dose: S.mdose }); say("Medicine saved: " + S.mname + ", " + S.mdose + "."); close(); }
    else if (a === "event") { var id = +b.getAttribute("data-id"); S.ev = W.concat(E).filter(function (x) { return x.id === id; })[0]; open("event"); }
    else if (a === "del") {
      var gone = S.ev, keep = function (x) { return x !== gone; }; E = E.filter(keep); W = W.filter(keep); S.ver++; T = totals();
      say(EV[gone.kind][0] + " deleted."); sync(); close();
    }
    sync();
  });
  app.addEventListener("keydown", function (e) { if (e.key === "Escape" && S.sheet) { e.preventDefault(); close(); sync(); } });

  app.classList.add("is-live");
  sync();
})();
