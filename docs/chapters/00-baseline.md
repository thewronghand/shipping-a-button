# PDR-000 — Chapter 0: Baseline

> Post-Delivery Review. *One Perl script and a cron job.*

| Document control | |
|---|---|
| Document ID | `SAB-PDR-000` |
| Chapter | 0 — Baseline |
| Sponsoring stakeholder | S-07 (Heritage) |
| Status | Delivered · Frozen |
| Review rounds before freeze | 7 |
| Supersedes | Nothing. Everything else will be measured against this. |

---

## 1. Mandate

S-07 asserted that, in 1997, the deliverable would have shipped as one Perl script and a cron job: no containers, no YAML, regular expressions.

Chapter 0 accepts this advice literally and designates the result as the **control group**. Every later chapter is measured against it, and every later chapter MUST reproduce its figures (README P-5).

## 2. What was delivered

A single file, [`baseline/button.pl`](../../baseline/button.pl), using core Perl only.

| Command | Purpose |
|---|---|
| `generate` | Synthetic Acme Payments data from a fixed seed: 18 merchants under 3 distributors and 6 agencies, 116,796 transactions over July–September 2026. |
| `build` | Server-rendered HTML, statement CSVs, a static JSON API, and the button counter. Intended to run under cron every minute. |
| `serve` | A small single-threaded HTTP/1.0 server with an access log in Common Log Format. |
| `golden` / `verify` | Writes and checks the contract every later chapter must honour. |

The button counter (FR-4) reads the access log with a regular expression, as S-07 would have wished.

## 3. The contract this chapter establishes

The most important output of Chapter 0 is not the dashboard. It is the set of rules that later chapters inherit, now written down in the script and pinned by [`golden/`](../../golden/).

**Input.** `data/merchants.csv` and `data/transactions.csv`, produced by `generate` with the default seed and pinned by `golden/data.sha256`. Later chapters consume these files; they need not reimplement the generator.

**Figures.**
- Only approved transactions count.
- Fee per transaction is `floor(amount × fee_bp / 10000)`, in integer arithmetic. The daily fee is the sum of per-transaction fees, never a fee on the daily total.
- Payout is amount minus fee. Settlement is the transaction date plus two calendar days.
- A period is the calendar month of the **transaction** date, not the settlement date.

**Statement CSV.** Byte-exact: UTF-8, LF, no BOM, no quoting; one row per day with at least one approved transaction; a final `TOTAL` row. Pinned by `golden/statements.sha256`.

**What counts as a press.** A GET of a statement CSV path that the server answered with 200 *and successfully wrote*. A response the server failed to write is logged as 499 and is not a press. A request whose header block never completes is not answered and so is never a press. Whether the client actually read the bytes is not considered; the server cannot know.

## 4. Findings

Seven independent reviewers examined the chapter in turn, each without the history of the previous rounds. None found an error in the figures; all of them independently recomputed the numbers and matched the golden files. Every other part of the system yielded findings.

| Round | Verdict | Principal finding |
|---|---|---|
| 1 | FAIL | `--seed` and `--port` were silently ignored: a regular-expression capture was overwritten by the next match. |
| 2 | FAIL | macOS filesystems are case-insensitive, so `/M/m001/2026-07.CSV` was served — and not counted. Behaviour differed between operating systems. |
| 3 | FAIL | Downloads to clients that had already disconnected were logged as 200 and counted. |
| 4 | FAIL | A fix from round 3 used `glob`, which splits on spaces; `verify` failed whenever the project lived in a directory with a space in its name. |
| 5 | PASS | Two concurrent builds deleted each other's temporary files. Requests with no terminating blank line were answered and counted. |
| 6 | PASS | A fix from round 5 truncated the request line before parsing it, so long query strings stopped being presses. |
| 7 | PASS | Delta review. Comments only. |

A further regression was found during verification rather than review: truncating the logged request line at 2,048 characters cut off the `HTTP/1.x" 200` suffix, and the counter quietly stopped counting long requests.

## 5. Analysis

### 5.1 The log format is an API

The counter is a regular expression over the access log. That makes the log line format a contract between two halves of the same file, and it is enforced by nothing.

Twice in this chapter, a change made for an unrelated reason — truncating a request line for safety, then truncating it for logging — silently changed what counts as a press. Neither change touched the counter. Both changed its answer. Neither was caught by `verify`, because `verify` guards the figures, and the figures were never wrong.

S-07's regular expressions work. They also make every byte of a log line load-bearing.

### 5.2 Simple is not the same as unspecified

The script is short and its architecture is trivial. What took seven review rounds was not complexity but **definition**: what is a period, what is a press, which bytes a CSV contains, which paths exist, what happens when two builds overlap, what happens when the filesystem disagrees about case.

None of these questions were raised by S-07. All of them had to be answered before the numbers could be trusted, and all of them will have to be answered again, in a different form, by every later chapter.

### 5.3 Fixes are where the regressions live

Three of the defects were introduced by fixes to earlier defects. Each fix was locally reasonable and passed the checks that existed at the time. The rounds converged only once reviews began to look specifically at the delta and its interaction with the counter.

## 6. Cascade observations

The README hypothesis is that accepted advice makes further advice mandatory. Chapter 0 accepted the least advice of any chapter and still observed the effect:

- A counter built from regular expressions **required** a stable, escaped, untruncated log format.
- Serving files from a single process while cron rewrote them **required** atomic writes and a build lock.
- Reproducing figures in other languages later **required** a pinned input, integer-only arithmetic, a portable random generator, and a byte-exact output format.

These requirements were not advice. They were consequences.

## 7. Measurements

Recorded in the README metrics table.

| Metric | Chapter 0 |
|---|---|
| Time until the button worked | 2 min 24 s |
| Lines of code | 724 (513 excluding blanks and comments) |
| Languages | 1 |
| Dependencies | 0 / 0 |
| Build time (cold / warm) | 0.48 s / 0.24 s |
| Memory | 13 MB |
| Button → CSV latency (p50 / p95) | 0.33 ms / 0.41 ms |
| Processes / containers | 1 / 0 |
| Configuration lines (YAML) | 1 (0) |

The first working button took under three minutes. The frozen, reviewed button took seven rounds. Later chapters will be measured on both clocks.

## 8. Disposition

Chapter 0 is frozen (README P-4). The next chapter, Architecture (S-01), will reproduce these figures across microservices, two graph databases, a Kafka topic per interaction, event sourcing and a service mesh, and will be held to the contract in §3.
