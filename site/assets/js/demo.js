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
    if (!h) out.push(x + (x === 1 ? " second" : " seconds"));
    return out.join(" ");
  }
  function tm(at) { return new Date(at).toLocaleTimeString("en-US", { hour: "numeric", minute: "2-digit" }); }
  function today(at) { return "Today, " + tm(at); }
  function detail(e) {
    var k = e.kind;
    return k === "nursing" ? "L " + dur(e.L) + " · R " + dur(e.R) : k === "bottle" ? e.oz + " oz" : k === "diaper" ? e.sub
      : k === "pump" ? e.side + " · " + e.oz : k === "med" ? e.name + " · " + e.dose : dur(e.dur);
  }

  /* ---- paint: text only, written only when the string changes, no layout reads ---- */
  var els = {};
  "clock since diaperago awake feedsub bartime fh fm fs tL tR stime".split(" ").forEach(function (k) { els[k] = $(k); });
  function put(el, s) { if (el && el._v !== s) { el._v = s; el.textContent = s; } }
  function paint() {
    var w = wall(), at = mono(), t = S.timer, d = new Date(w), L = T.last;
    put(els.clock, ((d.getHours() + 11) % 12 + 1) + ":" + p2(d.getMinutes()));
    put(els.since, L ? hm(w - L.at) : "None");
    put(els.diaperago, T.diaper ? hm(w - T.diaper.at) : "None");
    put(els.awake, t && t.kind === "sleep" ? hm(elapsed(t, at)) : T.wake ? hm(w - T.wake) : "None");
    put(els.feedsub, L ? (L.kind === "bottle" ? "Bottle" : SIDE[L.side]) + " · " + hm(w - L.at) + " ago" : "");
    var e = t ? elapsed(t, at) : 0, s = Math.floor(e / 1000), f = t && t.kind === "feed";
    put(els.bartime, clock(e));
    put(els.fh, p2(f ? Math.floor(s / 3600) : 0)); put(els.fm, p2(f ? Math.floor(s / 60) % 60 : 0)); put(els.fs, p2(f ? s % 60 : 0));
    put(els.tL, clock(f ? sideMs(t, "L", at) : 0)); put(els.tR, clock(f ? sideMs(t, "R", at) : 0));
    put(els.stime, clock(t && !f ? e : 0));
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
    if (!o || !o.isConnected || o.closest("[hidden]") || !app.contains(o)) o = app.querySelector(S.tab === "home" ? ".app__q--feed" : S.tab === "log" ? ".app__row" : ".app__ev") || app.querySelector('[aria-current="page"]');
    o.focus({ preventScroll: true });
  }

  app.addEventListener("click", function (e) {
    var b = e.target.closest("[data-act]"); if (!b || !app.contains(b)) return;
    var a = b.getAttribute("data-act"), v = b.getAttribute("data-v"), t = S.timer, msg;
    if (a === "tab") S.tab = b.getAttribute("data-tab");
    else if (a === "view") S.view = b.getAttribute("data-view");
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
    else if (a === "event") { var id = +b.getAttribute("data-id"); S.ev = E.filter(function (x) { return x.id === id; })[0]; open("event"); }
    else if (a === "del") {
      var gone = S.ev; E = E.filter(function (x) { return x !== gone; }); S.ver++; T = totals();
      say(EV[gone.kind][0] + " deleted."); sync(); close();
    }
    sync();
  });
  app.addEventListener("keydown", function (e) { if (e.key === "Escape" && S.sheet) { e.preventDefault(); close(); sync(); } });

  app.classList.add("is-live");
  sync();
})();
