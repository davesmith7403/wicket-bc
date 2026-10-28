codeunit 94115 "Bcmag Op Insert"
{
    var
        Exposure: Record "Bcmag Exposure";
        Problem: Codeunit "Bcmag Problem";
        Coercer: Codeunit "Bcmag Value Coercer";
        Codec: Codeunit "Bcmag Record Id Codec";
        Projector: Codeunit "Bcmag Projector";
        JsonRead: Codeunit "Bcmag Json Read";

    procedure Run(Data: JsonObject; var Response: JsonObject; var Fail: JsonObject; var Cost: Integer): Boolean
    var
        Tok: JsonToken;
        TableId: Integer;
        RecRef: RecordRef;
        Values: JsonObject;
        ByFieldNo, RunTrigger: Boolean;
        Result: JsonObject;
    begin
        Cost := 1;
        if not Data.Get('tableId', Tok) then begin
            Fail := Problem.NewFailure(400, 'missing-field', 'Missing tableId', 'data.tableId is required');
            exit(false);
        end;
        if not JsonRead.ReadInteger(Tok, 'tableId', TableId, Fail) then exit(false);
        if not Exposure.IsAllowed(Exposure."Object Type"::Table, TableId, 'insert') then begin
            Fail := Problem.NewFailure(403, 'not-exposed', 'Insert not exposed', StrSubstNo('table %1 is not exposed for insert', TableId));
            exit(false);
        end;

        if not GetValues(Data, Values, ByFieldNo, Fail) then exit(false);
        RunTrigger := true;
        if Data.Get('init', Tok) then
            if not JsonRead.ReadBoolean(Tok, 'init', RunTrigger, Fail) then exit(false);
        // init:false skips the table's OnInsert trigger — number series, defaults, validation the table
        // owns. A tenant policy, not a caller choice: refused unless Setup allows the bypass.
        if not RunTrigger then
            if not TriggerBypassAllowed('init', Fail) then exit(false);

        RecRef.Open(TableId);
        RecRef.SecurityFiltering := SecurityFilter::Filtered;
        RecRef.Init();
        if not Coercer.ApplyValues(RecRef, Values, ByFieldNo, true, false, Fail) then begin
            RecRef.Close();
            exit(false);
        end;
        if not TryInsert(RecRef, RunTrigger) then begin
            Fail := Problem.NewFailure(422, 'insert-failed', 'Insert failed', GetLastErrorText());
            RecRef.Close();
            exit(false);
        end;

        // Re-read the row before minting the returned @etag. The token derives from SystemModifiedAt,
        // and the value the platform leaves in the record variable after Insert is not guaranteed to
        // be the value SQL Server persists (datetime storage rounds sub-10 ms precision), so a token
        // minted from memory can miss with 412 on the caller's very next write. The read path always
        // mints from persisted values; the write path must hand back the same kind of token.
        RecRef.Get(RecRef.RecordId);

        Result.Add('recordId', Codec.Encode(RecRef.RecordId));
        if Projector.EtagOf(RecRef) <> '' then
            Result.Add('@etag', Projector.EtagOf(RecRef));
        Clear(Response);
        Response.Add('value', Result);
        RecRef.Close();
        exit(true);
    end;

    local procedure GetValues(Data: JsonObject; var Values: JsonObject; var ByFieldNo: Boolean; var Fail: JsonObject): Boolean
    var
        Tok: JsonToken;
    begin
        if Data.Get('values', Tok) then begin
            if not JsonRead.ReadObject(Tok, 'values', Values, Fail) then exit(false);
            ByFieldNo := false;
            exit(true);
        end;
        if Data.Get('valuesByFieldNo', Tok) then begin
            if not JsonRead.ReadObject(Tok, 'valuesByFieldNo', Values, Fail) then exit(false);
            ByFieldNo := true;
            exit(true);
        end;
        Fail := Problem.NewFailure(400, 'missing-field', 'Missing values', 'data.values or data.valuesByFieldNo is required');
        exit(false);
    end;

    procedure TriggerBypassAllowed(MemberName: Text; var Fail: JsonObject): Boolean
    var
        Setup: Record "Bcmag Setup";
    begin
        Setup.GetSingleton();
        if Setup."Allow Trigger Bypass" then
            exit(true);
        Fail := Problem.NewFailure(403, 'trigger-bypass-disabled', 'Trigger bypass disabled',
            StrSubstNo('data.%1 = false would skip the table''s business logic, and this tenant does not allow that (Wicket Setup "Allow Trigger Bypass"); omit data.%1 to run the triggers', MemberName));
        exit(false);
    end;

    [TryFunction]
    local procedure TryInsert(var RecRef: RecordRef; RunTrigger: Boolean)
    begin
        RecRef.Insert(RunTrigger);
    end;
}
