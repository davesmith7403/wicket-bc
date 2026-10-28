codeunit 94143 "Bcmag Op Page Url"
{
    // "pageUrl" operation: a deep link into the BC web client for one record.
    // data: { tableId | table: "<name>"|"#<no>", systemId?: guid, recordId?: token, pageId?: int }
    // At least one of systemId/recordId is required; systemId wins when both are present.
    // The table must be exposed for READ (same gate as query): a page URL discloses record
    // existence, so it fails with the identical 403 'not-exposed' a query would.
    // Page resolution: caller pageId if given, else the table's default lookup page from the
    // platform virtual table "Table Metadata" (2000000136, LookupPageID). Neither -> 404 'no-page'.
    // Non-mutating: building a URL reads one record and writes nothing.

    var
        Exposure: Record "Bcmag Exposure";
        Problem: Codeunit "Bcmag Problem";
        Codec: Codeunit "Bcmag Record Id Codec";
        JsonRead: Codeunit "Bcmag Json Read";

    procedure Run(Data: JsonObject; var Response: JsonObject; var Fail: JsonObject; var Cost: Integer): Boolean
    var
        RecRef: RecordRef;
        Result: JsonObject;
        TableId, PageId: Integer;
        Url: Text;
    begin
        Cost := 1;
        if not ResolveTable(Data, TableId, Fail) then exit(false);
        if not Exposure.IsAllowed(Exposure."Object Type"::Table, TableId, 'read') then begin
            Fail := Problem.NewFailure(403, 'not-exposed', 'Table not exposed',
                StrSubstNo('table %1 is not exposed for read; enroll it in Wicket Exposure or switch Mode to Open', TableId));
            exit(false);
        end;
        if not LocateRecord(Data, TableId, RecRef, Fail) then exit(false);
        if not ResolvePage(Data, TableId, PageId, Fail) then begin
            RecRef.Close();
            exit(false);
        end;

        Url := GetUrl(ClientType::Web, CompanyName(), ObjectType::Page, PageId, RecRef);
        RecRef.Close();

        Result.Add('pageUrl', Url);
        Result.Add('pageId', PageId);
        Clear(Response);
        Response.Add('value', Result);
        exit(true);
    end;

    // data.tableId (the number, like every other op) or data.table ("<name>" or "#<no>",
    // resolved against AllObjWithCaption the same way discover/describe list objects).
    local procedure ResolveTable(Data: JsonObject; var TableId: Integer; var Fail: JsonObject): Boolean
    var
        AllObj: Record AllObjWithCaption;
        Tok: JsonToken;
        Name: Text;
    begin
        if Data.Get('tableId', Tok) then
            exit(JsonRead.ReadInteger(Tok, 'tableId', TableId, Fail));
        if Data.Get('table', Tok) then begin
            if not JsonRead.ReadText(Tok, 'table', Name, Fail) then exit(false);
            if Name.StartsWith('#') then begin
                if Evaluate(TableId, CopyStr(Name, 2)) then exit(true);
                Fail := Problem.NewFailure(400, 'invalid-field', 'Invalid table',
                    StrSubstNo('"%1" is not a valid "#<tableNo>" reference', Name));
                exit(false);
            end;
            AllObj.SetRange("Object Type", AllObj."Object Type"::Table);
            AllObj.SetRange("Object Name", Name);
            if AllObj.FindFirst() then begin
                TableId := AllObj."Object ID";
                exit(true);
            end;
            Fail := Problem.NewFailure(404, 'unknown-table', 'Unknown table',
                StrSubstNo('no table named "%1" exists', Name));
            exit(false);
        end;
        Fail := Problem.NewFailure(400, 'missing-field', 'Missing table',
            'data.tableId (or data.table: a table name or "#<tableNo>") is required');
        exit(false);
    end;

    // systemId (GetBySystemId) wins over recordId (opaque token via the Record Id Codec).
    // Both re-fetch under the caller's record-level security filter, and a missing/foreign
    // record is the same 404 either way (a URL builder must not become an existence probe
    // beyond what read exposure already grants).
    local procedure LocateRecord(Data: JsonObject; TableId: Integer; var RecRef: RecordRef; var Fail: JsonObject): Boolean
    var
        DecodedRef: RecordRef;
        Tok: JsonToken;
        SystemId: Guid;
        Token, Raw, ErrorMsg: Text;
        Found: Boolean;
        TokenTableNo: Integer;
    begin
        if Data.Get('systemId', Tok) then begin
            if not Tok.IsValue() then begin
                Fail := InvalidSystemId();
                exit(false);
            end;
            if Tok.AsValue().IsNull() then begin
                Fail := InvalidSystemId();
                exit(false);
            end;
            Raw := Tok.AsValue().AsText();
            if not TryParseGuid(Raw, SystemId) then begin
                Fail := InvalidSystemId();
                exit(false);
            end;
            RecRef.Open(TableId);
            RecRef.SecurityFiltering := SecurityFilter::Filtered;
            if not TryGetBySystemId(RecRef, SystemId, Found) then
                Found := false;
            if not Found then begin
                RecRef.Close();
                Fail := NotFound();
                exit(false);
            end;
            exit(true);
        end;

        if Data.Get('recordId', Tok) then begin
            if not JsonRead.ReadText(Tok, 'recordId', Token, Fail) then exit(false);
            // Judge the token's table before Decode reads the row: decoding first would answer
            // found / not-found about whatever (possibly unexposed) table the token names.
            if not Codec.TableNoOf(Token, TokenTableNo) then begin
                Fail := Problem.NewFailure(404, 'unknown-record', 'Record not found', 'recordId token is not a valid record reference');
                exit(false);
            end;
            if TokenTableNo <> TableId then begin
                Fail := Problem.NewFailure(400, 'record-table-mismatch', 'recordId / table mismatch',
                    'recordId belongs to a different table than the requested table');
                exit(false);
            end;
            if not Codec.Decode(Token, DecodedRef, ErrorMsg) then begin
                Fail := Problem.NewFailure(404, 'unknown-record', 'Record not found', ErrorMsg);
                exit(false);
            end;
            RecRef.Open(TableId);
            RecRef.SecurityFiltering := SecurityFilter::Filtered;
            RecRef.SetPosition(DecodedRef.GetPosition());
            DecodedRef.Close();
            if not RecRef.Find('=') then begin
                RecRef.Close();
                Fail := NotFound();
                exit(false);
            end;
            exit(true);
        end;

        Fail := Problem.NewFailure(400, 'missing-field', 'Missing record reference',
            'data.systemId or data.recordId is required (systemId wins if both are given)');
        exit(false);
    end;

    local procedure ResolvePage(Data: JsonObject; TableId: Integer; var PageId: Integer; var Fail: JsonObject): Boolean
    var
        TableMetadata: Record "Table Metadata";
        Tok: JsonToken;
        Suggest: JsonObject;
    begin
        PageId := 0;
        if Data.Get('pageId', Tok) then begin
            if not JsonRead.ReadInteger(Tok, 'pageId', PageId, Fail) then exit(false);
        end else
            if TableMetadata.Get(TableId) then
                PageId := TableMetadata.LookupPageID;
        if PageId > 0 then exit(true);
        Suggest.Add('use', 'pass data.pageId (the id of a card or list page for this table)');
        Fail := Problem.NewFailureSuggest(404, 'no-page', 'No page for table',
            StrSubstNo('table %1 has no default lookup page; pass data.pageId explicitly', TableId), Suggest);
        exit(false);
    end;

    local procedure InvalidSystemId() Fail: JsonObject
    begin
        Fail := Problem.NewFailure(400, 'invalid-field', 'Invalid systemId',
            'data.systemId must be a GUID string (the @systemId from a prior query row)');
    end;

    local procedure NotFound() Fail: JsonObject
    begin
        Fail := Problem.NewFailure(404, 'unknown-record', 'Record not found',
            'record not found or not within your security scope');
    end;

    // GetBySystemId throws on a table without system fields; a TryFunction folds that
    // into the same not-found outcome instead of a 500.
    [TryFunction]
    local procedure TryGetBySystemId(var RecRef: RecordRef; SystemId: Guid; var Found: Boolean)
    begin
        Found := RecRef.GetBySystemId(SystemId);
    end;

    [TryFunction]
    local procedure TryParseGuid(Input: Text; var Value: Guid)
    begin
        Evaluate(Value, Input);
    end;
}
