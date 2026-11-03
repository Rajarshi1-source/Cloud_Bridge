import Link from "next/link";

import { api, type Overview } from "../lib/api";
import { asOf, NO_DATA, number, percent } from "../lib/format";

export const dynamic = "force-dynamic";

function Split({ title, weights, note }: { title: string; weights: Record<string, number> | null; note: string }) {
  return (
    <div>
      <h2>{title}</h2>
      {weights ? (
        <p className="big">{Object.entries(weights).sort().map(([cloud, share]) => `${cloud.toUpperCase()} ${share.toFixed(0)}`).join(" / ")}</p>
      ) : (
        <p className="none">{NO_DATA}</p>
      )}
      <p className="asof">{note}</p>
    </div>
  );
}

export default async function Page() {
  const o = await api<Overview>("/overview");
  const configured = o.configured?.weights ?? null;
  return (
    <>
      <header className="page">
        <h1>Both clouds, environment {o.env}</h1>
        <p className="asof">as of {asOf(o.as_of)}</p>
      </header>

      {!o.prometheus_reachable && (
        <p className="panel bad" role="alert">Prometheus didn&apos;t answer, so live numbers below read as missing, not as zero.</p>
      )}

      <section className="panel grid" aria-label="Traffic split">
        <Split title="Split configured" weights={configured}
               note={o.configured ? `${o.configured.source}, applied ${asOf(o.configured.applied_at)}` : "no recorded traffic change"} />
        <Split title="Split observed, last 5 minutes" weights={o.observed}
               note={o.observed ? "user requests at each gateway" : "needs user traffic: probes don't count"} />
      </section>

      <section className="grid" aria-label="Cells">
        {o.cells.length === 0 && <p className="panel none">No cells registered yet.</p>}
        {o.cells.map((c) => (
          <article key={c.cell} className="panel">
            <h2>{c.cell}</h2>
            <dl>
              <dt>Availability, 1 h</dt>
              <dd className={c.availability === null ? "none" : ""}>{percent(c.availability)}</dd>
              <dt>Gateway p95</dt>
              <dd className={c.p95_ms === null ? "none" : ""}>{c.p95_ms === null ? NO_DATA : `${number(c.p95_ms, 0)} ms`}</dd>
            </dl>
            <p className="asof">Prometheus, as of {asOf(o.as_of)}</p>
          </article>
        ))}
      </section>

      <section className="grid">
        <article className="panel">
          <h2><Link href="/parity">Parity</Link></h2>
          {o.parity ? (
            <>
              <p className={`big ${o.parity.passed ? "good" : "bad"}`}>{number(o.parity.score, 3)}</p>
              <p className="asof">{o.parity.passed ? "every check matches" : "the cells differ"}, snapshot {asOf(o.parity.taken_at)}</p>
            </>
          ) : (
            <p className="none">{NO_DATA}</p>
          )}
        </article>
        <article className="panel">
          <h2>Last evacuation drill</h2>
          {o.last_drill ? (
            <>
              <p>{o.last_drill.from_cell} to {o.last_drill.to_cell}: {o.last_drill.outcome}, shift {o.last_drill.shift_seconds === null ? NO_DATA : `${o.last_drill.shift_seconds} s`}</p>
              <p className="asof">finished {asOf(o.last_drill.finished_at)}</p>
            </>
          ) : (
            <p className="none">{NO_DATA}</p>
          )}
        </article>
      </section>
    </>
  );
}
