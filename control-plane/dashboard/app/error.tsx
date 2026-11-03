"use client";

export default function ErrorPage({ reset }: { error: Error; reset: () => void }) {
  return (
    <section className="panel" role="alert">
      <h1>The control-plane API didn&apos;t answer</h1>
      <p>Nothing here is a measurement, so nothing is shown. Users aren&apos;t affected: the control plane is off the request path.</p>
      <button type="button" onClick={reset}>Try again</button>
    </section>
  );
}
