codeunit 94103 "Bcmag Logger"
{
    // Durable per-request audit. v1 transport returns HTTP 200 for every call (success
    // OR problem) and never calls Error(), so this single end-of-request Insert always
    // commits — including for failed calls, which the old StartLog/Error/rollback pattern
    // silently lost. The dispatcher also emits Session.LogMessage telemetry in parallel.

    procedure Write(RequestId: Text; IdempotencyKey: Text; Operation: Text; Origin: Text; Caller: Text; Status: Integer; Cost: Integer; DurationMs: Integer; ProblemType: Text; ProblemDetail: Text; StartedAt: DateTime; EndedAt: DateTime; Data: JsonObject)
    var
        Log: Record "Bcmag Operation Log";
        Setup: Record "Bcmag Setup";
        RunnerCtx: Codeunit "Bcmag Op Runner Context";
    begin
        Log.Init();
        Log."Request Id" := CopyStr(RequestId, 1, MaxStrLen(Log."Request Id"));
        Log."Idempotency Key" := CopyStr(IdempotencyKey, 1, MaxStrLen(Log."Idempotency Key"));
        Log.Operation := CopyStr(Operation, 1, MaxStrLen(Log.Operation));
        Log.Origin := CopyStr(Origin, 1, MaxStrLen(Log.Origin));
        Log.Caller := CopyStr(Caller, 1, MaxStrLen(Log.Caller));
        Log.Status := Status;
        Log.Cost := Cost;
        Log."Duration (ms)" := DurationMs;
        Log."Started At" := StartedAt;
        Log."Ended At" := EndedAt;
        Log."Problem Type" := CopyStr(ProblemType, 1, MaxStrLen(Log."Problem Type"));
        Log."Problem Detail" := CopyStr(ProblemDetail, 1, MaxStrLen(Log."Problem Detail"));
        // The fields this request read above the caller's baseline (a user exception or the Unmask
        // tier lifted Masked to Clear) — recorded only where a lift disclosed a value: a successful
        // query (rows, aggregates, a replayed snapshot) or readBlob. describe, discover and capabilities
        // consult the same verdicts, and may note lifts, but return no field values, so they log ''.
        if ReturnsFieldValues(Operation) then
            if (Status >= 200) and (Status < 300) then
                Log."Unmasked Fields" := CopyStr(RunnerCtx.LiftedFieldsText(), 1, MaxStrLen(Log."Unmasked Fields"));
        // Best-effort: a failed audit Insert (lock, permission) must never escape and void an
        // already-completed operation — that would break the always-HTTP-200 contract. The
        // dispatcher emits Session.LogMessage telemetry in parallel, so the call is still traced.
        Log."Table Id" := IntegerMember(Data, 'tableId');
        Log.Target := CopyStr(TargetOf(Operation, Data), 1, MaxStrLen(Log.Target));
        if Setup.Get('') then
            if Setup."Log Request Details" then
                Log."Request Details" := CopyStr(RequestDetails(Data), 1, MaxStrLen(Log."Request Details"));
        if not TryInsertOperation(Log) then;
    end;

    // invoke: codeunit.procedure; action: the action code; describe of a codeunit or API: its id;
    // status/cancel: the async request id. None of these is a data value.
    local procedure TargetOf(Operation: Text; Data: JsonObject): Text
    var
        CodeunitId: Integer;
    begin
        case Operation of
            'invoke':
                begin
                    CodeunitId := IntegerMember(Data, 'codeunitId');
                    exit(Format(CodeunitId, 0, 9) + '.' + TextMember(Data, 'procedure'));
                end;
            'action':
                exit(TextMember(Data, 'action'));
            'describe':
                begin
                    if IntegerMember(Data, 'codeunitId') <> 0 then
                        exit('codeunit ' + Format(IntegerMember(Data, 'codeunitId'), 0, 9));
                    if IntegerMember(Data, 'pageId') <> 0 then
                        exit('page ' + Format(IntegerMember(Data, 'pageId'), 0, 9));
                    if IntegerMember(Data, 'queryId') <> 0 then
                        exit('query ' + Format(IntegerMember(Data, 'queryId'), 0, 9));
                end;
            'status', 'cancel':
                exit(TextMember(Data, 'requestId'));
        end;
        exit('');
    end;

    // The request's shape: the members that say WHAT was asked, copied as sent, and for a write or an
    // invoke only the NAMES of the fields or arguments it carried, never their values. Opaque tokens
    // (cursor, etag, ifNoneMatch) say nothing an auditor needs and are left out.
    local procedure RequestDetails(Data: JsonObject): Text
    var
        Details: JsonObject;
        Tok: JsonToken;
        Member: Text;
        Serialized: Text;
    begin
        foreach Member in Data.Keys() do
            if Data.Get(Member, Tok) then
                case Member of
                    'kind', 'select', 'selectFieldNo', 'filter', 'orderBy', 'top', 'skip', 'count', 'include',
                    'aggregate', 'modifiedAfter', 'modifiedBefore', 'publisher', 'deliver', 'recordId', 'systemId',
                    'target', 'preview', 'init', 'validate', 'unmask', 'returnShape', 'status', 'section', 'mode',
                    'table':
                        Details.Add(Member, Tok);
                    'values', 'valuesByFieldNo', 'args':
                        Details.Add(Member, MemberNames(Tok));
                end;
        if Details.Keys().Count() = 0 then
            exit('');
        Details.WriteTo(Serialized);
        exit(Serialized);
    end;

    local procedure MemberNames(Tok: JsonToken) Names: JsonArray
    var
        Name: Text;
    begin
        if not Tok.IsObject() then
            exit;
        foreach Name in Tok.AsObject().Keys() do
            Names.Add(Name);
    end;

    local procedure IntegerMember(Data: JsonObject; Name: Text): Integer
    var
        Tok: JsonToken;
        Value: Integer;
    begin
        if not Data.Get(Name, Tok) then
            exit(0);
        if not Tok.IsValue() then
            exit(0);
        if Tok.AsValue().IsNull() then
            exit(0);
        if not TryAsInteger(Tok.AsValue(), Value) then
            exit(0);
        exit(Value);
    end;

    [TryFunction]
    local procedure TryAsInteger(Value: JsonValue; var Result: Integer)
    begin
        Result := Value.AsInteger();
    end;

    local procedure TextMember(Data: JsonObject; Name: Text): Text
    var
        Tok: JsonToken;
    begin
        if Data.Get(Name, Tok) then
            if Tok.IsValue() then
                if not Tok.AsValue().IsNull() then
                    exit(Tok.AsValue().AsText());
        exit('');
    end;

    local procedure ReturnsFieldValues(Operation: Text): Boolean
    begin
        exit(Operation in ['query', 'readBlob']);
    end;

    [TryFunction]
    local procedure TryInsertOperation(var Log: Record "Bcmag Operation Log")
    begin
        Log.Insert(true);
    end;

    // Store the replay snapshot for an idempotent request: key + SHA-256 body hash + operation +
    // final logical status + the serialized response body. The dispatcher only calls this for
    // outcomes below 500 — a 5xx must stay retryable, never replayable. Best-effort like every
    // other logger write: a failed Insert must not void the already-completed operation.
    // ('Key' is a reserved AL keyword and cannot be a parameter identifier, hence IdemKey.)
    procedure LogIdempotencyResponse(IdemKey: Text; RequestId: Text; BodyHash: Text; Operation: Text; Status: Integer; ResponseText: Text)
    var
        Log: Record "Bcmag Idempotency Log";
        OutS: OutStream;
    begin
        if IdemKey = '' then exit;
        Log.Init();
        Log."Idempotency Key" := CopyStr(IdemKey, 1, MaxStrLen(Log."Idempotency Key"));
        Log."Request Id" := CopyStr(RequestId, 1, MaxStrLen(Log."Request Id"));
        Log."Body Hash" := CopyStr(BodyHash, 1, MaxStrLen(Log."Body Hash"));
        Log.Operation := CopyStr(Operation, 1, MaxStrLen(Log.Operation));
        Log.Status := Status;
        Log."Logged At" := CurrentDateTime();
        // Stamp the calling principal so replay/conflict lookups can be scoped to it — one
        // caller must never replay (or 409-collide with) another caller's cached row.
        Log.Caller := UserSecurityId();
        if ResponseText <> '' then begin
            Log.Response.CreateOutStream(OutS, TextEncoding::UTF8);
            OutS.WriteText(ResponseText);
        end;
        if not TryInsertIdempotency(Log) then;
    end;

    // Fetch the most recent snapshot for a key BELONGING TO THE CURRENT PRINCIPAL. The lookup is
    // scoped to Caller = UserSecurityId(), so a snapshot is only ever visible to the user who
    // created it — this is what closes the cross-principal replay / stale-authorization leak.
    // Rows without a stored response (legacy v1 rows, written before replay existed) report as
    // not found; legacy rows also carry an empty Caller Guid, so they match no live principal and
    // fall through to fresh execution — they can neither replay a stale payload nor 409 a retry.
    procedure FindReplay(IdemKey: Text; var StoredHash: Text; var StoredStatus: Integer; var ResponseText: Text): Boolean
    var
        Log: Record "Bcmag Idempotency Log";
        InS: InStream;
        Line: Text;
    begin
        StoredHash := '';
        StoredStatus := 0;
        ResponseText := '';
        if IdemKey = '' then exit(false);
        Log.SetCurrentKey("Idempotency Key", Caller);
        Log.SetRange("Idempotency Key", IdemKey);
        Log.SetRange(Caller, UserSecurityId());
        if not Log.FindLast() then exit(false);
        Log.CalcFields(Response);
        if not Log.Response.HasValue() then exit(false);
        Log.Response.CreateInStream(InS, TextEncoding::UTF8);
        // The stored JSON is single-line (WriteTo emits no line breaks), but ReadText stops at a
        // line break, so accumulate defensively.
        while not InS.EOS() do begin
            InS.ReadText(Line);
            ResponseText += Line;
        end;
        if ResponseText = '' then exit(false);
        StoredHash := Log."Body Hash";
        StoredStatus := Log.Status;
        exit(true);
    end;

    [TryFunction]
    local procedure TryInsertIdempotency(var Log: Record "Bcmag Idempotency Log")
    begin
        Log.Insert(true);
    end;
}
