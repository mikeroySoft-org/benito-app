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
})();
