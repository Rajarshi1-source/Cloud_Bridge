// Server side only: the token never reaches the browser.
export type Overview = {
  as_of: string;
  env: string;
  prometheus_reachable: boolean;
  configured: { weights: Record<string, number>; source: string; applied_at: string } | null;
  observed: Record<string, number> | null;
  cells: { cell: string; cloud: string; availability: number | null; p95_ms: number | null }[];
  parity: { score: number; passed: boolean; taken_at: string; trigger: string } | null;
  last_drill: { from_cell: string; to_cell: string; outcome: string; shift_seconds: number | null; finished_at: string } | null;
};

export type Finding = {
  check_id: string;
  weight: number;
  cell_values: Record<string, unknown>;
  status: "match" | "diverged" | "excepted" | "unknown";
  note: string | null;
  exception_expires: string | null;
};

export type Parity = {
  as_of: string;
  env: string;
  latest: { score: number; passed: boolean; trigger: string; commit_sha: string | null; taken_at: string } | null;
  findings: Finding[];
  trend: { score: number; passed: boolean; taken_at: string }[];
  expiring: Finding[];
};

export type Cost = {
  as_of: string;
  window_days: number;
  per_service: {
    cell_id: string;
    service: string;
    currency: string;
    effective_cost: number;
    list_cost: number | null;
    requests: number | null;
    cost_per_1k: number | null;
  }[];
  shared_without_share: { cell_id: string; currency: string; cost: number }[];
  unallocated: { provider_name: string; service_name: string | null; currency: string; cost: number }[];
  not_usage: { cell_id: string | null; charge_category: string; currency: string; cost: number }[];
  freshness: { provider_name: string; latest_day: string; ingested_at: string }[];
};

export async function api<T>(path: string): Promise<T> {
  const response = await fetch(`${process.env.CP_API_URL}${path}`, {
    cache: "no-store",
    headers: { Authorization: `Bearer ${process.env.CB_CP_TOKEN}` },
  });
  if (!response.ok) throw new Error(`control plane answered ${response.status} for ${path}`);
  return response.json() as Promise<T>;
}
