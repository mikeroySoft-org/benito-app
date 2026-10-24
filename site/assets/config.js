/*
 * Benito site config. One place to change site-wide values.
 *
 * GET_BENITO_URL is the App Store URL placeholder.
 * Benito is not on the App Store yet, so every "Get Benito" link points at the
 * self-host page, which explains how to build and run it today.
 * When the App Store listing exists, set GET_BENITO_URL to it (for example
 * "https://apps.apple.com/app/id0000000000"). Every element with a
 * data-get-benito attribute picks it up at load (assets/js/site.js), and on
 * /join it also fills the link's data-store-url, which assets/join.js reads.
 * A value starting with "/" is read from the site root.
 * The static href on those links ("self-host/" or "../self-host/") is the
 * no-script fallback and must name the same destination. When the URL changes,
 * update them too: grep -rl 'data-get-benito' site/
 */
window.BENITO_CONFIG = {
  GET_BENITO_URL: "/self-host/",
};
