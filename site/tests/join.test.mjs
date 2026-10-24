// Checks that the web join page decodes exactly what the app's FamilyInviteLink encodes.
// Run: node site/tests/join.test.mjs
import assert from "node:assert/strict";
import { createRequire } from "node:module";

const require = createRequire(import.meta.url);
const { readPayload, decodePayload, formatExpiry, formatExpiryExact } = require("../assets/join.js");

// Same shape as FamilyInviteLink.encodePayload: sorted-key JSON, base64url without padding.
const invite = { by: "Mike", e: ["http://192.168.1.20:8082"], f: "Roy family", i: "inv1", r: "caregiver", s: "secret", sid: "srv", v: 1, x: 1893456000 };
const payload = Buffer.from(JSON.stringify(invite)).toString("base64url");

assert.equal(readPayload("#p=" + payload), payload);
assert.equal(readPayload("#" + payload), payload, "bare fragment");
assert.equal(readPayload(""), null);
assert.equal(readPayload("#p=<script>"), null, "rejects non-base64url");

const decoded = decodePayload(payload);
assert.equal(decoded.f, "Roy family");
assert.equal(decoded.by, "Mike");
assert.equal(decoded.r, "caregiver");
assert.equal(decoded.x, 1893456000);

const unicode = Buffer.from(JSON.stringify({ ...invite, f: "Famille Roy 👶" })).toString("base64url");
assert.equal(decodePayload(unicode).f, "Famille Roy 👶", "UTF-8 names survive");

assert.equal(decodePayload(Buffer.from(JSON.stringify({ ...invite, e: [] })).toString("base64url")), null, "needs an endpoint");
assert.equal(decodePayload("not-json"), null);

// Friendly expiry: relative inside a week, a date after that, never seconds.
const now = new Date("2026-10-23T16:00:00Z");
const later = (ms) => new Date(now.getTime() + ms);
const H = 3600 * 1000, D = 24 * H;
assert.equal(formatExpiry(later(12 * 60 * 1000), now, "en-US"), "in 12 minutes");
assert.equal(formatExpiry(later(10 * 1000), now, "en-US"), "in 1 minute", "never seconds");
assert.equal(formatExpiry(later(5 * H), now, "en-US"), "in 5 hours");
assert.equal(formatExpiry(later(D), now, "en-US"), "tomorrow");
assert.equal(formatExpiry(later(72 * H - 60 * 1000), now, "en-US"), "in 3 days", "a 72-hour invite a minute after sharing");
const newYearsEve = new Date(Date.UTC(2029, 11, 31, 12)); // midday UTC: Dec 31 in every time zone CI might use
assert.equal(formatExpiry(newYearsEve, now, "en-US"), "on Dec 31, 2029");
assert.equal(formatExpiry(newYearsEve, now, "en-GB"), "on 31 Dec 2029", "locale order");
assert.equal(formatExpiry(later(3 * D), now, "fr"), "dans 3 jours", "locale words");
assert.equal(formatExpiry(later(-1), now, "en-US"), "", "expired shows nothing");
assert.equal(formatExpiry(new Date(NaN), now, "en-US"), "");
const exact = formatExpiryExact(newYearsEve, "en-US");
assert.match(exact, /^Dec 31, 2029, \d{1,2}:\d\d\s?[AP]M$/);
assert.doesNotMatch(exact, /:\d\d:\d\d/, "no seconds");

console.log("join.js: all checks passed");
