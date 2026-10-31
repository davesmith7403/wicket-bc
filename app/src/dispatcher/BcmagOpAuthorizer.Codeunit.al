codeunit 94148 "Bcmag Op Authorizer"
{
    // Current-authorization checks that execute NOTHING. Two clients:
    //   - Bcmag Op Runner calls CheckGates before routing: the tenant's read-only switch and the
    //     principal's role rung, in that order, ahead of any handler.
    //   - Bcmag Rpc Dispatcher calls AuthorizeReplay before an idempotency snapshot is disclosed. A
    //     snapshot is a response the SAME caller already received once, but authorization is evaluated
    //     at every disclosure, not once: a caller who has since lost the role, the table exposure, the
    //     BC table permission or the field policy that produced the response must not read it back
    //     through the replay cache. The check mirrors what the operation would refuse NOW — same order,
    //     same problem types — and never re-runs business effects. A refusal is not snapshotted: the
    //     stored outcome stays, and replays again once access is restored.
    //
    // Three layers, each answered by the component that owns it so this codeunit cannot drift from it:
    //   gates     read-only mode (Setup) and role rung (Bcmag Role Gate)
    //   target    the request's table/codeunit/procedure/action under the exposure allowlist, the
    //             platform's Read/WritePermission, and the catalogs' Allow Run
    //   body      every projected row in the stored response (identified by its @recordId, wherever
    //             it sits — query pages, rows a wrapper embeds) against the CURRENT field policy of its
    //             own table, plus the shapes that carry field data without a projection: aggregate
    //             summaries, describe field/key lists, discover object lists. A write's response is not a
    //             projection: insert/modify/delete return only `recordId` (no '@') and `@etag`, no field
    //             values, so the target check (exposure + WritePermission) is all that guards it.
    // Field-policy denials from the body scan never NAME the field: for a "*" selection the caller never
    // named it either, and the name is exactly what the policy hides.
    // Masking: a field that is Masked NOW may replay only as the mask rendering the stored row already
    // carries — each projected row names its masked members in "@masked" (Bcmag Projector). A member
    // stored in clear (not listed) is refused 403 field-masked; one stored masked and Clear now replays
    // as stored (stricter than today's view). Shapes that carry a clear value or a clear-access claim
    // without a projection — aggregates, readBlob bytes, describe's access: "clear" — are refused too.

    Access = Public;

    var
        Problem: Codeunit "Bcmag Problem";
        RoleGate: Codeunit "Bcmag Role Gate";
        FieldPolicy: Codeunit "Bcmag Field Policy";
        Codec: Codeunit "Bcmag Record Id Codec";
        ReadableTables: List of [Integer];
        FieldNoByName: Dictionary of [Text, Integer];
        ReadableByField: Dictionary of [Text, Boolean];
        ClearByField: Dictionary of [Text, Boolean];
        RequestTableId: Integer;

    // Tenant + principal gates. Shared by the runner (before routing) and by replay.
    procedure CheckGates(Operation: Text; Data: JsonObject; var Fail: JsonObject): Boolean
    var
        Setup: Record "Bcmag Setup";
    begin
        // Read-only master switch, enforced ahead of everything (Mode, the exposure allowlist, and
        // the principal's BC permissions). A mutating call is refused here before its handler — and
        // thus before any table exposure, field policy, or permission check — can grant it.
        if IsMutatingRequest(Operation, Data) then begin
            Setup.GetSingleton();
            if Setup."Read-Only Mode" then begin
                Fail := Problem.NewFailure(403, 'read-only', 'Endpoint is read-only',
                    StrSubstNo('operation "%1" is disabled: the Wicket endpoint is in read-only mode', Operation));
                exit(false);
            end;
        end;
        // Role rung: a principal below the rung an operation needs gets a typed 403 role-forbidden
        // with no side effects, instead of the platform's Execute denial on the handler codeunit
        // escaping the Run boundary as "500 internal". See Bcmag Role Gate.
        exit(RoleGate.CheckOperation(Operation, Fail));
    end;

    procedure IsMutating(Operation: Text): Boolean
    begin
        // invoke and action are treated as mutating: a wrapper codeunit can write, so a full
        // read-only endpoint must refuse them even though some wrappers only read. The one
        // exception is decided per request, in IsMutatingRequest.
        exit(Operation in ['insert', 'modify', 'delete', 'batch', 'invoke', 'action']);
    end;

    // Per-request refinement of IsMutating: an `action` request whose wrapper runs inside the forced
    // rollback (Bcmag Action Rollback) cannot persist anything, so the read-only switch and the key
    // requirement let it through. Everything else follows IsMutating.
    procedure IsMutatingRequest(Operation: Text; Data: JsonObject): Boolean
    begin
        // A batch preview runs inside Bcmag Batch Rollback: nothing it does can persist.
        if Operation = 'batch' then
            exit(not IsPreview(Data));
        if Operation <> 'action' then
            exit(IsMutating(Operation));
        exit(not RunsInRollback(Data));
    end;

    local procedure IsPreview(Data: JsonObject): Boolean
    var
        Tok: JsonToken;
        Preview: Boolean;
    begin
        if Data.Get('preview', Tok) then
            if Tok.IsValue() then
                if not Tok.AsValue().IsNull() then
                    if TryAsBool(Tok.AsValue(), Preview) then
                        exit(Preview);
        exit(false);
    end;

    // True for a preview (data.preview = true) and for a verb enrolled with Is Mutating = false — the
    // same rule Bcmag Op Action applies when it picks the boundary. A malformed member, an unknown or
    // unreadable verb counts as mutating: the op itself then answers 400/404 where writes are allowed.
    procedure RunsInRollback(Data: JsonObject): Boolean
    var
        Catalog: Record "Bcmag Action Catalog";
        Tok: JsonToken;
        Preview: Boolean;
        ActionCode: Text;
    begin
        if Data.Get('preview', Tok) then
            if Tok.IsValue() then
                if not Tok.AsValue().IsNull() then
                    if TryAsBool(Tok.AsValue(), Preview) then
                        if Preview then
                            exit(true);
        if not Data.Get('action', Tok) then
            exit(false);
        if not Tok.IsValue() then
            exit(false);
        if Tok.AsValue().IsNull() then
            exit(false);
        if not TryAsText(Tok.AsValue(), ActionCode) then
            exit(false);
        if (ActionCode = '') or (StrLen(ActionCode) > MaxStrLen(Catalog."Action Code")) then
            exit(false);
        if not Catalog.ReadPermission() then
            exit(false);
        if not Catalog.Get(ActionCode) then
            exit(false);
        exit(not Catalog."Is Mutating");
    end;

    [TryFunction]
    local procedure TryAsBool(Value: JsonValue; var Result: Boolean)
    begin
        Result := Value.AsBoolean();
    end;

    [TryFunction]
    local procedure TryAsText(Value: JsonValue; var Result: Text)
    begin
        Result := Value.AsText();
    end;

    // True when the caller may receive the stored response for (Operation, Data) under the policy in
    // force NOW. False + Fail (the 403/404 the operation itself would produce today) otherwise.
    procedure AuthorizeReplay(Operation: Text; Data: JsonObject; Cached: JsonObject; var Fail: JsonObject): Boolean
    begin
        Clear(ReadableTables);
        Clear(FieldNoByName);
        Clear(ReadableByField);
        Clear(ClearByField);
        // The request's own table: the fallback judge for a projection whose @recordId cannot be decoded.
        if not ReadInt(Data, 'tableId', RequestTableId) then
            RequestTableId := 0;
        if not CheckGates(Operation, Data, Fail) then
            exit(false);
        if not CheckTarget(Operation, Data, Fail) then
            exit(false);
        exit(CheckBody(Operation, Data, Cached, Fail));
    end;

    // ---- target -----------------------------------------------------------------------------------

    local procedure CheckTarget(Operation: Text; Data: JsonObject; var Fail: JsonObject): Boolean
    var
        TableId, CodeunitId, FieldNo: Integer;
        Name: Text;
    begin
        case Operation of
            'query':
                if ReadInt(Data, 'tableId', TableId) then
                    exit(CheckTableRead(TableId, Fail));
            'pageUrl':
                // pageUrl also accepts data.table ("<name>" or "#<no>"); resolve it the way the handler
                // does, or a snapshot requested by name would replay with only the gates checked.
                if ResolvePageUrlTable(Data, TableId) then
                    exit(CheckTableRead(TableId, Fail));
            'readBlob':
                if ReadInt(Data, 'tableId', TableId) then begin
                    if not CheckTableRead(TableId, Fail) then
                        exit(false);
                    // The stored bytes ARE the field: the caller named it by number, so the refusal may too.
                    if ReadInt(Data, 'fieldNo', FieldNo) then begin
                        if not IsReadable(TableId, FieldNo) then begin
                            Fail := Problem.NewFailure(403, 'field-restricted', 'Field access restricted',
                                StrSubstNo('field %1 on table %2 is not readable under the current field policy', FieldNo, TableId));
                            exit(false);
                        end;
                        // Readable but Masked: bytes have no masked form, so the handler refuses a masked
                        // binary outright — and the stored bytes are the clear value.
                        if not IsClear(TableId, FieldNo) then begin
                            Fail := Problem.NewFailure(403, 'field-masked', 'Field is masked',
                                StrSubstNo('field %1 on table %2 is readable only masked under the current field policy, and a binary value has no masked form', FieldNo, TableId));
                            exit(false);
                        end;
                    end;
                end;
            'describe':
                begin
                    if ReadInt(Data, 'tableId', TableId) then
                        exit(CheckTableRead(TableId, Fail));
                    if ReadInt(Data, 'codeunitId', CodeunitId) then
                        exit(CheckCodeunitInvoke(CodeunitId, Fail));
                end;
            'insert', 'modify', 'delete':
                if ReadInt(Data, 'tableId', TableId) then
                    exit(CheckTableWrite(TableId, Operation, Fail));
            'batch':
                exit(CheckBatchTargets(Data, Fail));
            'invoke':
                if ReadInt(Data, 'codeunitId', CodeunitId) then
                    if ReadText(Data, 'procedure', Name) then
                        exit(CheckProcedure(CodeunitId, Name, Fail));
            'action':
                if ReadText(Data, 'action', Name) then
                    exit(CheckAction(Name, Fail));
        end;
        // No resolvable target: a request the operation itself rejected as malformed (its snapshot is a
        // 4xx problem), or a caller-scoped operation (status, requests, cancel, whoAmI, skill,
        // capabilities). The gates and the body scan are all that apply.
        exit(true);
    end;

    local procedure CheckTableRead(TableId: Integer; var Fail: JsonObject): Boolean
    var
        Exposure: Record "Bcmag Exposure";
        RecRef: RecordRef;
    begin
        if ReadableTables.Contains(TableId) then
            exit(true);
        if not Exposure.IsAllowed(Exposure."Object Type"::Table, TableId, 'read') then begin
            Fail := NotExposed(StrSubstNo('table %1 is not exposed for read; enroll it in Wicket Exposure or switch Mode to Open', TableId));
            exit(false);
        end;
        if not TryOpen(RecRef, TableId) then begin
            Fail := NotExposed(StrSubstNo('table %1 is not readable by the calling principal', TableId));
            exit(false);
        end;
        if not RecRef.ReadPermission() then begin
            RecRef.Close();
            Fail := NotExposed(StrSubstNo('table %1 is not readable by the calling principal', TableId));
            exit(false);
        end;
        RecRef.Close();
        ReadableTables.Add(TableId);
        exit(true);
    end;

    // A replayed batch: every item's table must still be writable for its op today.
    local procedure CheckBatchTargets(Data: JsonObject; var Fail: JsonObject): Boolean
    var
        Tok, ItemTok : JsonToken;
        Op: Text;
        TableId: Integer;
    begin
        if not Data.Get('items', Tok) then
            exit(true);
        if not Tok.IsArray() then
            exit(true);
        foreach ItemTok in Tok.AsArray() do
            if ItemTok.IsObject() then
                if ReadText(ItemTok.AsObject(), 'op', Op) then
                    if LowerCase(Op) in ['insert', 'modify', 'delete'] then
                        if ReadInt(ItemTok.AsObject(), 'tableId', TableId) then
                            if not CheckTableWrite(TableId, LowerCase(Op), Fail) then
                                exit(false);
        exit(true);
    end;

    local procedure CheckTableWrite(TableId: Integer; Op: Text; var Fail: JsonObject): Boolean
    var
        Exposure: Record "Bcmag Exposure";
        RecRef: RecordRef;
    begin
        if not Exposure.IsAllowed(Exposure."Object Type"::Table, TableId, Op) then begin
            Fail := NotExposed(StrSubstNo('table %1 is not exposed for %2', TableId, Op));
            exit(false);
        end;
        if not TryOpen(RecRef, TableId) then begin
            Fail := NotExposed(StrSubstNo('table %1 is not writable by the calling principal', TableId));
            exit(false);
        end;
        if not RecRef.WritePermission() then begin
            RecRef.Close();
            Fail := NotExposed(StrSubstNo('table %1 is not writable by the calling principal', TableId));
            exit(false);
        end;
        RecRef.Close();
        // A write returns recordId + @etag only — no field values — so there is no body to judge.
        exit(true);
    end;

    local procedure CheckCodeunitInvoke(CodeunitId: Integer; var Fail: JsonObject): Boolean
    var
        Exposure: Record "Bcmag Exposure";
    begin
        if not Exposure.IsAllowed(Exposure."Object Type"::Codeunit, CodeunitId, 'invoke') then begin
            Fail := NotExposed(StrSubstNo('codeunit %1 is not exposed for invoke', CodeunitId));
            exit(false);
        end;
        exit(true);
    end;

    local procedure CheckProcedure(CodeunitId: Integer; ProcedureName: Text; var Fail: JsonObject): Boolean
    var
        Catalog: Record "Bcmag Procedure Catalog";
    begin
        if not CheckCodeunitInvoke(CodeunitId, Fail) then
            exit(false);
        // Oversized names cannot be enrolled (Text[120]); answer like the handler, without overflowing Get.
        if StrLen(ProcedureName) > MaxStrLen(Catalog."Procedure Name") then begin
            Fail := Problem.NewFailure(404, 'unknown-procedure', 'Unknown procedure',
                StrSubstNo('procedure name exceeds %1 characters, so it cannot be enrolled for codeunit %2', MaxStrLen(Catalog."Procedure Name"), CodeunitId));
            exit(false);
        end;
        if not Catalog.Get(CodeunitId, ProcedureName) then begin
            Fail := Problem.NewFailure(404, 'unknown-procedure', 'Unknown procedure',
                StrSubstNo('procedure "%1" is not enrolled for codeunit %2', ProcedureName, CodeunitId));
            exit(false);
        end;
        if not Catalog."Allow Run" then begin
            Fail := Problem.NewFailure(403, 'invoke-disabled', 'Procedure disabled',
                StrSubstNo('procedure "%1" is enrolled but Allow Run is off', ProcedureName));
            exit(false);
        end;
        exit(true);
    end;

    local procedure CheckAction(ActionCode: Text; var Fail: JsonObject): Boolean
    var
        Catalog: Record "Bcmag Action Catalog";
    begin
        // Oversized codes cannot be enrolled (Code[50]); answer like the handler, without overflowing Get.
        if StrLen(ActionCode) > MaxStrLen(Catalog."Action Code") then begin
            Fail := Problem.NewFailure(404, 'unknown-action', 'Unknown action',
                StrSubstNo('action code exceeds %1 characters, so it cannot be enrolled', MaxStrLen(Catalog."Action Code")));
            exit(false);
        end;
        if not Catalog.Get(ActionCode) then begin
            Fail := Problem.NewFailure(404, 'unknown-action', 'Unknown action',
                StrSubstNo('action "%1" is not enrolled', ActionCode));
            exit(false);
        end;
        if not Catalog."Allow Run" then begin
            Fail := Problem.NewFailure(403, 'action-disabled', 'Action disabled',
                StrSubstNo('action "%1" is enrolled but Allow Run is off', ActionCode));
            exit(false);
        end;
        exit(true);
    end;

    // Mirrors Bcmag Op Page Url's table resolution (tableId, or table = "<name>" / "#<no>"). A name
    // that resolves to nothing, or a malformed reference, was a 4xx from the handler — nothing to guard.
    local procedure ResolvePageUrlTable(Data: JsonObject; var TableId: Integer): Boolean
    var
        AllObj: Record AllObjWithCaption;
        Name: Text;
    begin
        if ReadInt(Data, 'tableId', TableId) then
            exit(true);
        if not ReadText(Data, 'table', Name) then
            exit(false);
        if Name.StartsWith('#') then
            exit(Evaluate(TableId, CopyStr(Name, 2)));
        if StrLen(Name) > MaxStrLen(AllObj."Object Name") then
            exit(false);
        AllObj.SetRange("Object Type", AllObj."Object Type"::Table);
        AllObj.SetRange("Object Name", Name);
        if not AllObj.FindFirst() then
            exit(false);
        TableId := AllObj."Object ID";
        exit(true);
    end;

    // ---- body -------------------------------------------------------------------------------------

    local procedure CheckBody(Operation: Text; Data: JsonObject; Cached: JsonObject; var Fail: JsonObject): Boolean
    var
        TableId: Integer;
    begin
        if not WalkProjections(Cached.AsToken(), Fail) then
            exit(false);
        case Operation of
            'query':
                begin
                    // The fields a query was filtered, ordered or windowed by never appear in its body,
                    // yet they decided which rows (or which count) it holds. Re-run the request's shaping
                    // steps against today's policy, reading no rows. Only a policy refusal (403) counts:
                    // a shape the handler would now reject for another reason (a lowered filter-length
                    // cap, say) still produced a legitimate stored result.
                    if not ShapeStillAllowed(Data, Fail) then
                        exit(false);
                    if Data.Contains('aggregate') then
                        if ReadInt(Data, 'tableId', TableId) then
                            exit(CheckAggregateValue(TableId, Cached, Fail));
                end;
            'describe':
                begin
                    if ReadInt(Data, 'tableId', TableId) then
                        exit(CheckDescribeValue(TableId, Cached, Fail));
                    // describe kind "api" (a pageId): its field entries claim access "clear" for the
                    // fields a client may read through the tenant API.
                    if Data.Contains('pageId') then
                        exit(CheckApiDescribeValue(Cached, Fail));
                end;
            'discover':
                exit(CheckDiscoverValue(Cached, Fail));
        end;
        exit(true);
    end;

    local procedure ShapeStillAllowed(Data: JsonObject; var Fail: JsonObject): Boolean
    var
        OpQuery: Codeunit "Bcmag Op Query";
        ShapeFail: JsonObject;
    begin
        if OpQuery.ValidateShape(Data, ShapeFail) then
            exit(true);
        if Problem.StatusOf(ShapeFail) <> 403 then
            exit(true);
        Fail := ShapeFail;
        exit(false);
    end;

    // Depth-first over the whole stored body: any object carrying @recordId is a projection.
    local procedure WalkProjections(Tok: JsonToken; var Fail: JsonObject): Boolean
    var
        Obj: JsonObject;
        Child: JsonToken;
        MemberName: Text;
    begin
        if Tok.IsObject() then begin
            Obj := Tok.AsObject();
            if Obj.Contains('@recordId') then
                if not CheckProjection(Obj, Fail) then
                    exit(false);
            foreach MemberName in Obj.Keys() do begin
                Obj.Get(MemberName, Child);
                if not WalkProjections(Child, Fail) then
                    exit(false);
            end;
            exit(true);
        end;
        if Tok.IsArray() then
            foreach Child in Tok.AsArray() do
                if not WalkProjections(Child, Fail) then
                    exit(false);
        exit(true);
    end;

    local procedure CheckProjection(Row: JsonObject; var Fail: JsonObject): Boolean
    var
        Tok: JsonToken;
        MemberName: Text;
        MaskedMembers: List of [Text];
        TableId, FieldNo: Integer;
        MaskedLoaded: Boolean;
    begin
        Row.Get('@recordId', Tok);
        if not Tok.IsValue() then
            exit(true);
        if not Codec.TableNoOf(Tok.AsValue().AsText(), TableId) then begin
            // Undecodable: judge the row by the request's own table rather than letting it through
            // unjudged. With no request table to fall back on, fail CLOSED — the row carries field
            // values we cannot attribute to a table, so no field policy can vouch for them.
            if RequestTableId = 0 then begin
                Fail := Problem.NewFailure(403, 'field-restricted', 'Field access restricted',
                    'the stored response for this idempotency key includes a record whose table cannot be determined, so its fields cannot be judged against the current field policy; read the current state with a new key');
                exit(false);
            end;
            TableId := RequestTableId;
        end;
        if not CheckTableRead(TableId, Fail) then
            exit(false);
        foreach MemberName in Row.Keys() do begin
            if MemberName.StartsWith('@') then
                continue;
            if not ResolveField(TableId, MemberName, FieldNo) then
                continue; // a key that is not a field of this table (renamed since, or a wrapper's addition)
            if not IsReadable(TableId, FieldNo) then begin
                Fail := BodyRestricted(TableId);
                exit(false);
            end;
            // Masked now: fine only if the row carried this member as its mask rendering already.
            if not IsClear(TableId, FieldNo) then begin
                if not MaskedLoaded then begin
                    MaskedMembers := MaskedMembersOf(Row);
                    MaskedLoaded := true;
                end;
                if not MaskedMembers.Contains(MemberName) then begin
                    Fail := BodyMasked(TableId);
                    exit(false);
                end;
            end;
        end;
        exit(true);
    end;

    // The row's "@masked" member names. Absent or malformed → none, so every Masked-now member is judged
    // as stored in clear (fail-closed).
    local procedure MaskedMembersOf(Row: JsonObject) Names: List of [Text]
    var
        Tok, Item: JsonToken;
    begin
        if not Row.Get('@masked', Tok) then
            exit;
        if not Tok.IsArray() then
            exit;
        foreach Item in Tok.AsArray() do
            if Item.IsValue() then
                if not Item.AsValue().IsNull() then
                    Names.Add(Item.AsValue().AsText());
    end;

    // value.sum/avg/min/max are keyed by field name, without a projection.
    local procedure CheckAggregateValue(TableId: Integer; Cached: JsonObject; var Fail: JsonObject): Boolean
    var
        Value, Group: JsonObject;
        Tok: JsonToken;
        Kind, MemberName: Text;
        FieldNo: Integer;
    begin
        if not ValueObject(Cached, Value) then
            exit(true);
        foreach Kind in Aggregates() do
            if Value.Get(Kind, Tok) then
                if Tok.IsObject() then begin
                    Group := Tok.AsObject();
                    foreach MemberName in Group.Keys() do
                        if ResolveField(TableId, MemberName, FieldNo) then
                            if not IsReadable(TableId, FieldNo) then begin
                                Fail := BodyRestricted(TableId);
                                exit(false);
                            end else
                                // Replay never reruns the aggregate's field resolution, so the masked
                                // refusal must be repeated here: a stored min/max/sum over a field that
                                // is now Masked would otherwise replay the clear value.
                                if not IsClear(TableId, FieldNo) then begin
                                    Fail := Problem.NewFailure(403, 'field-masked', 'Field is masked',
                                        StrSubstNo('the stored aggregate for this idempotency key covers a field of table %1 that is now masked, so it cannot be replayed; the original request has already taken effect (or not) — read again with a new key', TableId));
                                    exit(false);
                                end;
                end;
        exit(true);
    end;

    // describe omits restricted fields and the keys over them — unless the administrator advertises
    // them with readable=false (Describe Restricted Fields), in which case the stored list is fine.
    // Independently of that switch, an entry stored with access "clear" for a field that is Masked now
    // is refused: it would tell the client the field reads (and filters, sorts) in clear.
    local procedure CheckDescribeValue(TableId: Integer; Cached: JsonObject; var Fail: JsonObject): Boolean
    var
        Setup: Record "Bcmag Setup";
        Value, Entry: JsonObject;
        Tok, No: JsonToken;
        FieldNo: Integer;
        AdvertisesRestricted: Boolean;
    begin
        Setup.GetSingleton();
        AdvertisesRestricted := Setup."Describe Restricted Fields";
        if not ValueObject(Cached, Value) then
            exit(true);
        if Value.Get('fields', Tok) then
            if Tok.IsArray() then
                foreach Tok in Tok.AsArray() do
                    if Tok.IsObject() then begin
                        Entry := Tok.AsObject();
                        if Entry.Get('no', No) then begin
                            FieldNo := IntOf(No);
                            if not AdvertisesRestricted then
                                if not IsReadable(TableId, FieldNo) then begin
                                    Fail := BodyRestricted(TableId);
                                    exit(false);
                                end;
                            if ClaimsClearAccess(Entry) then
                                if IsMaskedNow(TableId, FieldNo) then begin
                                    Fail := DescribeMasked(TableId);
                                    exit(false);
                                end;
                        end;
                    end;
        if AdvertisesRestricted then
            exit(true);
        if Value.Get('keys', Tok) then
            if Tok.IsArray() then
                foreach Tok in Tok.AsArray() do
                    if Tok.IsObject() then begin
                        Entry := Tok.AsObject();
                        if Entry.Get('fields', No) then
                            if No.IsArray() then
                                foreach No in No.AsArray() do
                                    if not IsReadable(TableId, IntOf(No)) then begin
                                        Fail := BodyRestricted(TableId);
                                        exit(false);
                                    end;
                    end;
        exit(true);
    end;

    // describe kind "api": a mapped field entry stored with access "clear" (readable through the tenant
    // API) must still be Clear — otherwise a client routing through the API would read in clear a value
    // Wicket now masks (or hides). Entries stored as "masked" or without access claim nothing extra. A
    // field bound to another table than the page's source carries its own tableId.
    local procedure CheckApiDescribeValue(Cached: JsonObject; var Fail: JsonObject): Boolean
    var
        Value, Entry: JsonObject;
        Tok, Member: JsonToken;
        SourceTableId, TableId, FieldNo: Integer;
    begin
        if not ValueObject(Cached, Value) then
            exit(true);
        if not ReadInt(Value, 'sourceTableId', SourceTableId) then
            SourceTableId := 0;
        if not Value.Get('fields', Tok) then
            exit(true);
        if not Tok.IsArray() then
            exit(true);
        foreach Tok in Tok.AsArray() do
            if Tok.IsObject() then begin
                Entry := Tok.AsObject();
                if ClaimsClearAccess(Entry) then
                    if Entry.Get('fieldNo', Member) then begin
                        FieldNo := IntOf(Member);
                        if not ReadInt(Entry, 'tableId', TableId) then
                            TableId := SourceTableId;
                        if (TableId <> 0) and (FieldNo <> 0) then
                            if not IsClear(TableId, FieldNo) then begin
                                if IsReadable(TableId, FieldNo) then
                                    Fail := DescribeMasked(TableId)
                                else
                                    Fail := BodyRestricted(TableId);
                                exit(false);
                            end;
                    end;
            end;
        exit(true);
    end;

    local procedure ClaimsClearAccess(Entry: JsonObject): Boolean
    var
        Access: Text;
    begin
        if not ReadText(Entry, 'access', Access) then
            exit(false);
        exit(Access = 'clear');
    end;

    // Readable, but not Clear: Masked under the current policy.
    local procedure IsMaskedNow(TableId: Integer; FieldNo: Integer): Boolean
    begin
        if not IsReadable(TableId, FieldNo) then
            exit(false);
        exit(not IsClear(TableId, FieldNo));
    end;

    // discover lists the objects the caller could reach at the time; each must still be reachable.
    local procedure CheckDiscoverValue(Cached: JsonObject; var Fail: JsonObject): Boolean
    var
        Entry: JsonObject;
        Tok, Member: JsonToken;
        Scope: Text;
    begin
        if not Cached.Get('value', Tok) then
            exit(true);
        if not Tok.IsArray() then
            exit(true);
        foreach Tok in Tok.AsArray() do
            if Tok.IsObject() then begin
                Entry := Tok.AsObject();
                Scope := '';
                if Entry.Get('scope', Member) then
                    if Member.IsValue() then
                        Scope := Member.AsValue().AsText();
                if Entry.Get('id', Member) then
                    case Scope of
                        'table':
                            if not CheckTableRead(IntOf(Member), Fail) then
                                exit(false);
                        'codeunit':
                            if not CheckCodeunitInvoke(IntOf(Member), Fail) then
                                exit(false);
                    end;
            end;
        exit(true);
    end;

    // ---- helpers ----------------------------------------------------------------------------------

    local procedure ResolveField(TableId: Integer; Name: Text; var FieldNo: Integer): Boolean
    var
        FieldRec: Record Field;
        CacheKey: Text;
    begin
        // A field name is at most Text[30]; anything longer is not a field (and would overflow the
        // FieldName filter with a raised error instead of an answer).
        if StrLen(Name) > MaxStrLen(FieldRec.FieldName) then begin
            FieldNo := 0;
            exit(false);
        end;
        CacheKey := Format(TableId) + ':' + Name;
        if FieldNoByName.Get(CacheKey, FieldNo) then
            exit(FieldNo <> 0);
        // Exact name only (no suggestion scan): a projection key IS a field name, or is nothing to us.
        FieldRec.SetRange(TableNo, TableId);
        FieldRec.SetRange(FieldName, Name);
        if FieldRec.FindFirst() then
            FieldNo := FieldRec."No."
        else
            FieldNo := 0;
        FieldNoByName.Add(CacheKey, FieldNo);
        exit(FieldNo <> 0);
    end;

    // Once per field per replay, like the handlers: never per row inside the projection walk.
    local procedure IsReadable(TableId: Integer; FieldNo: Integer): Boolean
    var
        CacheKey: Text;
        Readable: Boolean;
    begin
        CacheKey := Format(TableId) + ':' + Format(FieldNo);
        if ReadableByField.Get(CacheKey, Readable) then
            exit(Readable);
        Readable := FieldPolicy.IsReadable(TableId, FieldNo);
        ReadableByField.Add(CacheKey, Readable);
        exit(Readable);
    end;

    local procedure IsClear(TableId: Integer; FieldNo: Integer): Boolean
    var
        CacheKey: Text;
        IsClearVal: Boolean;
    begin
        CacheKey := Format(TableId) + ':' + Format(FieldNo);
        if ClearByField.Get(CacheKey, IsClearVal) then
            exit(IsClearVal);
        IsClearVal := FieldPolicy.IsClear(TableId, FieldNo);
        ClearByField.Add(CacheKey, IsClearVal);
        exit(IsClearVal);
    end;

    local procedure BodyRestricted(TableId: Integer): JsonObject
    begin
        exit(Problem.NewFailure(403, 'field-restricted', 'Field access restricted',
            StrSubstNo('the stored response for this idempotency key includes a field of table %1 that is no longer readable under the current field policy, so it cannot be replayed; the original request has already taken effect (or not) — read the current state with a new key', TableId)));
    end;

    local procedure BodyMasked(TableId: Integer): JsonObject
    begin
        exit(Problem.NewFailure(403, 'field-masked', 'Field is masked',
            StrSubstNo('the stored response for this idempotency key includes a field of table %1 in clear that is now masked under the current field policy, so it cannot be replayed; the original request has already taken effect (or not) — read the current state with a new key', TableId)));
    end;

    local procedure DescribeMasked(TableId: Integer): JsonObject
    begin
        exit(Problem.NewFailure(403, 'field-masked', 'Field is masked',
            StrSubstNo('the stored response for this idempotency key describes a field of table %1 as readable in clear, but it is now masked under the current field policy, so it cannot be replayed; describe again with a new key', TableId)));
    end;

    local procedure NotExposed(Detail: Text): JsonObject
    begin
        exit(Problem.NewFailure(403, 'not-exposed', 'Not exposed', Detail));
    end;

    local procedure Aggregates() Kinds: List of [Text]
    begin
        Kinds.Add('sum');
        Kinds.Add('avg');
        Kinds.Add('min');
        Kinds.Add('max');
    end;

    local procedure ValueObject(Cached: JsonObject; var Value: JsonObject): Boolean
    var
        Tok: JsonToken;
    begin
        if not Cached.Get('value', Tok) then
            exit(false);
        if not Tok.IsObject() then
            exit(false);
        Value := Tok.AsObject();
        exit(true);
    end;

    local procedure ReadInt(Data: JsonObject; Name: Text; var Value: Integer): Boolean
    var
        Tok: JsonToken;
    begin
        Value := 0;
        if not Data.Get(Name, Tok) then
            exit(false);
        exit(TryInt(Tok, Value));
    end;

    local procedure ReadText(Data: JsonObject; Name: Text; var Value: Text): Boolean
    var
        Tok: JsonToken;
    begin
        Value := '';
        if not Data.Get(Name, Tok) then
            exit(false);
        if not Tok.IsValue() then
            exit(false);
        if Tok.AsValue().IsNull() then
            exit(false);
        Value := Tok.AsValue().AsText();
        exit(Value <> '');
    end;

    local procedure IntOf(Tok: JsonToken): Integer
    var
        Value: Integer;
    begin
        if TryInt(Tok, Value) then
            exit(Value);
        exit(0);
    end;

    [TryFunction]
    local procedure TryInt(Tok: JsonToken; var Value: Integer)
    begin
        Value := Tok.AsValue().AsInteger();
    end;

    [TryFunction]
    local procedure TryOpen(var RecRef: RecordRef; TableId: Integer)
    begin
        RecRef.Open(TableId);
    end;
}
