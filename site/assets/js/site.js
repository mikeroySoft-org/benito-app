/* Shared page behaviour. Everything here is progressive: the pages read fully with scripting off. */
(function () {
  var cfg = window.BENITO_CONFIG || {};
  /* A GET_BENITO_URL that starts with "/" is read from the site root (the folder above assets/), so it works on any host. */
  var cfgScript = document.querySelector('script[src$="config.js"]');
  var siteRoot = cfgScript ? new URL("../", cfgScript.src) : new URL("/", location.href);
  if (cfg.GET_BENITO_URL) {
    var url = /^\//.test(cfg.GET_BENITO_URL) ? new URL(cfg.GET_BENITO_URL.slice(1), siteRoot).href : cfg.GET_BENITO_URL;
    document.querySelectorAll("[data-get-benito]").forEach(function (a) {
      a.setAttribute("href", url);
      /* /join's Get Benito link also carries data-store-url, which join.js reads. Filling it here keeps one source. */
      if (a.hasAttribute("data-store-url")) a.setAttribute("data-store-url", url);
    });
  }

  var reduce = window.matchMedia("(prefers-reduced-motion: reduce)").matches;

  /* One reveal per page, under .js only (content is visible without it). */
  var items = document.querySelectorAll("[data-reveal]");
  if ("IntersectionObserver" in window && !reduce) {
    var io = new IntersectionObserver(function (es) {
      es.forEach(function (e) { if (e.isIntersecting) { e.target.classList.add("is-in"); io.unobserve(e.target); } });
    }, { rootMargin: "0px 0px -10% 0px" });
    items.forEach(function (el) { io.observe(el); });
  } else {
    items.forEach(function (el) { el.classList.add("is-in"); });
  }

  /* The Live Activity sample: a running nursing timer that counts up once a second.
     Stops off-screen, on hover and focus, under reduced motion, and on its Pause button. */
  document.querySelectorAll("[data-timer]").forEach(function (el) {
    var out = el.querySelector("[data-timer-value]");
    var btn = el.querySelector("[data-timer-toggle]");
    var secs = parseInt(el.getAttribute("data-timer"), 10) || 0;
    var s = { seen: false, hover: false, focus: false, held: reduce };
    var id = null;
    function paint() {
      var m = Math.floor(secs / 60), r = secs % 60;
      out.textContent = (m < 10 ? "0" : "") + m + ":" + (r < 10 ? "0" : "") + r;
    }
    function sync() {
      var run = s.seen && !s.hover && !s.focus && !s.held;
      if (run && !id) id = setInterval(function () { secs += 1; paint(); }, 1000);
      if (!run && id) { clearInterval(id); id = null; }
      el.classList.toggle("is-running", run);
      if (btn) { btn.textContent = s.held ? "Resume" : "Pause"; btn.setAttribute("aria-pressed", String(s.held)); }
    }
    if (btn) btn.addEventListener("click", function () { s.held = !s.held; sync(); });
    el.addEventListener("pointerenter", function () { s.hover = true; sync(); });
    el.addEventListener("pointerleave", function () { s.hover = false; sync(); });
    el.addEventListener("focusin", function () { s.focus = true; sync(); });
    el.addEventListener("focusout", function () { s.focus = false; sync(); });
    if ("IntersectionObserver" in window) {
      new IntersectionObserver(function (es) { s.seen = es[0].isIntersecting; sync(); }).observe(el);
    }
    paint(); sync();
  });
})();
