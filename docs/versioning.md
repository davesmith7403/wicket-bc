# Wicket — versioning & deprecation policy

This is the contract Wicket keeps with its callers (LLM agents, backend services, the companion
skill). It tells an integrator what is allowed to change without warning, what is not, and how a
wire change is announced.

## Version surfaces

There are three distinct version numbers; do not conflate them.

| Surface | Where | Bumps when | Caller impact |
|---|---|---|---|
| **URL major version** | the `v1.0` segment in `/api/wicket/rpc/v1.0/...` (the API page's `APIVersion`) | a **breaking wire change** is unavoidable | new path; old path stays online for the deprecation window |
| **Data schema version** | `schemaVersion` in `describe` and `capabilities` responses (currently `"1.0"`) | the shape of an operation's `data` / result changes in a way callers can branch on | additive changes do **not** force a new URL |
| **Extension version** | `app.json` `version` (currently `1.4.1.0`) | any release | release/upgrade tracking only; not a wire contract |

The URL segment is the only hard compatibility boundary. `app.json` can go from `1.3` to `1.9`
shipping new operations and fields without ever touching the URL, as long as the additive rule below holds.

## The additive rule (non-breaking changes)

Within a single URL major version, these changes are **allowed without notice** and callers must
tolerate them:

- **New operations** (new `[ServiceEnabled]` bound actions on the API page). They appear in
  `capabilities.operations[]`; callers that don't know them simply don't call them.
- **New optional fields in an operation's `data`.** Defaults must preserve existing behaviour.
- **New fields in a result object.** Callers must ignore unknown keys (`@`-prefixed control keys
  included: `@recordId`, `@etag`, `@nextLink`, `@count`, `@pagingMode`, `@requestId`).
- **New problem `type` slugs, new `suggest` keys**, new telemetry dimensions, new enum members in
  catalog/setup tables.
- **Relaxed limits** (e.g. a higher `Max Top`). Limits are advertised live in `capabilities.limits`,
  so a caller reads them rather than hard-coding them.

Corollary for clients: **never reject a response for having extra fields**, and read limits and the
operation list from `capabilities` instead of assuming them.

## Breaking changes (require a new URL major version)

These are the changes that force `v1.0 → v2.0`:

- Removing or renaming an operation, a `data` field, or a result field.
- Changing the type or meaning of an existing field.
- Changing the transport contract (always HTTP 200, the result in `response.value`, and a value with
  `type` and `status` being an RFC 7807 problem).
- Changing the envelope's required fields (`id`, `issuedAt`, `origin`, `data`).
- Tightening a limit or changing default behaviour in a way that breaks existing callers.

A breaking change ships as a **new API page** with a new `APIVersion` (e.g. `v2.0`) and its own bound
actions. The old page stays published and unchanged for the deprecation window. A live `v1.0`
action's contract is never mutated in place. (A surgical, single-operation break can instead ship as
a new path leaf — e.g. `queryV2` — leaving the rest of `v1.0` intact.)

## Deprecation lifecycle

1. **Announce.** A deprecation is announced in the release notes and in the `wicket-usage` skill
   before the replacement ships.
2. **Co-exist.** The new URL major version ships alongside the old. Both are live.
3. **Deprecation window.** The old version stays online for **at least 12 months** from the release
   of its replacement.
4. **Sunset.** After the window, the old API page may be removed in a major `app.json` release. The
   removal is itself called out in the release notes.

## How wire changes are announced

- **Authoritative, machine-readable:** the `capabilities` operation. Its `schemaVersion`, `operations[]`,
  `filterGrammar`, and `limits` are the live source of truth. An agent that disagrees with the skill
  should trust `capabilities` and `describe`.
- **Per-table/-codeunit shape:** `describe` carries its own `schemaVersion`; branch on it if you cache schema.
- **Human-readable:** the release notes of each GitHub release, listing additive vs. breaking changes.
- **Skill:** the usage skill in the [plugin repository](https://github.com/davesmith7403/wicket) is updated in lockstep, but is explicitly **static**
  guidance — the runtime truth is `capabilities`/`describe`.

## Current state

- **Version 1.4.1.0** (companion `0.3.1.0`, AL-Go `repoVersion` `1.4`; plugin and MCP server `2.6.1`).
  A fix release with no new operation, table or Setup field and no upgrade code. **Upgrade from
  1.4.0.0:** two of its fixes are needed for 1.4.0.0 to work for a caller below `Wicket - Admin`:
  - the change recorder no longer modifies a row the data-plane sets only let it insert (every
    generic write answered 500 with Record Changes on, the default);
  - `capabilities` no longer calls the Edit-rung batch handler (500 for a principal on the Read or
    Execute rung that holds no codeunit wildcard such as D365 BASIC).
- **Stricter on the wire in 1.4.1.0** (none widens access):
  - `post-sales` and `post-purchase` refuse what the Post action on the document page refuses (an
    enabled approval workflow with the document not approved, unpaid prepayments) and never post a
    quote or blanket order; the quote conversions make the quote page's approval check. A preview
    meets the same refusals.
  - A `systemId` sent with a `documentType` or `no` that names another document is refused.
  - A batch `{ fromItem, field }` reference needs the earlier item's table exposed for read
    (`403 not-exposed`); a FlowFilter, Blob or Media field is `400 invalid-reference`.
  - `describe` of an API page over a temporary source table answers `routable: false`,
    `notRoutableReason: "temporary-source"`.
  - The change history renders a masked non-text field as a read does (nothing, a hash token or the
    fixed text); `changes` shows no values for a table not exposed for read, and a stored `changes`
    answer is re-judged before it is replayed.
  - `query` answers `403 not-exposed` when the caller lacks the table's read permission.
  - Strong ETags on tables with field numbers of 1000 and above miss once after the upgrade
    (`412`, re-read): the hash input is now locale-invariant.
- **Additive in 1.4.1.0:** a chained batch item (`recordId: { fromItem }`) with no `etag` is given
  the record's current one, so it runs where **Require ETag On Writes** is on; the Operation Log row
  of a batch carries `n items` and each item's op, table and field names; `Wicket - Audit Changes`
  works when assigned alone; the maintenance task that purges the logs is re-armed from the request
  path.
- **Version 1.4.0.0** added the `batch` and `changes` operations and the change history (Setup group
  *Change History*; an upgraded tenant begins to record what the agent changes).
- **Version 1.3.0.0** (companion `0.3.0.0`, AL-Go `repoVersion` `1.3`, MCP server `2.3.0`).
- **Behaviour to know before upgrading from an earlier build.** The core enforces the action
  catalog's `Is Mutating`: a verb marked non-mutating runs inside a forced rollback, so whatever it
  writes is undone and only its result comes back. The companion's upgrade only ever tightens
  `Is Mutating`, so its own posting verbs stay mutating. A third-party wrapper enrolled as
  non-mutating that actually writes would silently stop persisting its writes: check such rows
  (Action Catalog) before upgrading.
- Upgrade the companion together with the core: `Wicket Actions - Base` 0.3.0.0 requires Wicket
  1.3.0.0, because its non-mutating verbs (document-pdf, item-availability) depend on the rollback.
- Business Central upgrades an installed extension only to a higher version, and the upgrade
  codeunits carry work later builds depend on, so always bump `app.json` when shipping.

## Client guidance in one line

Pin the **URL major version**; read everything else (operations, limits, schema) from `capabilities`
and `describe` at runtime; ignore unknown fields; follow `@nextLink` until it is absent.
