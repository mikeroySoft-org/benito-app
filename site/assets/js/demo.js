/* The hero demo: Benito's home screen with sample data. State lives in memory only, nothing goes over the
   network, and a reload starts over. Timers store when the running stretch began plus the time already banked,
   and every paint reads the clock. Nothing counts ticks, so hover, scroll, busy threads and background tabs
   cannot make a timer drift: a late tick only paints late, never wrong. */
(function () {
  var app = document.querySelector("[data-demo]");
  if (!app) return;
  var MIN = 60000;
  var mono = function () { return performance.now(); };
  var wall = function () { return Date.now(); };
  var $ = function (k) { return app.querySelector('[data-d="' + k + '"]'); };
  var t0 = wall();
  var S = {
    feeds: 6, diapers: 4, sleepMs: 460 * MIN, nurseMs: 69 * MIN, bottleOz: 6.5,
    last: { at: t0 - 109 * MIN, kind: "bottle", oz: 3.5 },
    diaper: { at: t0 - 84 * MIN, kind: "Both" },
    wakeAt: t0 - 134 * MIN,
    timer: null, mode: "nursing", oz: 4, ago: 0, sheet: null, opener: null
  };
  var SIDE = { L: "Left", R: "Right" };

  /* ---- time ---- */
  function elapsed(t, at) { return t.acc + (t.seg === null ? 0 : at - t.seg); }
  function sideMs(t, s, at) { return t.sides[s] + (t.seg !== null && t.side === s ? at - t.seg : 0); }
  function bank(t) { var at = mono(), d = at - t.seg; t.acc += d; if (t.side) t.sides[t.side] += d; t.seg = null; }
  function p2(n) { return (n < 10 ? "0" : "") + n; }
  function clock(ms) { var s = Math.floor(ms / 1000), h = Math.floor(s / 3600), m = Math.floor(s / 60) % 60; return (h ? h + ":" + p2(m) : p2(m)) + ":" + p2(s % 60); }
  function hm(ms) { var m = Math.max(0, Math.floor(ms / MIN)), h = Math.floor(m / 60); return h ? h + "h " + (m % 60) + "m" : m + "m"; }
  function spoken(ms) {
    var s = Math.floor(ms / 1000), h = Math.floor(s / 3600), m = Math.floor(s / 60) % 60, x = s % 60, out = [];
    if (h) out.push(h + (h > 1 ? " hours" : " hour"));
    if (m) out.push(m + (m > 1 ? " minutes" : " minute"));
    if (!h) out.push(x + (x === 1 ? " second" : " seconds"));
    return out.join(" ");
  }
  function today(at) { return "Today, " + new Date(at).toLocaleTimeString("en-US", { hour: "numeric", minute: "2-digit" }); }

  /* ---- paint: text only, written only when the string changes, no layout reads ---- */
  var els = {};
  "clock since diaperago awake fed feedsub bartime fh fm fs tL tR stime".split(" ").forEach(function (k) { els[k] = $(k); });
  function put(el, s) { if (el && el._v !== s) { el._v = s; el.textContent = s; } }
  function paint() {
    var w = wall(), at = mono(), t = S.timer, d = new Date(w);
    put(els.clock, ((d.getHours() + 11) % 12 + 1) + ":" + p2(d.getMinutes()));
    put(els.since, hm(w - S.last.at));
    put(els.diaperago, hm(w - S.diaper.at));
    put(els.awake, t && t.kind === "sleep" ? hm(elapsed(t, at)) : hm(w - S.wakeAt));
    put(els.fed, hm(S.nurseMs) + " nursing · " + S.bottleOz + " oz bottle");
    put(els.feedsub, (S.last.kind === "bottle" ? "Bottle" : S.last.side) + " · " + hm(w - S.last.at) + " ago");
    var e = t ? elapsed(t, at) : 0, s = Math.floor(e / 1000);
    put(els.bartime, clock(e));
    var f = t && t.kind === "feed";
    put(els.fh, p2(f ? Math.floor(s / 3600) : 0)); put(els.fm, p2(f ? Math.floor(s / 60) % 60 : 0)); put(els.fs, p2(f ? s % 60 : 0));
    put(els.tL, clock(f ? sideMs(t, "L", at) : 0)); put(els.tR, clock(f ? sideMs(t, "R", at) : 0));
    put(els.stime, clock(t && t.kind === "sleep" ? e : 0));
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

  /* ---- state changes ---- */
  function attr(el, k, v) { if (el) el.setAttribute(k, v); }
  function icon(k, id) { var u = $(k); if (u) u.setAttribute("href", id); }
  function sync() {
    var t = S.timer, run = t && t.seg !== null, f = t && t.kind === "feed", sl = t && t.kind === "sleep";
    app.setAttribute("data-run", t ? t.kind : "");
    app.toggleAttribute("data-paused", !!t && !run);
    var bar = $("bar"); bar.hidden = !t;
    if (t) {
      bar.setAttribute("data-kind", t.kind);
      icon("baruse", f ? "#i-drop" : "#i-moon");
      put($("barlabel"), f ? (run ? "Nursing: " : "Paused: ") + SIDE[t.side] : run ? "Sleeping" : "Sleep: Paused");
      attr($("pausebtn"), "aria-label", run ? "Pause" : "Resume");
      icon("pauseuse", run ? "#i-pause" : "#i-play");
    }
    put($("state"), sl ? "Asleep" : "Awake"); $("state").toggleAttribute("data-asleep", !!sl);
    put($("awakeh"), sl ? "Asleep" : "Awake");
    put($("awakesub"), sl ? "Sleep timer" : "Since last wake");
    attr($("sleepq"), "aria-label", sl ? "Open the sleep timer" : "Start sleep");
    put($("feeds"), String(S.feeds)); put($("diapers"), String(S.diapers)); put($("sleep"), hm(S.sleepMs));
    var k = $("lastkind"); k.setAttribute("data-kind", S.last.kind === "bottle" ? "bottle" : "feed");
    put(k, S.last.kind === "bottle" ? "Bottle" : S.last.side);
    put($("diaperkind"), S.diaper.kind);
    put($("lastamt"), S.last.kind === "bottle" ? S.last.oz + " oz" : "");
    /* feed sheet */
    app.querySelectorAll('[data-act="mode"]').forEach(function (b) { attr(b, "aria-pressed", String(b.getAttribute("data-mode") === S.mode)); });
    $("nursing").hidden = S.mode !== "nursing"; $("bottle").hidden = S.mode !== "bottle";
    $("fstartrow").hidden = !f; $("fsave").hidden = !f;
    if (f) put($("fstart"), today(t.startWall));
    app.querySelectorAll(".app__side").forEach(function (b) {
      var s = b.getAttribute("data-side"), on = f && t.side === s, l = SIDE[s].toLowerCase();
      b.classList.toggle("is-on", !!(on && run)); b.classList.toggle("is-held", !!(on && !run));
      b.querySelector("use").setAttribute("href", on && run ? "#i-pause" : "#i-play");
      attr(b, "aria-label", !f ? "Start " + l + " side" : on ? (run ? "Pause " : "Resume ") + l + " side" : "Switch to " + l + " side");
    });
    app.querySelectorAll('[data-act="oz"]').forEach(function (b) { attr(b, "aria-pressed", String(+b.getAttribute("data-oz") === S.oz)); });
    app.querySelectorAll('[data-act="when"]').forEach(function (b) { attr(b, "aria-pressed", String(+b.getAttribute("data-ago") === S.ago)); });
    put($("whenlbl"), S.ago ? S.ago + "m ago" : "Now");
    /* sleep sheet */
    if (sl) put($("sstart"), today(t.startWall));
    put($("spauselbl"), run ? "Pause" : "Resume"); icon("spauseuse", run ? "#i-pause" : "#i-play");
    loop();
  }

  var live = $("live"), sayId = 0;
  function say(msg) { live.textContent = ""; clearTimeout(sayId); sayId = setTimeout(function () { live.textContent = msg; }, 60); }

  function start(kind, side) {
    var said = S.timer ? save() + " " : "";
    S.timer = { kind: kind, side: side || null, acc: 0, seg: mono(), sides: { L: 0, R: 0 }, startWall: wall() };
    say(said + (kind === "feed" ? "Feed started on the " + SIDE[side].toLowerCase() + " side." : "Sleep timer started."));
  }
  function save() {
    var t = S.timer; if (!t) return "";
    if (t.seg !== null) bank(t);
    S.timer = null;
    if (t.kind === "feed") {
      S.feeds += 1; S.nurseMs += t.acc;
      S.last = { at: t.startWall, kind: "nursing", side: t.side };
      return "Feed saved: " + spoken(t.acc) + " nursing. " + S.feeds + " feeds since 12 AM.";
    }
    S.sleepMs += t.acc; S.wakeAt = wall();
    return "Sleep saved: " + spoken(t.acc) + ".";
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
    if (t.seg !== null) { bank(t); t.seg = mono(); }
    else { t.seg = mono(); }
    t.side = s;
    say("Switched to the " + SIDE[s].toLowerCase() + " side.");
  }

  /* ---- sheets ---- */
  var behind = ["home", "bar", "quick"].map($).concat(app.querySelector(".app__tabs"));
  function sheetEl(n) { return app.querySelector('[data-sheet="' + n + '"]'); }
  function open(n) {
    if (S.sheet) close(true);
    S.opener = document.activeElement;
    S.sheet = n;
    var el = sheetEl(n);
    el.hidden = false; app.classList.add("has-sheet");
    behind.forEach(function (b) { b.inert = true; });
    sync();
    var first = n === "feed" ? el.querySelector(".app__side.is-on, .app__side.is-held, .app__side") : n === "diaper" ? el.querySelector(".app__rows button") : $("spause");
    if (S.mode === "bottle" && n === "feed") first = el.querySelector('[data-act="oz"][aria-pressed="true"]');
    first.focus({ preventScroll: true });
  }
  function close(swap) {
    if (!S.sheet) return;
    sheetEl(S.sheet).hidden = true; S.sheet = null;
    app.classList.remove("has-sheet");
    behind.forEach(function (b) { b.inert = false; });
    if (swap) return;
    var o = S.opener;
    if (!o || !o.isConnected || o.closest("[hidden]") || !app.contains(o)) o = app.querySelector('[data-act="feed"]');
    o.focus({ preventScroll: true });
  }

  app.addEventListener("click", function (e) {
    var b = e.target.closest("[data-act]"); if (!b || !app.contains(b)) return;
    var a = b.getAttribute("data-act"), t = S.timer;
    if (a === "feed") open("feed");
    else if (a === "diaper") { S.ago = 0; open("diaper"); }
    else if (a === "sleep") { if (!t || t.kind !== "sleep") start("sleep"); open("sleep"); }
    else if (a === "open") open(t ? t.kind : "feed");
    else if (a === "close") close();
    else if (a === "side") side(b.getAttribute("data-side"));
    else if (a === "pause") togglePause();
    else if (a === "stop") { var msg = save(); say(msg); close(); }
    else if (a === "mode") S.mode = b.getAttribute("data-mode");
    else if (a === "oz") S.oz = +b.getAttribute("data-oz");
    else if (a === "bottle") {
      S.feeds += 1; S.bottleOz += S.oz; S.last = { at: wall(), kind: "bottle", oz: S.oz };
      say("Bottle saved: " + S.oz + " ounces. " + S.feeds + " feeds since 12 AM."); close();
    }
    else if (a === "when") S.ago = +b.getAttribute("data-ago");
    else if (a === "nappy") {
      S.diapers += 1; S.diaper = { at: wall() - S.ago * MIN, kind: b.getAttribute("data-kind") };
      say("Diaper logged: " + S.diaper.kind.toLowerCase() + ". " + S.diapers + " diapers since 12 AM."); close();
    }
    sync();
  });
  app.addEventListener("keydown", function (e) { if (e.key === "Escape" && S.sheet) { e.preventDefault(); close(); sync(); } });

  app.classList.add("is-live");
  sync();
})();
