// Checks that the web join page decodes exactly what the app's FamilyInviteLink encodes.
// Run: node site/tests/join.test.mjs
import assert from "node:assert/strict";
import { createRequire } from "node:module";

const require = createRequire(import.meta.url);
const { readPayload, decodePayload } = require("../assets/join.js");

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

console.log("join.js: all checks passed");
