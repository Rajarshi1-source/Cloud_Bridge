import { api, type Cost } from "../../lib/api";
import { asOf, count, money, NO_DATA, number } from "../../lib/format";

export const dynamic = "force-dynamic";

export default async function Page() {
  const c = await api<Cost>("/cost");
  return (
    <>
      <header className="page">
        <h1>Cost per request</h1>
        <p className="asof">as of {asOf(c.as_of)}, ledger window: the last {c.window_days} days</p>
      </header>

      <section className="panel">
        <h2>Billing data as of</h2>
        {c.freshness.length === 0 ? (
          <p className="none">{NO_DATA}: no billing export has been ingested, so there are no costs to show.</p>
        ) : (
          <dl>
            {c.freshness.map((f) => [
              <dt key={`${f.provider_name}-t`}>{f.provider_name}</dt>,
              <dd key={`${f.provider_name}-d`}>{f.latest_day}, ingested {asOf(f.ingested_at)}</dd>,
            ])}
          </dl>
        )}
      </section>

      <section className="panel">
        <h2>Cost per 1,000 requests</h2>
        <p className="asof">
          Cost divided by requests on the days that have a bill. Credits are excluded. Node cost is an OpenCost estimate, and
          different currencies aren&apos;t compared.
        </p>
        {c.per_service.length === 0 ? <p className="none">{NO_DATA}</p> : (
          <div className="scroll">
            <table>
              <thead>
                <tr>
                  <th>Service</th><th>Cell</th><th className="num">Per 1,000 requests</th>
                  <th className="num">Effective cost</th><th className="num">List cost</th><th className="num">Requests</th>
                </tr>
              </thead>
              <tbody>
                {c.per_service.map((r) => (
                  <tr key={`${r.service}-${r.cell_id}-${r.currency}`}>
                    <td>{r.service}</td>
                    <td>{r.cell_id}</td>
                    <td className="num">{r.cost_per_1k === null ? NO_DATA : `${number(r.cost_per_1k, 4)} ${r.currency}`}</td>
                    <td className="num">{money(r.effective_cost, r.currency)}</td>
                    <td className="num">{money(r.list_cost, r.currency)}</td>
                    <td className="num">{count(r.requests)}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </section>

      {c.shared_without_share.length > 0 && (
        <section className="panel" role="note">
          <h2 className="warn">Shared cost with no allocation share</h2>
          <p className="asof">On a cell, on days with no OpenCost share to divide it by. The table above leaves it out, so its unit costs are too low by this much.</p>
          <ul>{c.shared_without_share.map((s) => <li key={`${s.cell_id}-${s.currency}`}>{s.cell_id}: {money(s.cost, s.currency)}</li>)}</ul>
        </section>
      )}

      <section className="grid">
        <article className="panel">
          <h2>Unallocated cost</h2>
          <p className="asof">No cb-cell tag. Shown here, never spread across the cells.</p>
          {c.unallocated.length === 0 ? <p className="none">none in the ledger</p> : (
            <ul>{c.unallocated.map((u) => <li key={`${u.provider_name}-${u.service_name}-${u.currency}`}>{u.provider_name}, {u.service_name ?? "unnamed"}: {money(u.cost, u.currency)}</li>)}</ul>
          )}
        </article>
        <article className="panel">
          <h2>Left out of unit costs</h2>
          <p className="asof">Credits, taxes and purchases, reported separately.</p>
          {c.not_usage.length === 0 ? <p className="none">none in the ledger</p> : (
            <ul>{c.not_usage.map((n) => <li key={`${n.cell_id}-${n.charge_category}-${n.currency}`}>{n.cell_id ?? "no cell"}, {n.charge_category}: {money(n.cost, n.currency)}</li>)}</ul>
          )}
        </article>
      </section>
    </>
  );
}
