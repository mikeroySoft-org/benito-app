/*
 * Benito site config. One place to change site-wide values.
 *
 * GET_BENITO_URL is the App Store listing. Every element with a
 * data-get-benito attribute picks it up at load (assets/js/site.js), and on
 * /join it also fills the link's data-store-url, which assets/join.js reads.
 * A value starting with "/" is read from the site root.
 * The static href on those links is the no-script fallback and must name the
 * same destination. When the URL changes, update them too:
 * grep -rl 'data-get-benito' site/
 */
window.BENITO_CONFIG = {
  GET_BENITO_URL: "https://apps.apple.com/app/id6838921745",
};
