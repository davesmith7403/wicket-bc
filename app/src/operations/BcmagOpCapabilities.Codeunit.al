codeunit 94119 "Bcmag Op Capabilities"
{
    // Machine-readable self-description so any agent framework can auto-discover the tool
    // surface — the real bound-action URL shape, the envelope, the operation list with data
    // schemas, the $filter grammar, and the live limits — without trusting static skill text.

    var
        FilterApplier: Codeunit "Bcmag Filter Applier";
        AppInfo: Codeunit "Bcmag App Info";
        OpBatch: Codeunit "Bcmag Op Batch";
        SchemaVersionTok: Label '1.0', Locked = true;

    procedure Run(Data: JsonObject; var Response: JsonObject; var Fail: JsonObject; var Cost: Integer): Boolean
    var
        Setup: Record "Bcmag Setup";
        Caps, Transport, Envelope, Limits, FilterGrammar, FieldPolicyObj: JsonObject;
        Operations: JsonArray;
    begin
        Cost := 0;
        Setup.GetSingleton();

        Caps.Add('product', 'Wicket');
        Caps.Add('apiVersion', 'v1.0');
        Caps.Add('schemaVersion', SchemaVersionTok);
        Caps.Add('urlTemplate', '/api/wicket/rpc/v1.0/companies({companyId})/wicketEndpoint(0)/Microsoft.NAV.{operation}');

        Transport.Add('httpStatus', 'always-200');
        // Bound actions take and return Text (the platform does not publish JsonObject parameters), so
        // the envelope and the result each cross the wire as ONE serialised JSON string.
        Transport.Add('requestBody', '{"envelope": "<the envelope serialised as a JSON string>"}');
        Transport.Add('resultPath', 'response.value');
        Transport.Add('resultEncoding', 'response.value is a string holding the result serialised as JSON; parse it once');
        Transport.Add('errorShape', 'RFC 7807; a response.value with "type" and "status" is a problem document, otherwise it is the result');
        Transport.Add('idempotency', 'set envelope.idempotencyKey to make a write safe to retry; a retry with the same key + same {operation,data} replays the stored result verbatim with "@replayed":true; the same key with a different {operation,data} returns 409 idempotency-conflict. Replay is scoped to the calling principal; only outcomes with status < 500 are stored.');
        Caps.Add('transport', Transport);

        Envelope.Add('id', 'uuid v4 (required)');
        Envelope.Add('issuedAt', 'RFC 3339 UTC (required)');
        Envelope.Add('origin', 'caller tag, <=256 chars matching [A-Za-z0-9._@/+-:] (required)');
        Envelope.Add('idempotencyKey', 'optional, <=128 printable chars; see transport.idempotency');
        Envelope.Add('data', 'operation-specific object (required)');
        Caps.Add('envelope', Envelope);

        AddOperation(Operations, 'discover', 'List reachable tables/codeunits/companies, or the tenant''s API catalog', '{ kind: "tables"|"codeunits"|"companies"|"apis", filter?, publisher?, top?, languages? }. Table and codeunit rows carry app { id, name, publisher, version } (null for platform objects); publisher is an AL filter on the owning app''s Publisher, e.g. "<>Microsoft" for solution objects. kind "apis" also takes tableId?, skip?, ifNoneMatch? and returns { value: [ { id, apiKind: "page"|"query", name, entitySetName, entityName, route, routes, sourceTableId?, operations } ], catalogVersion, apiRouting, @count, @nextSkip? }; its filter is an AL filter on the entity set name. Pass a cached catalogVersion as ifNoneMatch: when unchanged the rows are omitted and notModified is true (see "apiRouting")');
        AddOperation(Operations, 'describe', 'Full schema for one table, enrolled codeunit, or API page', '{ kind: "table"|"codeunit"|"api", tableId?|codeunitId?|pageId?|queryId?, languages?, ifNoneMatch?, include?: { referencedBy? } }. A table carries app { id, name, publisher, version }|null and describeVersion, a hash of the answer as this caller sees it: pass it back as ifNoneMatch and an unchanged answer is { tableId, describeVersion, notModified: true }. include.referencedBy adds referencedBy [ { tableId, tableName, fieldNo, fieldName } ] (the readable fields of readable tables whose TableRelation targets this one; referencedByTruncated past 200). A table also lists apiRoutes (the API pages over it); each readable field carries access "clear"|"masked", and a masked one also mask { profile, kind } with filterable:false and sortable:false. kind "api" returns the API''s routes, sourceTableId, sourceTableView, operations, fields [ { name, mapped, fieldNo?, tableId?, readable } ], routable, notRoutableReason?, catalogVersion');
        AddOperation(Operations, 'query', 'Read records', '{ tableId, select?|selectFieldNo?, filter?, orderBy?, top?, skip?, cursor?, count?, include?, aggregate?, modifiedAfter?, modifiedBefore? }. modifiedAfter/modifiedBefore (ISO 8601 datetime strings) constrain SystemModifiedAt (>= / <=), AND-composed with filter and applied to row pages AND aggregates; a filter that itself constrains SystemModifiedAt cannot be combined with them (400), and an inverted window (modifiedAfter later than modifiedBefore) is rejected (400) rather than silently selecting nothing. select accepts ["*"] to mean every readable non-binary field (it narrows to what the field policy permits, so it may return fewer fields than describe lists). aggregate: { count?: bool, sum?: [fields], avg?: [fields], min?: [fields], max?: [fields] } composes only with filter and returns ONE summary object { count?, sum?: {field:number|string}, avg?/min?/max?: {field:number|string|null} } instead of rows (avg/min/max are null on an empty set; large decimals are invariant strings). All aggregated fields must be policy-readable. A field the caller may read only masked is emitted as its mask rendering (see describe access/mask) and the row names it in "@masked": [field names]; data.unmask: false asks for the baseline view without the caller''s unmask grants.');
        AddOperation(Operations, 'readBlob', 'Fetch one binary field (base64 in v1)', '{ tableId, recordId, fieldNo }. A binary field the caller may read only masked is refused (403 field-masked): bytes have no masked form.');
        AddOperation(Operations, 'insert', 'Create a record', '{ tableId, values|valuesByFieldNo, init? }');
        AddOperation(Operations, 'modify', 'Update a record (optimistic via data.etag)', '{ tableId, recordId, values|valuesByFieldNo, etag?, validate? }');
        AddOperation(Operations, 'delete', 'Delete a record (optimistic via data.etag)', '{ tableId, recordId, etag? }');
        AddOperation(Operations, 'batch', 'Insert, modify and delete many records in one call and one transaction: all are written or none (see limits.maxBatchItems)', '{ items: [ { op: "insert"|"modify"|"delete", tableId, recordId?, values?|valuesByFieldNo?, etag?, validate?, init? } ], preview? } -> { items: [ { index, op, recordId, @etag?|deleted } ], count, preview? }. A failure names the item ("item", "itemOp"; detail starts items[i]) and nothing is written. preview: true runs every item and rolls back. A value or recordId may be { fromItem: n, field?: "<name>", fieldNo? }: a field of, or the record from, an earlier item (an order header''s "No." for its lines); the field must be readable in clear.');
        AddOperation(Operations, 'invoke', 'Run an enrolled procedure', '{ codeunitId, procedure, args?, returnShape? }');
        AddOperation(Operations, 'capabilities', 'This document', '{ }');
        AddOperation(Operations, 'status', 'Track one async delivery request (see "async")', '{ requestId } -> { requestId, status, packageFormat, createdAt, scheduledFor, startedAt, completedAt, expiresAt, progressRows, resultRowCount, resultBytes, packageUrl?, problem? }');
        AddOperation(Operations, 'cancel', 'Cancel an async request (before or during execution)', '{ requestId } -> { requestId, status }');
        AddOperation(Operations, 'requests', 'List the caller''s async requests', '{ status?, top? } -> [ status-projection ]');
        AddOperation(Operations, 'changes', 'What the agent created, changed or deleted, and the actions and procedures it ran, old and new per field (Setup: Change History)', '{ from?, to?, tableId?, viaConnection?, kind?: "created"|"changed"|"deleted"|"action"|"procedure", user? (Wicket - Audit Changes only), top?, cursor? } -> [ { entryNo, createdAt, kind, tableId, tableName, recordKey, systemId?, user, connection, requestId, name?, outcome?, result?, fieldCount, fields: [ { fieldNo, fieldName, shownAs: "clear"|"masked"|"hidden", old?, new?, truncated? } ] } ], @nextLink?. Your own entries unless you hold Wicket - Audit Changes; 403 changes-off when the history is off or not readable by the agent.');
        AddOperation(Operations, 'action', 'Run a named business action (see "actions")', '{ action, target?: { systemId }, args?, preview? }');
        AddOperation(Operations, 'skill', 'Fetch the usage guide with progressive disclosure', '{ mode?: "toc"|"section"|"full", section? } -> toc: { title, description?, sections[] }; section: { section, content }; full: { content }');
        AddOperation(Operations, 'pageUrl', 'Deep link into the BC web client for one record', '{ tableId | table: "<name>"|"#<no>", systemId?|recordId? (one required; systemId wins), pageId? } -> { pageUrl, pageId }. Uses the table''s default lookup page when pageId is omitted (404 no-page if the table has none). Requires read exposure on the table.');
        AddOperation(Operations, 'whoAmI', 'Identify the calling principal and endpoint posture', '{ } -> { userSecurityId, userId, company, readOnly, fieldPolicy, unmaskGranted, activeExceptions, strongEtag, serverTime }');
        Caps.Add('operations', Operations);

        FilterGrammar.Add('comparison', 'eq ne gt ge lt le');
        FilterGrammar.Add('logical', 'and (chaining); same-field disjunction via in(...)');
        FilterGrammar.Add('functions', 'startswith endswith contains');
        FilterGrammar.Add('membership', 'F in (''a'',''b'')');
        FilterGrammar.Add('null', 'F eq null / F ne null');
        FilterGrammar.Add('literals', 'boolean fields: F eq true / F eq false; string apostrophes are doubled OData-style: Name eq ''O''''Brien''');
        FilterGrammar.Add('fieldByNumber', '#22');
        FilterGrammar.Add('wildcards', 'inside a startswith/endswith/contains value, * and ? are live wildcards (the platform has no escape for them); in comparisons and in(...) every value is exact, including * and ?');
        FilterGrammar.Add('inListMax', StrSubstNo('in(...) accepts at most %1 values (see limits.maxInMembers); split longer lists across queries', FilterApplier.MaxInMembers()));
        FilterGrammar.Add('unsupported', 'cross-field or, standalone not, arithmetic, lambdas, cast/isof');
        Caps.Add('filterGrammar', FilterGrammar);

        Limits.Add('defaultTop', Setup."Default Top");
        Limits.Add('maxTop', Setup."Max Top");
        Limits.Add('maxFilterLength', Setup."Max Filter Length");
        Limits.Add('maxSelectFields', Setup."Max Select Fields");
        Limits.Add('scanBudget', Setup."Per-Call Scan Budget");
        Limits.Add('maxInMembers', FilterApplier.MaxInMembers());
        Limits.Add('maxBatchItems', OpBatch.MaxItems());
        Caps.Add('limits', Limits);

        Caps.Add('readOnly', Setup."Read-Only Mode");
        // Moves when an app is installed, upgraded or removed: a client's structural knowledge of the
        // tenant (a schema cache, a tenant map) should be re-verified when it changes.
        Caps.Add('structureVersion', AppInfo.StructureVersion());
        // @etag concurrency strength: false = base64(SystemModifiedAt) (millisecond granularity);
        // true = also folds a field-value hash so same-millisecond changes are still detected.
        Caps.Add('strongEtag', Setup."Strong ETag");
        // Invariant enum member name, not Format() (the caption in the session language).
        Caps.Add('exposureMode', Setup.Mode.Names().Get(Setup.Mode.Ordinals().IndexOf(Setup.Mode.AsInteger())));
        FieldPolicyObj.Add('mode', FieldPolicyModeName(Setup."Field Policy Mode"));
        FieldPolicyObj.Add('classifications', Classifications());
        FieldPolicyObj.Add('maskProfiles', MaskProfiles());
        FieldPolicyObj.Add('unmaskTierEnabled', Setup."Unmask Tier Enabled");
        FieldPolicyObj.Add('principal', Principal());
        FieldPolicyObj.Add('describeRestrictedFields', Setup."Describe Restricted Fields");
        Caps.Add('fieldPolicy', FieldPolicyObj);
        AddAsync(Caps, Setup);
        AddApiRouting(Caps);
        AddActions(Caps);
        // Protocol education: when a skill doc URL is configured, `skill` serves it with progressive
        // disclosure so any client learns the plane without repo access.
        Caps.Add('skill', Setup."Skill Doc Url" <> '');
        Caps.Add('paging', 'continuation via the @nextLink cursor; follow until absent. Without orderBy paging is keyset (resumes after the last primary key, each page scans only its own rows); with orderBy it is offset (skipped rows count against the scan budget). @pagingMode says which');

        Clear(Response);
        Response.Add('value', Caps);
        exit(true);
    end;

    // Explicit case map — Format() of an enum yields the locale-dependent caption, never a
    // stable machine identifier. Public: whoAmI emits the same invariant name.
    procedure FieldPolicyModeName(Mode: Enum "Bcmag Field Policy Mode"): Text
    begin
        case Mode of
            Mode::AllFields:
                exit('AllFields');
            Mode::ByClassification:
                exit('ByClassification');
            Mode::Explicit:
                exit('Explicit');
        end;
        exit('Unknown');
    end;

    // One entry per classification: the effective rule (row, else the built-in default) as
    // { name, access, maskProfile } with invariant names — only consulted in ByClassification mode,
    // but emitted always so agents need no conditional parsing. maskProfile is '' unless Masked.
    local procedure Classifications() Arr: JsonArray
    var
        PolicyDefaults: Codeunit "Bcmag Policy Defaults";
        DataClass: Enum "Bcmag Data Class";
        Access: Enum "Bcmag Read Access";
        ProfileCode: Code[20];
        Entry: JsonObject;
        Ordinal: Integer;
    begin
        foreach Ordinal in Enum::"Bcmag Data Class".Ordinals() do begin
            DataClass := Enum::"Bcmag Data Class".FromInteger(Ordinal);
            PolicyDefaults.ClassificationRule(DataClass, Access, ProfileCode);
            if Access <> Access::Masked then
                ProfileCode := '';
            Clear(Entry);
            Entry.Add('name', PolicyDefaults.ClassName(DataClass));
            Entry.Add('access', ReadAccessName(Access));
            Entry.Add('maskProfile', ProfileCode);
            Arr.Add(Entry);
        end;
    end;

    // Every mask profile as { code, kind, keepFirst, keepLast, minHidden, preserveLength }, so an agent
    // can tell from a describe field's mask.profile what the rendering keeps. The kind is the masker's
    // invariant name (the same one describe emits). A caller without read permission on the profile
    // table gets an empty list rather than a failed manifest.
    local procedure MaskProfiles() Arr: JsonArray
    var
        Profile: Record "Bcmag Mask Profile";
        Masker: Codeunit "Bcmag Field Masker";
        Entry: JsonObject;
    begin
        if not Profile.ReadPermission() then
            exit;
        if Profile.FindSet() then
            repeat
                Clear(Entry);
                Entry.Add('code', Profile.Code);
                Entry.Add('kind', Masker.KindName(Profile.Code));
                Entry.Add('keepFirst', Profile."Keep First");
                Entry.Add('keepLast', Profile."Keep Last");
                Entry.Add('minHidden', Profile."Min Hidden");
                Entry.Add('preserveLength', Profile."Preserve Length");
                Arr.Add(Entry);
            until Profile.Next() = 0;
    end;

    // What the CALLER's grants change: whether the Unmask tier lifts masks for them right now, and how
    // many of their per-user exceptions are active. The same answers whoAmI gives.
    local procedure Principal() PrincipalObj: JsonObject
    var
        FieldPolicy: Codeunit "Bcmag Field Policy";
    begin
        PrincipalObj.Add('unmaskGranted', FieldPolicy.UnmaskGranted());
        PrincipalObj.Add('activeExceptions', FieldPolicy.ActiveExceptionCount());
    end;

    // Explicit case map — the wire names are lower-case invariants, never Format() captions.
    local procedure ReadAccessName(Access: Enum "Bcmag Read Access"): Text
    begin
        case Access of
            Access::Hidden:
                exit('hidden');
            Access::Masked:
                exit('masked');
            Access::Clear:
                exit('clear');
        end;
        exit('hidden');
    end;

    // Advertise the async delivery capability so an agent can discover it without trial and error.
    // enabled=false means a "deliver" block is rejected (async-not-configured); the agent should then
    // read query results inline. When enabled: add a "deliver" object to a query's data, poll "status"
    // (or list via "requests"), download from packageUrl, and "cancel" if needed.
    local procedure AddAsync(var Caps: JsonObject; Setup: Record "Bcmag Setup")
    var
        AsyncObj: JsonObject;
        Modes, Packages: JsonArray;
    begin
        Modes.Add('azureBlob');
        Packages.Add('ndjson');
        Packages.Add('json');
        Packages.Add('zip');
        AsyncObj.Add('enabled', Setup."Async Enabled");
        AsyncObj.Add('operations', 'query');
        AsyncObj.Add('deliverShape', '{ mode: "azureBlob", package?: "ndjson"|"json"|"zip", scheduleAt?: rfc3339 } — add to a query''s data; the response is { @async:true, requestId, status, packageUrl?, scheduledFor, expiresAt, statusVia }');
        AsyncObj.Add('modes', Modes);
        AsyncObj.Add('packages', Packages);
        AsyncObj.Add('scheduling', true);
        AsyncObj.Add('maxScheduleAheadDays', Setup."Max Schedule Ahead Days");
        AsyncObj.Add('maxActiveRequests', Setup."Max Active Requests");
        AsyncObj.Add('downloadMode', DownloadModeName(Setup."Download Mode"));
        // For a scheduled request the packageUrl is withheld until the package exists — read it from "status".
        AsyncObj.Add('immediateUrl', 'an immediate request returns packageUrl at once (it 404s until the package is written); a scheduled request returns it via status on completion');
        Caps.Add('async', AsyncObj);
    end;

    // API-first reads. The catalog (discover kind "apis", describe kind "api") is always available; mode
    // says whether Wicket lets a client read THROUGH an API page instead of the dynamic plane. catalogVersion
    // lets a client that cached the catalog see in this one call whether its copy is still current.
    local procedure AddApiRouting(var Caps: JsonObject)
    var
        Catalog: Codeunit "Bcmag Api Catalog";
        ApiObj: JsonObject;
    begin
        ApiObj.Add('mode', Catalog.RoutingModeName());
        ApiObj.Add('catalogVersion', Catalog.CatalogVersion());
        ApiObj.Add('guidance', 'Prefer: when an API page covers the table and the fields you need, read through it (describe kind "api" must answer routable:true, and only fields with readable:true may be selected or filtered on); otherwise, or when the user asks for it, use query. Off: use query only. Reads through an API are not recorded in the Wicket Operation Log.');
        Caps.Add('apiRouting', ApiObj);
    end;

    // Invariant name for the download strategy — never Format() an option (locale-dependent).
    local procedure DownloadModeName(DownloadMode: Option StreamProxy,ServiceSas,ReadySAS): Text
    begin
        case DownloadMode of
            DownloadMode::StreamProxy:
                exit('streamProxy');
            DownloadMode::ServiceSas:
                exit('serviceSas');
            DownloadMode::ReadySAS:
                exit('readySas');
        end;
        exit('');
    end;

    // Every enrolled named action (e.g. "post-sales") with `enabled` = its Allow Run, so an agent can
    // tell "no companion" (empty) from "enrolled but disabled" and name the exact administrator step
    // instead of probing. Each carries whether it mutates, whether it supports a preview, and its
    // argsSchema (the catalog's Args Schema, emitted only when it parses as a JSON object), so the
    // rules and the arguments are known without trial and error. A disabled verb is still refused
    // (403 action-disabled) by the action op.
    local procedure AddActions(var Caps: JsonObject)
    var
        Catalog: Record "Bcmag Action Catalog";
        ActionArr: JsonArray;
        ActionObj, ArgsSchema : JsonObject;
        SchemaText: Text;
    begin
        if Catalog.FindSet() then
            repeat
                Clear(ActionObj);
                // Code[50] stores upper case; verbs are documented (and matched) as kebab-case lower case.
                ActionObj.Add('action', LowerCase(Catalog."Action Code"));
                ActionObj.Add('enabled', Catalog."Allow Run");
                if Catalog.Category <> '' then
                    ActionObj.Add('category', Catalog.Category);
                ActionObj.Add('mutating', Catalog."Is Mutating");
                ActionObj.Add('previewSupported', Catalog."Preview Supported");
                if Catalog.Description <> '' then
                    ActionObj.Add('description', Catalog.Description);
                Clear(ArgsSchema);
                SchemaText := Catalog.GetArgsSchema();
                if SchemaText <> '' then
                    if ArgsSchema.ReadFrom(SchemaText) then
                        ActionObj.Add('argsSchema', ArgsSchema);
                ActionArr.Add(ActionObj);
            until Catalog.Next() = 0;
        Caps.Add('actions', ActionArr);
    end;

    local procedure AddOperation(var Operations: JsonArray; Name: Text; Summary: Text; DataShape: Text)
    var
        Op: JsonObject;
    begin
        Op.Add('name', Name);
        Op.Add('summary', Summary);
        Op.Add('data', DataShape);
        Operations.Add(Op);
    end;
}
