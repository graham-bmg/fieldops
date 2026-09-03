# ADR-003: Billing & Invoicing Scope

## Status
Accepted

## Context
The original schema rules stated "money uses integer minor units," implying billing was in scope, but no table actually stored a monetary amount anywhere in the schema. Left as-is, that's a loose thread a reviewer would notice — a rule with nothing to apply it to.

Full payment processing (live charges, webhooks, PCI-adjacent handling) is a large, regulation-heavy surface that doesn't add much to a portfolio piece — and it's already the kind of work demonstrated in Mendo's Paystack integration. Pulling live payments into a second project mostly adds risk and scope, not signal.

## Decision
Add a minimal `invoices` table, scoped to **tracking and PDF generation only** — no live payment processing:

| Field | Intent |
| --- | --- |
| `id` | UUID PK |
| `job_id` | FK → `jobs`, the completed job being billed |
| `amount_minor` | integer, minor currency units |
| `currency` | fixed single currency for MVP (e.g. `char(3)`) |
| `status` | `draft` / `sent` / `paid` |
| `issued_at` | timestamptz |
| `due_at` | timestamptz |
| `paid_at` | timestamptz, nullable |
| `pdf_path` | reuses the existing `service_reports` PDF-generation pattern |

An invoice is generated from a completed job's `service_reports` data. Status moves from `draft` → `sent` → `paid` via explicit user action (e.g. a "mark paid" button) — no payment gateway is called.

## Consequences
- The integer-minor-units rule now has something real to apply to, and the schema stops implying billing without delivering it.
- Keeps the 48-hour build realistic — no gateway integration, webhook handling, or PCI scope.
- Leaves a clean seam: if this ever needs a real "connects to Stripe/Paystack" story, it's a gateway call on top of an existing `invoices` row, not a schema rewrite.
