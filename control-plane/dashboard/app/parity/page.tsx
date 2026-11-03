import { api, type Finding, type Parity } from "../../lib/api";
import { asOf, NO_DATA, number, short } from "../../lib/format";

export const dynamic = "force-dynamic";

const LABEL: Record<Finding["status"], { text: string; tone: string }> = {
  match: { text: "match", tone: "good" },
  excepted: { text: "excepted", tone: "warn" },
  diverged: { text: "diverged", tone: "bad" },
  unknown: { text: "unknown", tone: "bad" },
};

export default async function Page({ searchParams }: { searchParams: Promise<{ env?: string }> }) {
  const { env } = await searchParams;
  const p = await api<Parity>(`/parity${env ? `?env=${encodeURIComponent(env)}` : ""}`);
  const cells = [...new Set(p.findings.flatMap((f) => Object.keys(f.cell_values)))].sort();
  return (
    <>
      <header className="page">
        <h1>Parity, environment {p.env}</h1>
        <p className="asof">{p.latest ? `snapshot ${asOf(p.latest.taken_at)}, ${p.latest.trigger}` : `as of ${asOf(p.as_of)}`}</p>
      </header>

      {!p.latest ? (
        <p className="panel none">{NO_DATA}: no parity check has stored a snapshot for this environment.</p>
      ) : (
        <>
          <section className="grid">
            <article className="panel">
              <h2>Score</h2>
              <p className={`big ${p.latest.passed ? "good" : "bad"}`}>{number(p.latest.score, 3)}</p>
              <p className="asof">{p.latest.passed ? "every check matches or is excepted" : "anything below 1.0 fails: it is a list of divergences, not a grade"}</p>
            </article>
            <article className="panel">
              <h2>Last {p.trend.length} snapshots</h2>
              <div className="trend" role="img" aria-label={`Score over the last ${p.trend.length} snapshots`}>
                {p.trend.map((t) => (
                  <span key={t.taken_at} className={t.passed ? "" : "failed"} style={{ height: `${Math.max(t.score * 100, 4)}%` }}
                        title={`${number(t.score, 3)} at ${asOf(t.taken_at)}`} />
                ))}
              </div>
              <p className="asof">since {asOf(p.trend[0]?.taken_at)}</p>
            </article>
            <article className="panel">
              <h2>Exceptions expiring within 7 days</h2>
              {p.expiring.length === 0 ? <p className="none">none</p> : (
                <ul>{p.expiring.map((f) => <li key={f.check_id}><code>{f.check_id}</code>, {f.exception_expires}</li>)}</ul>
              )}
              <p className="asof">from this snapshot</p>
            </article>
          </section>

          <section className="panel">
            <h2>Checks</h2>
            <div className="scroll">
              <table>
                <thead>
                  <tr>
                    <th>Check</th><th className="num">Weight</th><th>Status</th>
                    {cells.map((c) => <th key={c}>{c}</th>)}
                    <th>Note</th>
                  </tr>
                </thead>
                <tbody>
                  {p.findings.map((f) => (
                    <tr key={f.check_id}>
                      <td><code>{f.check_id}</code></td>
                      <td className="num">{f.weight}</td>
                      <td className={LABEL[f.status].tone}>{LABEL[f.status].text}</td>
                      {cells.map((c) => <td key={c}><code title={JSON.stringify(f.cell_values[c])}>{short(f.cell_values[c])}</code></td>)}
                      <td>{f.note ?? ""}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          </section>
        </>
      )}
    </>
  );
}
