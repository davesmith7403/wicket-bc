# Wicket

**Generic JSON-RPC over Microsoft Dynamics 365 Business Central, for LLM agents.**

Wicket is a Business Central extension (BC 26+, AL, runtime 16.0, SaaS Online) that exposes a
single, generic RPC protocol over BC data and logic — one API page, sixteen operations, every BC
table reachable by ID — designed so an LLM agent can discover, read, write, invoke, run named
business actions, and export asynchronously against BC safely and without bespoke per-entity endpoints.

It is deny-by-default, returns RFC 7807 problem documents, enforces optimistic concurrency, logs
every call, and emits Application Insights telemetry.

- App: `app/app.json` → `Wicket`, version `1.3.0.0`, publisher `Dave The Wicketkeeper`, object range `94100–94199`.
- Companion app: [`actions/`](actions/) → `Wicket Actions - Base`, version `0.3.0.0`, object range
  `94200–94249` — the Base-App-dependent action providers (posting wrappers). Optional.
- Status: **full read/write/invoke plane, named actions, field-level policy, and async Azure Blob
  delivery built.** 389 core AL tests and 36 companion tests; see [Status](#status) for what is
  still unverified.

## What it is

Instead of publishing a hand-written API page per entity, Wicket publishes **one** API page with
generic bound actions. A caller addresses any exposed table by ID and any enrolled procedure by
`{codeunitId, procedure}`. The runtime schema (what tables/fields/permissions exist) is discoverable
through the protocol itself (`discover` → `describe` → `capabilities`), so an agent can operate
against an unfamiliar tenant without prior knowledge.

## The sixteen operations

All sixteen are `[ServiceEnabled]` bound actions on `page 94100 "Bcmag Rpc Endpoint"`:

| | Operation | Purpose |
|---|---|---|
| **Data plane** | `discover` | List reachable tables / codeunits / companies (deny-by-default; codeunits only if invoke-enrolled), or the tenant's API catalog (`kind: "apis"`, with a `catalogVersion` fingerprint for caching). |
| | `describe` | Full schema for one table (fields, keys, primaryKey, permissions, captionML, per-field readable/writable policy, `apiRoutes`), the enrolled procedures of one codeunit, or one API page (`kind: "api"`: its fields mapped to table fields, and whether Wicket lets a client read through it). |
| | `query` | Read records — `select`/`filter`/`orderBy`/`top`/`cursor`/`count`; server-side `aggregate` (count/sum/avg/min/max); `modifiedAfter`/`modifiedBefore` bound the read by `SystemModifiedAt` (the incremental-sync pattern); rows carry `@recordId` + `@systemId` + `@etag`; `@nextLink` pagination — keyset (primary-key position) without `orderBy`, offset with it. A `deliver` block turns the query into an async export. |
| | `readBlob` | Fetch one binary (BLOB/Media) field as base64 + `contentType`, by the `@recordId` from a query row (at most 10 MB). |
| | `insert` | Create a record from `values` / `valuesByFieldNo`; returns `recordId` + `@etag`. |
| | `modify` | Update a record by `data.recordId`, optimistic concurrency via `data.etag`; primary-key fields are immutable (`400 pk-immutable`). |
| | `delete` | Delete a record by `data.recordId`, optimistic concurrency via `data.etag`. |
| **Control plane** | `invoke` | Run an enrolled wrapper codeunit by id (deny-by-default via the Procedure Catalog). |
| | `capabilities` | Machine-readable self-description: url template, transport contract, envelope, operation schemas, filter grammar, live limits, the enabled `actions`. |
| | `pageUrl` | Resolve a BC web-client deep link for one record (`table` by name or `#<number>`, `systemId`/`recordId`, optional `pageId`) — requires `Allow Read` exposure; returns `{ pageUrl, pageId }`. |
| | `whoAmI` | Report the calling principal and endpoint posture: `{ userSecurityId, userId, company, readOnly, fieldPolicy, strongEtag, serverTime }`. |
| **Async** | `status` | Track one async delivery request by `requestId` (strictly caller-scoped). |
| | `cancel` | Cancel one async request — outright if not started (scheduled or queued), cooperatively (at the worker's next checkpoint) if running. |
| | `requests` | List the caller's own async requests, newest first (`status?`, `top?`). |
| **Actions & guidance** | `action` | Run a named business action (e.g. posting) from the deny-by-default Action Catalog — a stable verb over the invoke plane. |
| | `skill` | Serve the protocol usage guide from a configured HTTPS URL, with progressive disclosure (`mode`: `toc` / `section` / `full`; https-only, 1 MB cap). |

### URL & transport

```
POST .../api/wicket/rpc/v1.0/companies({companyId})/wicketEndpoint(0)/Microsoft.NAV.{operation}
```

`wicketEndpoint(0)` is the fixed key segment. **Every call returns HTTP 200.**

**Wire format.** Business Central publishes a bound action only for simple parameter types, so the
envelope below travels as **one JSON string** in the action's single `envelope` parameter, and the result
comes back as **one JSON string** in `value`:

```http
POST .../wicketEndpoint(0)/Microsoft.NAV.whoAmI
Content-Type: application/json

{ "envelope": "{\"id\":\"…\",\"issuedAt\":\"2026-09-24T00:00:00Z\",\"origin\":\"my-agent\",\"data\":{}}" }
```

```json
{ "@odata.context": "…#Edm.String", "value": "{\"value\":{\"userId\":\"…\"},\"@requestId\":\"…\"}" }
```

Parse `response.value` once; call the parsed object the *result*. If it has **both** `type` and
`status` it is an RFC 7807 problem (`{ type, title, status, detail, instance, operation, suggest? }`);
otherwise it is the operation's result. A few problems add extension members (e.g. `replay-withheld`
carries `originalStatus` and `reason`). Text in `envelope` that is not one JSON object is answered
with `400 invalid-envelope`. (Until 2026-09-24 the page declared `JsonObject` parameters, which the
platform silently leaves out of `$metadata`: no operation was reachable over HTTP before that fix.)

### Request envelope (serialised into the `envelope` string)

```json
{
  "id": "uuid-v4",
  "issuedAt": "2026-05-08T00:00:00Z",
  "origin": "my-agent",
  "idempotencyKey": "optional-caller-key",
  "data": { /* operation-specific */ }
}
```

`id`, `issuedAt` (RFC 3339 UTC), `origin` (≤256 chars, `[A-Za-z0-9._@/+-:]`), and `data` are required.
`idempotencyKey` (≤128 chars) is optional, except for `invoke`/`action` while Wicket Setup
`Require Key For Actions` is on (the fresh-install default) — see [Idempotent writes](#idempotent-writes).

## Architecture

```
HTTP/OData
   │  POST .../wicketEndpoint(0)/Microsoft.NAV.{operation}
   ▼
page 94100 "Bcmag Rpc Endpoint"            one [ServiceEnabled] action per operation
   │
   ▼
codeunit "Bcmag Rpc Dispatcher" (94100)    envelope parse · idempotency replay · logging · telemetry · always-200
   │   key-required check · execution reservation ("Bcmag Idempotency Guard", 94147)
   │   query + "deliver" forks here: enqueue ("Bcmag Async Enqueue Run" boundary) → @async { requestId }
   │   Codeunit.Run boundary (error isolation + commit support)
   ▼
codeunit "Bcmag Op Runner" (94125) ──► "Bcmag Op Runner Context" (94126, single-instance)
   │   gates via "Bcmag Op Authorizer" (94148): Read-Only Mode, then the role rung
   │   ("Bcmag Role Gate", 94146) — the same gates re-check every idempotent replay — then routes:
   ▼
"Bcmag Op {Discover|Describe|Query|Read Blob|Capabilities|Insert|Modify|Delete|Invoke|
           Status|Cancel|Requests|Action|Skill|Page Url|Who Am I}"
        │            │              │                 │
        │            │              │                 ├─ invoke: "Bcmag Procedure Catalog" (94104)
        │            │              │                 │  + "Bcmag Invoke Context" (94123) → wrapper codeunit
        │            │              │                 └─ action: "Bcmag Action Catalog" (94107) → same
        │            │              │                    invoke context → wrapper (e.g. the Actions app)
        │            │              ├─ writes: "Bcmag Value Coercer" (94122) + "Bcmag Record Access" (94127)
        │            │              └─ aggregate: "Bcmag Op Aggregate" over the same filtered set
        │            └─ query filter: Filter Lexer → Parser → Applier (parameterised SetFilter)
        └─ projection: "Bcmag Projector" + "Bcmag Type Mapper" + "Bcmag Caption Resolver"
              (field policy consulted once per field per request: "Bcmag Field Policy")

src/async/  Enqueuer → Request Queue (durable) → Worker (StartSession / TaskScheduler)
            → Package Builder (NDJSON/JSON/ZIP) → Azure Blob upload → Reaper (stale + expiry + blob
              cleanup + queue retention; re-arms first, "Reaper Guard" 94153 as failure codeunit)

actions/    "Wicket Actions - Base" companion app: posting wrappers enrolled (disabled) into the
            catalogs; runs through Wicket's invoke plane, never around it
```

Cross-cutting:
- **Error isolation & commits.** Handlers run inside `Codeunit.Run`, so an unhandled AL `Error()`
  becomes a synthesised `500` and the write/invoke plane is still allowed to commit (a `[TryFunction]`
  could do neither).
- **Problem details.** `codeunit "Bcmag Problem"` builds RFC 7807 documents; handlers return
  `NewFailure(status, slug, title, detail)` / `NewFailureSuggest(...)`.
- **Audit.** Every call (success and failure) writes one `Bcmag Operation Log` row and emits a
  `Session.LogMessage` (event `WICKET-0001`). Async emits `WICKET-0002` (blob cleanup gave up),
  `WICKET-0003` (one per finished request), `WICKET-0004` (queue retention purge failed) and
  `WICKET-0005` (operation log retention purge failed; the reaper runs it automatically).
- **Identifiers.** `@recordId` is a base64-encoded `RecordId` token; `@systemId` is the record's
  stable GUID (what `action` targets); `@etag` is `base64(SystemModifiedAt)` by default. Opt-in
  **Strong ETag** (`Bcmag Setup."Strong ETag"`) folds a SHA256 hash of the record's field values into
  the etag, so a same-timestamp rewrite still misses — at the cost of a full field read+hash per row.

### Idempotent writes

The envelope `idempotencyKey` makes mutating calls (`insert`/`modify`/`delete`/`invoke`/
`action`, and async `deliver` enqueues) safe to retry: a duplicate call with the same key **replays**
the snapshot of the original response (same `@requestId`) without executing again; the same key with
a different request body is refused as a `409 idempotency-conflict` (also after an earlier attempt
released the key). Snapshots live in the `Bcmag Idempotency Log` (Response classified
`CustomerContent`); snapshots and reservations are purged with the operation log. An async acceptance
is snapshotted without the SAS token on its `packageUrl` — `status` hands out a freshly signed URL.

Wicket Setup `Require Key For Actions` (field 200; on for fresh installs, off after an upgrade) refuses
`invoke` and `action` calls without a key with `400 idempotency-key-required`: a wrapper may post and
commit, and only a key makes a lost response safely retryable.

The snapshot is a replay cache, not the guarantee. Before executing, the dispatcher takes a durable
**execution reservation** (`Bcmag Idempotency Reservation`, one row per caller and key, committed
before the runner) so that a key can run **at most once**: a duplicate that arrives while the first
request is still running gets `409 idempotency-in-progress` (retry later with the same key to receive
the result); a key whose earlier attempt settled but left no snapshot, or whose session died
mid-operation, gets `409 idempotency-indeterminate` — the earlier outcome is unknowable, so the caller
verifies the business result and retries with a **new** key rather than the framework re-executing.
A `5xx` releases the reservation for a retry with the same key — including a commit-time failure,
reported as `500 internal` with none of the operation's changes persisted — and so does a
pre-execution refusal an administrator can lift (`read-only`, `role-forbidden`, `not-exposed`,
`action-disabled`, `invoke-disabled`, `trigger-bypass-disabled`, `async-not-configured`,
`too-many-requests`): those are not cached, so the same key runs once the gate is fixed. Every other
4xx is final.

A replay is re-authorized at the moment of the resend (`Bcmag Op Authorizer`): the snapshot is handed
out only if the caller could still obtain it now — read-only mode, role rung, table exposure and BC
permission for the request's target, and the current field policy for every field the stored rows
carry (judged from the stored body itself, so a `select ["*"]` snapshot is covered), plus the fields
a stored query was filtered, ordered or windowed by; a row whose table cannot be determined fails
closed. Otherwise the resend gets `403 replay-withheld` with `originalStatus` and `reason` (the slug of
the refusal): the detail says the original request **completed**, so the caller must not repeat it
under a new key. The refusal is not stored, and the snapshot replays again once access is restored.

### Async delivery to Azure Blob

A `query` whose `data` carries a `deliver` block doesn't return rows — it is validated synchronously,
written as a durable `Bcmag Request Queue` row, and accepted with an `@async { requestId }` response.
A background worker (`StartSession` for immediate jobs, `TaskScheduler` for scheduled ones) then
re-runs the stored query **through the query op itself** — so exposure, field policy, and read-only
mode all still hold — pages it internally past the synchronous scan budget, packages the rows
(**NDJSON** default, **JSON** array, or **ZIP**), and uploads the package to Azure Blob Storage
(System-Application ABS client; Shared Key or ready-made SAS auth). The target table's exposure and
readability are checked at submit. The package URL carries a read SAS Wicket signs per blob (*Service
SAS*, the default: UTC times, `st` backdated 15 minutes, `spr=https`) or a pre-provisioned one (*Ready
SAS*, which must grant `r`, must not grant `l`, and must outlive the package TTL); the *Stream Proxy*
download mode is reserved for a proxy page that does not exist yet, and a `deliver` request is refused
with a typed problem while it is selected. The signed URL is composed at response time and never
stored — the queue row and its list page keep only the tokenless blob URL, and `status` re-mints a
fresh SAS on every call (capped at the package's expiry). The caller tracks the lifecycle with
`status`, lists its own requests with `requests`, and can `cancel` (a queued or scheduled request is
finalised at once, a running one cooperatively). If the platform cannot start a worker, the submit
answers `503 async-start-failed` and the row is marked failed. A self-re-arming reaper fails stale
runs, expires delivered packages when the TTL (default 24 h) has passed since the request **finished**
(`expiresAt` = `completedAt` + TTL; the accepted response's `expiresAt` is `null`), deletes the blob
where it was uploaded — the account, container and endpoint are recorded on the request row, so
repointing Setup later neither redirects the delete nor lets it confirm absence in the wrong place; a
delete that cannot be confirmed stays pending and is retried; cleanup is attempted only for a row whose
worker began an upload — and purges finished rows after `Operation Log Retention Days` (never a row
whose blob cleanup is still pending). Everything is strictly caller-scoped: another principal's
request is indistinguishable from a nonexistent one. Configure it on the Wicket Setup card (`Async
Enabled`, storage account/container, auth + download mode, TTLs, max active requests).

### Named actions & the companion app

`invoke` runs a wrapper by raw codeunit id; `action` runs a **named business verb** (e.g.
`post-sales`) from `table "Bcmag Action Catalog"` — with a description, category, mutates/preview
metadata, and an args schema, all discoverable via `capabilities` → `actions` (every enrolled verb, with
`enabled`). The catalog is deny-by-default: an action is reachable only when a row exists **and** `Allow
Run` is set. A preview, and every verb enrolled with `Is Mutating` off, runs inside a forced rollback
(`codeunit "Bcmag Action Rollback"`: explicit commits ignored, for a non-mutating verb a nested
committing `Codeunit.Run` refused, every write undone), so it may run on a read-only endpoint without an
idempotency key. A preview relies on its wrapper honouring `args.preview` (BC's preview engine is itself a
nested run, so it cannot take that guard); the companion's posting wrappers do. Any invoke
wrapper can be a provider; the action runs through the same invoke context, so no Wicket core change is
needed per action.

The **Wicket Actions - Base** companion app ([`actions/`](actions/), range `94200–94249`) supplies the
wrappers a System-Application-only core cannot own: posting sales and purchase documents and general
and item journal batches through the Base Application's posting routines (each with a real
`preview: true` on Business Central's own posting-preview engine), releasing and reopening sales and
purchase documents, converting quotes into orders and invoices, and two non-mutating verbs —
`document-pdf` (the PDF a document's Print action produces) and `item-availability` (Available to
Promise) — plus new-company enrolment. On install it enrols its actions and procedures
**disabled** (`Allow Run` and `Allow Invoke` start false) — an admin enables each one explicitly on the
catalog pages, per company; an upgrade refreshes the companion-owned metadata of existing rows
(description, wrapper id, category, mutating/preview flags, args schema), never `Allow Run`. When a posting routine commits
and then fails in later code (an after-posting subscriber, the analysis-view refresh), the wrapper
reports `posted: true` with `postCommitWarning` + `postCommitEvidence` instead of a failure, so a
caller is never told to post a posted document again. Return orders default to receive/ship + invoice;
for credit memos and return orders `postedInvoiceNo` is the posted credit memo number. The journal
wrappers enforce Gen. Jnl.-Post's refusals (Force Posting Report, Job G/L WIP source code).

## Security model

- **Deny-by-default exposure.** `table "Bcmag Exposure"` gates each object: `Allow Read/Insert/Modify/
  Delete/Invoke`. `Bcmag Setup.Mode` = **Exposed tables only** (default; API name `Allowlisted`) honours the table; `Open` (sandbox) bypasses
  the per-row check for reads/writes — but **never for invoke** unless `Allow Invoke In Open Mode` is set.
- **API Routing (off by default).** `Bcmag Setup."API Routing"` (`Off` / `Prefer`) decides whether a
  client may read through one of the tenant's own API pages instead of the dynamic plane. The catalog
  itself (`discover kind:"apis"`, `describe kind:"api"`) is always visible; `describe kind:"api"`
  answers `routable` and per-field `readable` under the CURRENT exposure list, BC permissions and
  field policy, and the MCP server asks it fresh before every API read. Such a read never passes the
  endpoint, so it is not in the Operation Log (the MCP server logs one stderr line per read).
- **Read-Only Mode master switch.** `Bcmag Setup."Read-Only Mode"` refuses every mutating operation
  (`insert`/`modify`/`delete`/`invoke`/`action`) in the dispatcher, ahead of Mode, exposure, field
  policy, and BC permission checks. Action previews and non-mutating verbs pass: they run inside the
  forced rollback.
- **Field-level policy.** BC has no native per-column security, so `codeunit "Bcmag Field Policy"`
  decides per field, on every surface that resolves a field (select, `*` expansion, filter, orderBy,
  aggregate, readBlob, writes, describe), whether a caller gets it **Hidden**, **Masked** or **Clear**.
  Three modes: **AllFields** (v1.1 back-compat, overrides ignored), **ByClassification** (fresh-install
  default: a classification rule per `DataClassification` — CustomerContent and SystemMetadata Clear,
  EUII and EUPI Masked, the rest Hidden — plus per-field override rows) and **Explicit** (a field is
  Hidden unless it has a row). A masked value is rendered from a mask profile (partial, e-mail, fixed
  text, keyed hash, null), named in the row's `@masked`, and refused as a filter, sort, aggregate or
  write-back (`403 field-masked`, `400 masked-value`). The `Wicket - Unmask` permission set and per-user
  exceptions lift Masked to Clear (audited in the Operation Log); a request or MCP connection can opt
  out with `"unmask": false`. Masking governs the Wicket plane only — direct API/OData/web-client
  access still sees clear values. Primary-key fields are always accessible; a hidden field fails
  typed (`403 field-restricted`). Aggregates enforce the same policy (no inference oracle).
- **BC permissions still apply.** Exposure is necessary but not sufficient: the app principal must also
  hold the relevant tabledata read/write permissions. The real check happens at action time.
- **Invoke is doubly gated; action is triply named.** A codeunit must be exposed for invoke **and** the
  `{codeunitId, procedure}` pair enrolled in `table "Bcmag Procedure Catalog"` with `Allow Run = true`;
  a named action additionally needs its `Bcmag Action Catalog` row enabled. No reflection over
  arbitrary methods — only small, auditable, enrolled **wrapper** codeunits ever run.
- **Write-path hardening.** Writes re-fetch the record from its opaque token under `SecurityFilter::
  Filtered` (a forged/stale token can't escape the caller's security scope; the token's table is judged
  before the row is read) and enforce optimistic concurrency from `data.etag` (`412` on mismatch).
  `modify` refuses a primary-key change (`400 pk-immutable`). Skipping triggers (`init: false`,
  `validate: false`) is a tenant policy — Wicket Setup `Allow Trigger Bypass` (field 201; off for fresh
  installs, on after an upgrade), else `403 trigger-bypass-disabled`. `action` owns `args.preview`
  (`data.preview: true` forces it; a caller's own `args.preview` is `400`), refuses non-object `args`
  and a `target.systemId` that contradicts `args.systemId`.
- **Filter injection.** Comparisons and `in (...)` reach BC as `SetFilter` `%n` parameters, which the
  platform treats as exact literals (CI-verified: `"No." eq '*'` matches only a literal `*`); `in`
  members are typed per literal kind and parsed invariantly, and a malformed list (missing/trailing
  comma, `null`) is a `400`. Text
  functions use a quoted literal with the wildcard *inside* the quotes, which neutralises `& ( ) = |`
  but not `*`/`?` — those stay wildcards inside a `startswith`/`endswith`/`contains` value, a documented
  platform property that can only widen the caller's own pattern.
- **Audit tables are never readable through the data plane.** The Operation Log, the Idempotency Log
  (which stores every idempotent write's full response), the Idempotency Reservation and the Request
  Queue (each caller's stored query and package URL) are refused for `read` in every Mode, Open
  included, and `discover` never lists them — otherwise one principal could read across all the
  others. Only the admin pages show them.
- **Permission sets are a privilege ladder, enforced by the platform.** The extension ships composable
  sets (`app/permissionSet/`):
  `Wicket - Read` (the read operations, async delivery, status/cancel/requests; Insert on the log and
  queue tables only), `Wicket - Execute` (adds `invoke`/`action`), `Wicket - Edit` (adds
  `insert`/`modify`/`delete`), `Wicket - Audit` (read-only view of every admin page and log) and
  `Wicket - Admin` (the control plane: exposure, setup, catalogs, credential, log purge). Each step
  grants Execute on the handler codeunits it names **and** full rights on one empty **role-gate**
  table (`Bcmag Execute Gate` from Execute up, `Bcmag Write Gate` from Edit up). The dispatcher checks
  `WritePermission` on the gate before routing `invoke`/`action` or `insert`/`modify`/`delete`, so a
  principal below the rung gets a typed `403 role-forbidden` with no side effects — even when Read-Only
  Mode is off, its other sets allow the table write, or it holds a `codeunit * = X` wildcard (permission
  sets are additive and cannot carve an exception out of a wildcard; the gate can). None of these
  grants business data; `Wicket Data - Read` (`tabledata * = R` + table/page/query Execute) and
  `Wicket Data - Exec` (+ Execute on every codeunit/report/xmlport; its wildcard reaches the write
  handlers too, but the Write Gate keeps the generic write plane closed) are the generic one-assignment
  roles for "read any information" and "read and execute".

## Install & build

**Prebuilt packages:** download `Wicket_<version>.zip` and, for posting actions,
`Wicket_Actions_Base_<version>.zip` from [Releases](https://github.com/davesmith7403/wicket-bc/releases), unzip
them, and upload the `.app` files in the Business Central admin center (**Manage Apps → Install Extension**),
core app first.

**Building from source** — prerequisites: VS Code + the **AL Language** extension, or the `alc` compiler, plus the BC 26.0 symbol
package. The core extension depends on Microsoft **System Application** `26.0.0.0` only; the optional
Actions app additionally needs the Base Application symbols.

```bash
# from the repo root — main app
# Each app lives in its OWN folder. Never point alc at the repo root: it globs *.al
# recursively, so a root compile swallows actions/ and test/ (115 files instead of 80,
# failing AL0185 + AL0297). AL has no exclude mechanism; separate folders are the fix.
alc /project:./app /packagecachepath:./.alpackages /out:Wicket.app

# companion Actions app (optional; range 94200–94249; depends on the main app)
alc /project:./actions /packagecachepath:./actions/.alpackages /out:Wicket_Actions_Base.app

# test app (range 94300–94349; depends on the main app, Library Assert and Test Runner)
alc /project:./test /packagecachepath:./test/.alpackages /out:Wicket_Tests.app
```

Or press **F5** in VS Code to publish to your configured BC sandbox. The AL extension needs `app.json`
at the opened folder's root, so **open `app/`** (or `actions/` / `test/`) rather than the repo root,
and copy [`app/.vscode/launch.json.example`](app/.vscode/launch.json.example) to
`app/.vscode/launch.json` with your tenant and environment first (`launch.json` is gitignored
everywhere; it names a real tenant). On install,
`codeunit "Bcmag Install"` materialises the `Bcmag Setup` singleton; exposure stays empty and every
enrolled action/procedure starts disabled (deny-by-default).

Then, in BC:
1. Register the app principal — see [docs/setup-entra.md](docs/setup-entra.md).
2. Assign a Wicket role — `Wicket - Read`, `Wicket - Execute` or `Wicket - Edit` for the calling
   principal, `Wicket - Admin` for the operator — plus permissions for the data in scope (for an
   agent that may read everything, `Wicket Data - Read` is that in one assignment).
3. Enrol tables in **Wicket Exposure**; for invoke, enrol procedures in **Wicket Procedure Catalog**;
   for named actions, enable the rows in **Wicket Action Catalog**.
4. For async delivery, fill in the Azure Storage settings on the **Wicket Setup** card and switch
   `Async Enabled` on.

Smoke-test with [docs/smoke-test.http](docs/smoke-test.http) (VS Code REST Client) — one request per
operation, all sixteen.

## Using it as an agent

The agent side of Wicket lives in its own repository, **[davesmith7403/wicket](https://github.com/davesmith7403/wicket)**:

- **Plugin:** the MCP server, the usage skill and the `/wicket:orient` and `/wicket:inventory`
  commands in one install (`/plugin marketplace add davesmith7403/wicket`, then
  `/plugin install wicket@wicket`).
- **MCP server:** a Model Context Protocol server (TypeScript / Bun) exposing **23 `wicket_*` tools**,
  one per Wicket operation plus async export, paging, API-first reads, the per-connection tenant map
  and multi-connection setups (service principal or device-code sign-in). It builds the envelope,
  POSTs each bound action, and unwraps `response.value`, surfacing the RFC 7807 problem on failure.
- **Usage skill:** how an agent should orient, filter, write, post and present results. Its
  single-file edition, `docs/wicket-usage-skill.md` in that repository, is what the endpoint's `skill`
  operation serves (see the Product Guide, *Serving the usage guide*).

Agents without MCP can still call the endpoint directly with their HTTP tooling, guided by the skill.
The runtime truth always lives behind `capabilities`/`describe`.

## Documentation

- [Product Guide](docs/Wicket-Product-Guide.md) — the complete manual: concepts, installation, security setup, first steps, every operation, configuration scenarios, the MCP server. Also as [PDF](docs/Wicket-Product-Guide.pdf) and as a [web page](https://davesmith7403.github.io/wicket-bc/) generated from the Markdown.
- [Entra ID setup](docs/setup-entra.md) — app registration, permission sets, read/write/invoke authority.
- [Smoke-test recipe](docs/smoke-test.http) — one request per operation.
- [Versioning & deprecation policy](docs/versioning.md) — what may change without notice, and how breaking changes are announced.
- [Plugin, MCP server and skill](https://github.com/davesmith7403/wicket) — the agent-facing side, in its own repository.

## Status

The full plane is **code-complete**: read/write/invoke, the capabilities manifest, field-level policy,
idempotent writes, named actions (core framework + the Actions companion app), the `skill` guide
operation, and async Azure Blob delivery with its `status`/`cancel`/`requests` lifecycle.

Verification status:
- **CI** (AL-Go, BC 26 container): the core and companion test suites run on every push to `main`
  and on pull requests to it. The container is configured to match SaaS try-function semantics
  (`.AL-Go/NewBcContainer.ps1`).
- **Live SaaS sandbox** (BC 28): the core and companion suites (`test/`, `actions-test/`) also run
  headless against a cloud sandbox through the test-runner web service, together with live HTTP
  calls through the published bound actions.
- **Still pending:** an async delivery round-trip against real Azure Storage (the Service SAS
  string-to-sign is still unverified against Azure) and a restricted-identity permission matrix.

## License

[MIT](LICENSE). Contributions are welcome — see [CONTRIBUTING.md](CONTRIBUTING.md); report security
issues as described in [SECURITY.md](SECURITY.md).
