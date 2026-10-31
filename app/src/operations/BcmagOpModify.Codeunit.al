codeunit 94116 "Bcmag Op Modify"
{
    var
        Exposure: Record "Bcmag Exposure";
        Problem: Codeunit "Bcmag Problem";
        Recorder: Codeunit "Bcmag Change Recorder";
        Coercer: Codeunit "Bcmag Value Coercer";
        Codec: Codeunit "Bcmag Record Id Codec";
        Projector: Codeunit "Bcmag Projector";
        RecordAccess: Codeunit "Bcmag Record Access";
        JsonRead: Codeunit "Bcmag Json Read";
        OpInsert: Codeunit "Bcmag Op Insert";

    procedure Run(Data: JsonObject; var Response: JsonObject; var Fail: JsonObject; var Cost: Integer): Boolean
    var
        Before: Dictionary of [Integer, Text];
        Tok: JsonToken;
        TableId: Integer;
        Token: Text;
        RecRef: RecordRef;
        Values: JsonObject;
        ByFieldNo, Validate: Boolean;
        Result: JsonObject;
        KeyBefore: List of [Text];
    begin
        Cost := 1;
        if not Data.Get('tableId', Tok) then begin
            Fail := Problem.NewFailure(400, 'missing-field', 'Missing tableId', 'data.tableId is required');
            exit(false);
        end;
        if not JsonRead.ReadInteger(Tok, 'tableId', TableId, Fail) then exit(false);
        if not Exposure.IsAllowed(Exposure."Object Type"::Table, TableId, 'modify') then begin
            Fail := Problem.NewFailure(403, 'not-exposed', 'Modify not exposed', StrSubstNo('table %1 is not exposed for modify', TableId));
            exit(false);
        end;
        if not Data.Get('recordId', Tok) then begin
            Fail := Problem.NewFailure(400, 'missing-field', 'Missing recordId', 'data.recordId is required');
            exit(false);
        end;
        if not JsonRead.ReadText(Tok, 'recordId', Token, Fail) then exit(false);
        if not GetValues(Data, Values, ByFieldNo, Fail) then exit(false);
        Validate := true;
        if Data.Get('validate', Tok) then
            if not JsonRead.ReadBoolean(Tok, 'validate', Validate, Fail) then exit(false);
        // validate:false assigns without OnValidate — the field rules the table owns. Tenant policy.
        if not Validate then
            if not OpInsert.TriggerBypassAllowed('validate', Fail) then exit(false);

        if not RecordAccess.LocateForWrite(TableId, Token, RecRef, Fail) then exit(false);
        if not RecordAccess.CheckConcurrency(RecRef, Data, Fail) then begin
            RecRef.Close();
            exit(false);
        end;
        KeyBefore := PrimaryKeyValues(RecRef);
        Before := Recorder.Snapshot(RecRef);
        if not Coercer.ApplyValues(RecRef, Values, ByFieldNo, Validate, true, Fail) then begin
            RecRef.Close();
            exit(false);
        end;
        // RecRef.Modify does not rename: with a changed primary key it writes to (or fails on) the row
        // the NEW key names — another record entirely. Keys change only through a rename, which this
        // operation does not offer; compare after coercion so every addressing form (name, caption,
        // field number) and any OnValidate side effect on a key field are caught alike.
        if not CheckKeyUnchanged(RecRef, KeyBefore, Fail) then begin
            RecRef.Close();
            exit(false);
        end;
        if not TryModify(RecRef) then begin
            Fail := Problem.NewFailure(422, 'modify-failed', 'Modify failed', GetLastErrorText());
            RecRef.Close();
            exit(false);
        end;

        // Re-read before minting the new @etag — same reason as the insert op: the token must come
        // from the persisted SystemModifiedAt, not the in-memory value Modify leaves behind.
        RecRef.Get(RecRef.RecordId);
        // Same transaction as the change: if anything after this fails, the history rolls back with it.
        Recorder.RecordChanged(Before, RecRef);

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

    local procedure PrimaryKeyValues(var RecRef: RecordRef) Values: List of [Text]
    var
        KeyRef: KeyRef;
        i: Integer;
    begin
        KeyRef := RecRef.KeyIndex(1);
        for i := 1 to KeyRef.FieldCount() do
            Values.Add(Format(KeyRef.FieldIndex(i).Value(), 0, 9));
    end;

    local procedure CheckKeyUnchanged(var RecRef: RecordRef; Before: List of [Text]; var Fail: JsonObject): Boolean
    var
        KeyRef: KeyRef;
        FldRef: FieldRef;
        i: Integer;
    begin
        KeyRef := RecRef.KeyIndex(1);
        for i := 1 to KeyRef.FieldCount() do begin
            FldRef := KeyRef.FieldIndex(i);
            if Format(FldRef.Value(), 0, 9) <> Before.Get(i) then begin
                Fail := Problem.NewFailure(400, 'pk-immutable', 'Primary key is immutable',
                    StrSubstNo('field "%1" is part of the primary key of table %2 and cannot be changed by modify (a key change is a rename, which is not supported); insert a new record and delete the old one instead', FldRef.Name(), RecRef.Number()));
                exit(false);
            end;
        end;
        exit(true);
    end;

    [TryFunction]
    local procedure TryModify(var RecRef: RecordRef)
    begin
        RecRef.Modify(true);
    end;
}
