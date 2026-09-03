# ADR-001: Server-Side Enforcement of Job State Transitions

## Status
Accepted

## Context
Jobs move through a fixed sequence: `ASSIGNED → EN_ROUTE → ARRIVED → IN_PROGRESS → COMPLETED`. The PRD specifies guarding this in domain/service logic on the client. That's necessary for immediate UX feedback, but it isn't sufficient on its own: FieldOps is offline-first, so a transition can sit in a local sync queue for hours before reaching the server. By the time it syncs, the job's real state may have moved on (reassigned, cancelled, or already advanced by another action). A client-only guard has no way to know that at the moment it queued the mutation.

If the database simply accepts whatever the client says a job's new status is, the *only* thing preventing an invalid or stale transition is trust in one specific client build.

## Decision
Enforce the transition guard in two independent places:

1. **Client (TypeScript domain layer)** — validates before a mutation is even queued, for instant UI feedback and to avoid needless round-trips.
2. **Postgres (`BEFORE UPDATE` trigger on `jobs`)** — the authoritative guard. The trigger:
   - Allows only forward moves along the fixed sequence, plus an explicit `CANCELLED` escape hatch from any non-terminal state.
   - Rejects backward or skipped transitions (e.g. `ASSIGNED → COMPLETED`).
   - Rejects transitions attempted by a technician not assigned to that job (defense in depth alongside RLS).

RLS controls *row visibility* (who can see/touch a job at all). This trigger controls *what values are legal to write* to a row you're already allowed to touch. They're complementary, not redundant.

## Consequences
- The server becomes the actual source of truth for state validity — a buggy or tampered client can't corrupt job state, even via a replayed offline mutation.
- A rejected transition is a legitimate, expected failure mode of sync, not an edge case. The sync layer (see ADR-002) must treat a trigger rejection differently from a network failure: surface it for manual resolution rather than retrying forever.
- Small upfront cost: one plpgsql trigger function and a migration, plus a unit test suite covering every legal and illegal transition pair.
