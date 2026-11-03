// One load step against one cell's origin, straight at its ingress: tools/load/measure_capacity.py runs
// this at rising rates. Each request is a new client, so the per-client rate limit stays out of the
// measurement. A 409 (out of stock in this cell) is a correct answer, not an error.
import http from "k6/http";
import { Counter } from "k6/metrics";
import { randomBytes } from "k6/crypto";

const HOST = __ENV.CB_HOST;
const SKU = __ENV.CB_SKU;
const ORDER_SHARE = Number(__ENV.CB_ORDER_SHARE || 0.2);
const outOfStock = new Counter("cb_out_of_stock");
// Why a step failed: a dropped connection, a shed request and an open breaker mean different things.
const noAnswer = new Counter("cb_no_answer");
const unavailable = new Counter("cb_503");
const otherError = new Counter("cb_other_error");

function record(res) {
  if (res.status === 0) noAnswer.add(1);
  else if (res.status === 503) unavailable.add(1);
  else if (res.status >= 400 && res.status !== 409) otherError.add(1);
}

export const options = {
  hosts: { [HOST]: __ENV.CB_ORIGIN_IP },
  insecureSkipTLSVerify: true, // the origin's certificate is issued for the edge, and this skips the edge
  scenarios: {
    step: {
      executor: "constant-arrival-rate",
      rate: Number(__ENV.CB_RATE),
      timeUnit: "1s",
      duration: __ENV.CB_DURATION,
      preAllocatedVUs: Math.max(10, Number(__ENV.CB_RATE)),
      maxVUs: Math.max(50, Number(__ENV.CB_RATE) * 10),
    },
  },
};

http.setResponseCallback(http.expectedStatuses({ min: 200, max: 299 }, 409));

function uuid() {
  const hex = Array.from(new Uint8Array(randomBytes(16)), (b) => b.toString(16).padStart(2, "0")).join("");
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-4${hex.slice(13, 16)}-8${hex.slice(17, 20)}-${hex.slice(20, 32)}`;
}

function clientIp() {
  const b = new Uint8Array(randomBytes(2));
  return `198.18.${b[0]}.${b[1]}`; // the benchmarking range (RFC 2544)
}

export default function () {
  const headers = { "CF-Connecting-IP": clientIp() };
  if (Math.random() < ORDER_SHARE) {
    const res = http.post(
      `https://${HOST}/orders`,
      JSON.stringify({ customerId: uuid(), items: [{ sku: SKU, qty: 1, pricePaise: 49900 }] }),
      { headers: { ...headers, "Content-Type": "application/json", "Idempotency-Key": uuid() }, tags: { kind: "order" } },
    );
    if (res.status === 409) outOfStock.add(1);
    record(res);
  } else {
    record(http.get(`https://${HOST}/inventory/${SKU}`, { headers, tags: { kind: "read" } }));
  }
}

export function handleSummary(data) {
  return { "/out/summary.json": JSON.stringify(data) };
}
