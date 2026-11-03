import assert from "node:assert/strict";
import { test } from "node:test";

import { asOf, count, money, NO_DATA, number, percent, short } from "./format.ts";

test("a missing number never becomes a zero", () => {
  for (const missing of [null, undefined, Number.NaN]) {
    assert.equal(number(missing), NO_DATA);
    assert.equal(percent(missing), NO_DATA);
    assert.equal(money(missing, "INR"), NO_DATA);
    assert.equal(count(missing), NO_DATA);
  }
});

test("a real zero stays a zero", () => {
  assert.equal(number(0), "0.00");
  assert.equal(percent(0, 1), "0.0%");
  assert.equal(money(0, "INR"), "0.00 INR");
  assert.equal(count(0), "0");
});

test("money keeps its currency", () => {
  assert.equal(money(12.5, "USD"), "12.50 USD");
});

test("timestamps say which zone, and a missing one says so", () => {
  assert.match(asOf("2026-11-03T06:00:00Z"), /3 Nov 2026.*11:30:00.*IST/i);
  assert.equal(asOf(null), NO_DATA);
  assert.equal(asOf("not a date"), NO_DATA);
});

test("an unreadable parity value reads as unreadable", () => {
  assert.equal(short(null), "unreadable");
  assert.equal(short("sha256:abcdef", 6), "sha256…");
  assert.equal(short({ a: 1 }), '{"a":1}');
});
