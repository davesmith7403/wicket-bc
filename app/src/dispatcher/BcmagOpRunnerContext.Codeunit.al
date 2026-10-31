codeunit 94126 "Bcmag Op Runner Context"
{
    // Single-instance channel between the dispatcher and the Codeunit.Run isolation boundary
    // in "Bcmag Op Runner". JsonObjects are reference types and persist across the in-session
    // Codeunit.Run call.
    //
    // It also carries the request-scoped field-policy state, because it is the one place that knows
    // where a request begins:
    //   - UnmaskRequested: the request's "unmask" opt-out, read by "Bcmag Field Policy".
    //   - NoteLift / LiftedFieldsText: fields whose verdict this request was LIFTED above the baseline
    //     (by a user exception or the Unmask tier), for the Operation Log. The logger records them only
    //     for operations that return field values (see "Bcmag Logger").
    //   - PolicyGeneration: "Bcmag Field Policy" caches verdicts per instance, and policy instances can
    //     outlive a request: the dispatcher holds its Op Authorizer (and that authorizer's policy) as a
    //     global for as long as the dispatcher instance lives, and test codeunits hold handlers as globals
    //     across test methods. (The runner itself is a fresh local per request in the dispatcher, so its
    //     handlers are not the long-lived ones.) The generation moves on every SetRequest and on
    //     every in-session write to a policy table (the subscribers below; table trigger events fire
    //     whether or not the write runs the table trigger), and a policy instance drops its cache when
    //     the generation it loaded at is no longer current. A write in ANOTHER session is picked up at
    //     that session's next SetRequest — a policy change applies from the next request on.
    SingleInstance = true;

    var
        Operation: Text;
        Data: JsonObject;
        Response: JsonObject;
        Fail: JsonObject;
        Cost: Integer;
        OpOk: Boolean;
        HasResult: Boolean;
        Lifts: List of [Text];
        PolicyGen: Integer;
        RequestId: Text;
        RequestOrigin: Text;
        HasFailedRun: Boolean;
        FailedRunKind: Enum "Bcmag Change Kind";
        FailedRunName: Text;
        FailedRunSystemId: Guid;
        FailedRunDetail: Text;

    procedure SetRequest(NewOperation: Text; NewData: JsonObject)
    begin
        Operation := NewOperation;
        Data := NewData;
        Clear(Response);
        Clear(Fail);
        Cost := 0;
        OpOk := false;
        HasResult := false;
        Clear(Lifts);
        RequestId := '';
        RequestOrigin := '';
        HasFailedRun := false;
        BumpPolicyGeneration();
    end;

    // The envelope's id and origin, for what a request leaves behind besides the Operation Log (the
    // change history names its request and connection). Set by the dispatcher right after SetRequest.
    procedure SetEnvelope(NewRequestId: Text; NewOrigin: Text)
    begin
        RequestId := NewRequestId;
        RequestOrigin := NewOrigin;
    end;

    procedure GetRequestId(): Text
    begin
        exit(RequestId);
    end;

    procedure GetOrigin(): Text
    begin
        exit(RequestOrigin);
    end;

    // A mutating action or procedure that failed may already have committed (a posting commits inside
    // the run). The runner then rolls the request's own writes back, so its change history entry is
    // written by the dispatcher AFTER the boundary, from what the handler noted here.
    procedure NoteFailedRun(Kind: Enum "Bcmag Change Kind"; Name: Text; SystemId: Guid; Detail: Text)
    begin
        HasFailedRun := true;
        FailedRunKind := Kind;
        FailedRunName := Name;
        FailedRunSystemId := SystemId;
        FailedRunDetail := Detail;
    end;

    procedure TakeFailedRun(var Kind: Enum "Bcmag Change Kind"; var Name: Text; var SystemId: Guid; var Detail: Text): Boolean
    begin
        if not HasFailedRun then
            exit(false);
        HasFailedRun := false;
        Kind := FailedRunKind;
        Name := FailedRunName;
        SystemId := FailedRunSystemId;
        Detail := FailedRunDetail;
        exit(true);
    end;

    procedure GetOperation(): Text
    begin
        exit(Operation);
    end;

    procedure GetData(): JsonObject
    begin
        exit(Data);
    end;

    procedure SetResult(NewOpOk: Boolean; NewResponse: JsonObject; NewFail: JsonObject; NewCost: Integer)
    begin
        OpOk := NewOpOk;
        Response := NewResponse;
        Fail := NewFail;
        Cost := NewCost;
        HasResult := true;
    end;

    // True once a handler has recorded an outcome (success or a structured failure). The runner
    // raises an error after a failure so its writes roll back; because codeunit state survives the
    // rollback, the dispatcher uses HasResult to tell a deliberate failure-rollback (use the stashed
    // Fail) apart from an unexpected AL error that escaped before any outcome was recorded (-> 500).
    procedure GetHasResult(): Boolean
    begin
        exit(HasResult);
    end;

    procedure GetOpOk(): Boolean
    begin
        exit(OpOk);
    end;

    procedure GetResponse(): JsonObject
    begin
        exit(Response);
    end;

    procedure GetFail(): JsonObject
    begin
        exit(Fail);
    end;

    procedure GetCost(): Integer
    begin
        exit(Cost);
    end;

    // ---- field-policy request state --------------------------------------------------------------

    // The request's "unmask" member. Only an explicit false (the JSON literal, or the string "false")
    // opts out; absent, null or anything unreadable keeps the default true. Reading the serialized
    // token instead of AsBoolean() means no value can raise an error on the read path.
    procedure UnmaskRequested(): Boolean
    var
        Tok: JsonToken;
        Raw: Text;
    begin
        if not Data.Get('unmask', Tok) then
            exit(true);
        if not Tok.IsValue() then
            exit(true);
        Tok.WriteTo(Raw);
        if Raw = 'false' then
            exit(false);
        if LowerCase(Raw) = '"false"' then
            exit(false);
        exit(true);
    end;

    // Distinct "table:field" pairs, numbers written invariantly (Format(.., 0, 9) — the default
    // format would add a thousands separator to a table like 94105).
    procedure NoteLift(TableId: Integer; FieldNo: Integer)
    var
        Pair: Text;
    begin
        Pair := Format(TableId, 0, 9) + ':' + Format(FieldNo, 0, 9);
        if not Lifts.Contains(Pair) then
            Lifts.Add(Pair);
    end;

    // "18:9,18:102", or '' when nothing was lifted. Bounded to 250 characters (an Operation Log Text
    // field). Pairs are never cut in half: when they do not all fit, the text keeps as many whole pairs
    // as leave room for an overflow marker ",+N" (N = the pairs left out), so an auditor can see that
    // the list is incomplete and by how much.
    procedure LiftedFieldsText() Result: Text
    var
        Pair, Candidate: Text;
        Kept: Integer;
        Full: Boolean;
    begin
        foreach Pair in Lifts do
            if Result = '' then
                Result := Pair
            else
                Result += ',' + Pair;
        if StrLen(Result) <= MaxLiftTextLength() then
            exit(Result);

        Result := '';
        foreach Pair in Lifts do
            if not Full then begin
                if Result = '' then
                    Candidate := Pair
                else
                    Candidate := Result + ',' + Pair;
                // Room for the marker that would follow if this pair were the last one kept.
                if StrLen(Candidate) + StrLen(OverflowMarker(Lifts.Count() - Kept - 1)) > MaxLiftTextLength() then
                    Full := true
                else begin
                    Result := Candidate;
                    Kept += 1;
                end;
            end;
        if Result = '' then
            exit(CopyStr(OverflowMarker(Lifts.Count()), 2));
        exit(Result + OverflowMarker(Lifts.Count() - Kept));
    end;

    local procedure OverflowMarker(Omitted: Integer): Text
    begin
        exit(',+' + Format(Omitted, 0, 9));
    end;

    local procedure MaxLiftTextLength(): Integer
    begin
        exit(250);
    end;

    procedure PolicyGeneration(): Integer
    begin
        exit(PolicyGen);
    end;

    local procedure BumpPolicyGeneration()
    begin
        if PolicyGen = 2147483647 then
            PolicyGen := 0;
        PolicyGen += 1;
    end;

    // ---- policy-table writes invalidate cached verdicts ------------------------------------------

    [EventSubscriber(ObjectType::Table, Database::"Bcmag Setup", 'OnAfterInsertEvent', '', false, false)]
    local procedure OnSetupInserted()
    begin
        BumpPolicyGeneration();
    end;

    [EventSubscriber(ObjectType::Table, Database::"Bcmag Setup", 'OnAfterModifyEvent', '', false, false)]
    local procedure OnSetupModified()
    begin
        BumpPolicyGeneration();
    end;

    [EventSubscriber(ObjectType::Table, Database::"Bcmag Setup", 'OnAfterDeleteEvent', '', false, false)]
    local procedure OnSetupDeleted()
    begin
        BumpPolicyGeneration();
    end;

    [EventSubscriber(ObjectType::Table, Database::"Bcmag Field Exposure", 'OnAfterInsertEvent', '', false, false)]
    local procedure OnFieldExposureInserted()
    begin
        BumpPolicyGeneration();
    end;

    [EventSubscriber(ObjectType::Table, Database::"Bcmag Field Exposure", 'OnAfterModifyEvent', '', false, false)]
    local procedure OnFieldExposureModified()
    begin
        BumpPolicyGeneration();
    end;

    [EventSubscriber(ObjectType::Table, Database::"Bcmag Field Exposure", 'OnAfterDeleteEvent', '', false, false)]
    local procedure OnFieldExposureDeleted()
    begin
        BumpPolicyGeneration();
    end;

    [EventSubscriber(ObjectType::Table, Database::"Bcmag Field Exposure", 'OnAfterRenameEvent', '', false, false)]
    local procedure OnFieldExposureRenamed()
    begin
        BumpPolicyGeneration();
    end;

    [EventSubscriber(ObjectType::Table, Database::"Bcmag Classification Rule", 'OnAfterInsertEvent', '', false, false)]
    local procedure OnRuleInserted()
    begin
        BumpPolicyGeneration();
    end;

    [EventSubscriber(ObjectType::Table, Database::"Bcmag Classification Rule", 'OnAfterModifyEvent', '', false, false)]
    local procedure OnRuleModified()
    begin
        BumpPolicyGeneration();
    end;

    [EventSubscriber(ObjectType::Table, Database::"Bcmag Classification Rule", 'OnAfterDeleteEvent', '', false, false)]
    local procedure OnRuleDeleted()
    begin
        BumpPolicyGeneration();
    end;

    [EventSubscriber(ObjectType::Table, Database::"Bcmag Classification Rule", 'OnAfterRenameEvent', '', false, false)]
    local procedure OnRuleRenamed()
    begin
        BumpPolicyGeneration();
    end;

    [EventSubscriber(ObjectType::Table, Database::"Bcmag Access Exception", 'OnAfterInsertEvent', '', false, false)]
    local procedure OnExceptionInserted()
    begin
        BumpPolicyGeneration();
    end;

    [EventSubscriber(ObjectType::Table, Database::"Bcmag Access Exception", 'OnAfterModifyEvent', '', false, false)]
    local procedure OnExceptionModified()
    begin
        BumpPolicyGeneration();
    end;

    [EventSubscriber(ObjectType::Table, Database::"Bcmag Access Exception", 'OnAfterDeleteEvent', '', false, false)]
    local procedure OnExceptionDeleted()
    begin
        BumpPolicyGeneration();
    end;

    [EventSubscriber(ObjectType::Table, Database::"Bcmag Mask Profile", 'OnAfterInsertEvent', '', false, false)]
    local procedure OnProfileInserted()
    begin
        BumpPolicyGeneration();
    end;

    [EventSubscriber(ObjectType::Table, Database::"Bcmag Mask Profile", 'OnAfterModifyEvent', '', false, false)]
    local procedure OnProfileModified()
    begin
        BumpPolicyGeneration();
    end;

    [EventSubscriber(ObjectType::Table, Database::"Bcmag Mask Profile", 'OnAfterDeleteEvent', '', false, false)]
    local procedure OnProfileDeleted()
    begin
        BumpPolicyGeneration();
    end;

    [EventSubscriber(ObjectType::Table, Database::"Bcmag Mask Profile", 'OnAfterRenameEvent', '', false, false)]
    local procedure OnProfileRenamed()
    begin
        BumpPolicyGeneration();
    end;
}
