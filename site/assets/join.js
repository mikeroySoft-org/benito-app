// Benito invite fallback. PLUMBING: see site/README.md before changing.
//
// An invite link looks like https://benito.mikeroysoft.com/join#p=<base64url JSON>.
// With the app installed, iOS opens Benito directly (universal link) and this page never loads.
// Without it, this page runs. Everything after "#" stays in the browser: it is never sent to
// the web server, so the single-use invite secret is not in any server log.
//
// The page reads the payload, shows who invited whom, and offers:
//   [data-join-open]  Open in Benito  -> benito://join?p=<payload>  (the app's own scheme)
//   [data-join-get]   Get Benito      -> App Store / TestFlight link (data-store-url)
//   [data-join-copy]  Copy invite     -> copies the benito:// link; the app's paste box accepts it
// Text slots: [data-join-family] [data-join-inviter] [data-join-role] [data-join-expires]
// States: <body data-join-state="ready|expired|invalid">; CSS shows/hides [data-when="..."].
(function () {
  "use strict";

  function readPayload(hash) {
    var fragment = (hash || "").replace(/^#/, "");
    var params = new URLSearchParams(fragment);
    var p = params.get("p");
    if (!p && /^[A-Za-z0-9_-]+$/.test(fragment)) p = fragment; // bare "#<payload>"
    return p && /^[A-Za-z0-9_-]+$/.test(p) ? p : null;
  }

  function decodePayload(p) {
    try {
      var b64 = p.replace(/-/g, "+").replace(/_/g, "/");
      while (b64.length % 4) b64 += "=";
      var bytes = Uint8Array.from(atob(b64), function (c) { return c.charCodeAt(0); });
      var json = JSON.parse(new TextDecoder().decode(bytes));
      if (typeof json !== "object" || !json || !Array.isArray(json.e) || json.e.length === 0) return null;
      return json; // keys: v, i, s, f (family), by (inviter), r (role), x (expires, unix s), sid, e
    } catch (_) {
      return null;
    }
  }

  // Friendly expiry for "The invite works once and expires ___.": "in 12 minutes", "in 5 hours",
  // "tomorrow", "in 3 days", then "on Dec 31, 2029" from a week out. Uses the reader's locale, never seconds.
  function formatExpiry(expires, now, locale) {
    var ms = expires.getTime() - now.getTime();
    if (isNaN(ms) || ms <= 0) return "";
    var minute = 60 * 1000, hour = 60 * minute, day = 24 * hour;
    if (ms < 7 * day) {
      var rel = new Intl.RelativeTimeFormat(locale, { numeric: "auto" });
      if (ms < hour) return rel.format(Math.max(1, Math.round(ms / minute)), "minute");
      if (ms < day) return rel.format(Math.round(ms / hour), "hour");
      return rel.format(Math.round(ms / day), "day");
    }
    return "on " + new Intl.DateTimeFormat(locale, { dateStyle: "medium" }).format(expires);
  }

  // Exact moment for the tooltip, e.g. "Dec 31, 2029, 4:00 PM". No seconds.
  function formatExpiryExact(expires, locale) {
    return new Intl.DateTimeFormat(locale, { dateStyle: "medium", timeStyle: "short" }).format(expires);
  }

  function setText(selector, value) {
    document.querySelectorAll(selector).forEach(function (el) { el.textContent = value; });
  }

  function setState(state) {
    document.body.setAttribute("data-join-state", state);
  }

  // Node (site/tests/join.test.mjs) gets the pure helpers; browsers run the page.
  if (typeof document === "undefined") {
    if (typeof module !== "undefined") {
      module.exports = { readPayload: readPayload, decodePayload: decodePayload, formatExpiry: formatExpiry, formatExpiryExact: formatExpiryExact };
    }
    return;
  }

  function init() {
    var p = readPayload(window.location.hash);
    var invite = p && decodePayload(p);
    if (!invite) {
      setState("invalid");
      return;
    }
    var appLink = "benito://join?p=" + p;
    var expires = new Date(Number(invite.x) * 1000);

    setText("[data-join-family]", invite.f || "a family");
    setText("[data-join-inviter]", invite.by || "Someone");
    setText("[data-join-role]", invite.r === "caregiver" ? "caregiver" : "parent");
    var locale = navigator.languages && navigator.languages.length ? navigator.languages : undefined;
    var valid = !isNaN(expires.getTime());
    setText("[data-join-expires]", valid ? formatExpiry(expires, new Date(), locale) : "");
    document.querySelectorAll("[data-join-expires]").forEach(function (el) {
      if (valid) el.setAttribute("title", formatExpiryExact(expires, locale));
      else el.removeAttribute("title");
    });

    document.querySelectorAll("[data-join-open]").forEach(function (a) { a.setAttribute("href", appLink); });
    document.querySelectorAll("[data-join-get]").forEach(function (a) {
      var store = a.getAttribute("data-store-url");
      if (store) a.setAttribute("href", store);
    });
    document.querySelectorAll("[data-join-copy]").forEach(function (button) {
      button.addEventListener("click", function () {
        var done = function () { button.setAttribute("data-copied", "true"); setText("[data-join-copy-status]", "Copied. Open Benito and paste it."); };
        if (navigator.clipboard && window.isSecureContext) {
          navigator.clipboard.writeText(appLink).then(done, function () { window.prompt("Copy this invite:", appLink); });
        } else {
          window.prompt("Copy this invite:", appLink);
        }
      });
    });

    setState(expires.getTime() <= Date.now() ? "expired" : "ready");
  }

  window.addEventListener("hashchange", init);
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", init);
  else init();
})();
