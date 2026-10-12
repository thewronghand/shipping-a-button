# shipping-a-button

An experiment: build one small dashboard while accepting **every piece of advice** from the developer comedy video "Shipping a button in 2026…" — graph databases, a Kafka topic per interaction, a service mesh, Rust, Java with BigDecimal, Bazel, SAML, per-button RBAC, hover audit logs, and finally a Lisp DSL that compiles to YAML.

The dashboard never changes. Only the architecture does. The real output is the table below: what each piece of advice cost.

## The dashboard

A merchant portal for **Acme Payments**, a fictional payment company. All data is synthetic and generated from a fixed seed.

- Settlement summary for a period
- Daily table: transactions, amount, fees, settlement
- **The button**: download the settlement statement as CSV
- A panel counting how many times the button has been pressed
- An API serving all of the above

## Chapters

| # | Chapter | Status |
|---|---|---|
| 0 | Baseline — one Perl script and a cron job | ⏳ |
| 1 | Architecture — microservices, graph DBs, Kafka, event sourcing, Istio | |
| 2 | Stack & runtime — Next.js, streaming SSR, PPR, Bun, Workers | |
| 3 | Maintenance — design system, WebGPU chart, open source docs, zero useEffect | |
| 4 | Build — Bazel monorepo, deterministic builds | |
| 5 | Rust — Rust services, Leptos web portal, Dioxus Native desktop client | |
| 6 | Observability — OpenTelemetry, Jaeger, predictive alerts and alerts about alerts | |
| 7 | Compliance — SAML SSO, SCIM, per-button RBAC, hover audit logs | |
| 8 | Enterprise — feature flags, kill switch, Java money service | |
| 9 | Ending — a Lisp DSL that compiles to YAML | |

Roadmap 2030: a Rust operating system.

## Measurements

Measured against chapter 0 after every chapter. Same machine, same seed.

| Metric | Ch 0 |
|---|---|
| Time until the button worked | |
| Lines of code / languages | |
| Dependencies (direct / transitive) | |
| Build time (cold / warm) | |
| Memory with the full stack running | |
| Button click → CSV latency (p50 / p95) | |
| Processes / containers | |
| Config lines (incl. YAML) | |
