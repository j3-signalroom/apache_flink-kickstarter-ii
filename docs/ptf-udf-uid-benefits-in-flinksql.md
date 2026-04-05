The `uid` parameter in a PTF call serves one critical purpose: **it ties the PTF's state to a stable identity that survives restarts, upgrades, and redeployments.**

Without `uid`, Flink generates an internal identifier for the operator automatically. That auto-generated ID is fragile — if you change anything about the query (reorder columns, rename the function, restructure the SQL), Flink generates a different ID, and it can no longer match the new operator to the saved state in a checkpoint or savepoint. The result is that **all accumulated state is orphaned and lost** on restart.

With `uid`, you're explicitly saying "this PTF instance is always called `enriched-events-v1`, regardless of how the surrounding SQL changes." Flink uses that stable name as the key to find and restore the correct state from the checkpoint.

**Concrete scenarios where this matters:**

- **Rolling upgrades** — you deploy a new version of your PTF logic (say, fixing a bug in a data quality rule). Without `uid`, the state accumulated by the old version is lost on restart. With `uid`, the new version picks up exactly where the old one left off.

- **Statement restarts** — Confluent Cloud stops and restarts Flink statements regularly (Autopilot scaling, platform maintenance, etc.). The `uid` ensures state survives those cycles.

- **Schema or query evolution** — if you restructure the surrounding SQL but the PTF itself hasn't changed, the `uid` keeps state continuity intact.

- **Multi-tenant cell architecture** — if you're running per-tenant PTF instances, the `uid` also helps you reason about which state belongs to which logical instance, rather than relying on auto-generated opaque identifiers.

The bottom line: `uid` is not optional in production. Omitting it means your PTF is effectively stateless across any restart, which defeats the entire purpose of using a stateful PTF.