// Every number on the dashboard goes through these, so a missing one can only ever read as missing.
export const NO_DATA = "no measurement yet";

type Num = number | null | undefined;

const missing = (value: Num): value is null | undefined =>
  value === null || value === undefined || Number.isNaN(value);

export function asOf(iso: string | null | undefined): string {
  if (!iso) return NO_DATA;
  const at = new Date(iso);
  if (Number.isNaN(at.getTime())) return NO_DATA;
  return `${at.toLocaleString("en-IN", { timeZone: "Asia/Kolkata", dateStyle: "medium", timeStyle: "medium" })} IST`;
}

export function number(value: Num, digits = 2): string {
  return missing(value) ? NO_DATA : value.toFixed(digits);
}

export function percent(ratio: Num, digits = 3): string {
  return missing(ratio) ? NO_DATA : `${(ratio * 100).toFixed(digits)}%`;
}

export function money(value: Num, currency: string): string {
  return missing(value) ? NO_DATA : `${value.toFixed(2)} ${currency}`;
}

export function count(value: Num): string {
  return missing(value) ? NO_DATA : value.toLocaleString("en-IN");
}

export function short(value: unknown, length = 28): string {
  if (value === null || value === undefined) return "unreadable";
  const text = typeof value === "string" ? value : JSON.stringify(value);
  return text.length > length ? `${text.slice(0, length)}…` : text;
}
