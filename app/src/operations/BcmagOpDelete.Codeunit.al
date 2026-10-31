codeunit 94117 "Bcmag Op Delete"
{
    var
        Exposure: Record "Bcmag Exposure";
        Problem: Codeunit "Bcmag Problem";
        Recorder: Codeunit "Bcmag Change Recorder";
        RecordAccess: Codeunit "Bcmag Record Access";
        JsonRead: Codeunit "Bcmag Json Read";

    procedure Run(Data: JsonObject; var Response: JsonObject; var Fail: JsonObject; var Cost: Integer): Boolean
    var
        Before: Dictionary of [Integer, Text];
        Tok: JsonToken;
        TableId: Integer;
        Token: Text;
        RecRef: RecordRef;
        Result: JsonObject;
    begin
        Cost := 1;
        if not Data.Get('tableId', Tok) then begin
            Fail := Problem.NewFailure(400, 'missing-field', 'Missing tableId', 'data.tableId is required');
            exit(false);
        end;
        if not JsonRead.ReadInteger(Tok, 'tableId', TableId, Fail) then exit(false);
        if not Exposure.IsAllowed(Exposure."Object Type"::Table, TableId, 'delete') then begin
            Fail := Problem.NewFailure(403, 'not-exposed', 'Delete not exposed', StrSubstNo('table %1 is not exposed for delete', TableId));
            exit(false);
        end;
        if not Data.Get('recordId', Tok) then begin
            Fail := Problem.NewFailure(400, 'missing-field', 'Missing recordId', 'data.recordId is required');
            exit(false);
        end;
        if not JsonRead.ReadText(Tok, 'recordId', Token, Fail) then exit(false);

        if not RecordAccess.LocateForWrite(TableId, Token, RecRef, Fail) then exit(false);
        if not RecordAccess.CheckConcurrency(RecRef, Data, Fail) then begin
            RecRef.Close();
            exit(false);
        end;
        Before := Recorder.Snapshot(RecRef);
        if not TryDelete(RecRef) then begin
            Fail := Problem.NewFailure(422, 'delete-failed', 'Delete failed', GetLastErrorText());
            RecRef.Close();
            exit(false);
        end;
        Recorder.RecordDeleted(Before, RecRef);

        Result.Add('deleted', true);
        Result.Add('recordId', Token);
        Clear(Response);
        Response.Add('value', Result);
        RecRef.Close();
        exit(true);
    end;

    [TryFunction]
    local procedure TryDelete(var RecRef: RecordRef)
    begin
        RecRef.Delete(true);
    end;
}
