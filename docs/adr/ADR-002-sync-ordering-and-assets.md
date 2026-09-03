# ADR-002: Offline Sync Ordering, Idempotency, and Binary Asset Handling

## Status
Accepted

## Context
`sync_operations` queues arbitrary entity mutations made while offline (`entity`, `entity_id`, `operation`, `payload` JSONB, `status`, `retry_count`, `last_error`). Two problems aren't addressed by that shape alone:

1. **Ordering / referential integrity.** A technician offline can create a job, then add checklist items and measurements that reference it, then attach photos. If the sync worker replays these out of order or in parallel, a `checklist_item` insert can hit the server before its parent `job` row exists.
2. **Binary content.** Photos and signatures don't belong in a JSONB payload column. They need their own upload path, and "the metadata row synced" and "the file actually made it to storage" are two different facts that shouldn't be conflated into one `synced` flag.

## Decision
- Every `sync_operation` carries a client-generated **idempotency key** (its own UUID) and a **monotonically increasing per-device sequence number**.
- The sync worker processes operations **per entity chain, in strict sequence order** — a job's creation is applied before any checklist item, measurement, attachment, or signature that references it. Operations for independent entities can run concurrently; operations within a dependency chain cannot.
- Binary assets (photos, signature images) are queued separately from row-level mutations — e.g. an `upload_operations` table or a payload discriminator — and only marked `synced` once the file upload to Supabase Storage is confirmed. A metadata row referencing a file that hasn't finished uploading stays in a `pending_upload` state, not `synced`.
- Failures are split by class:
  - **Network-class** (timeout, 5xx) → automatic retry with exponential backoff, using `retry_count`.
  - **Domain-rule rejection** (e.g. ADR-001's transition trigger rejects a stale transition, or an RLS policy denies the write) → marked `failed`, `last_error` populated, surfaced to the user for manual resolution. These are not retried automatically — retrying a rejected transition forever just burns battery and hides a real conflict from the user.

## Consequences
- More sync-worker complexity than "fire every queued operation and hope," but it removes two real failure classes: FK violations from out-of-order replay, and phantom "synced" states where the DB row exists but its photo doesn't.
- Idempotency keys make retries safe — a retried operation after a partial failure doesn't create a duplicate row.
- This is also what makes ADR-001 workable in practice: without the failed/rejected distinction here, a rejected transition would just loop forever as a "network retry."
