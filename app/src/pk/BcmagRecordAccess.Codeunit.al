codeunit 94127 "Bcmag Record Access"
{
    // Shared write-path helpers: locate a record from an opaque token under the caller's
    // security filter, and enforce optimistic concurrency (ETag / If-Match via data.etag,
    // since a bound action cannot read request headers in v1).

    var
        Codec: Codeunit "Bcmag Record Id Codec";
        Projector: Codeunit "Bcmag Projector";
        Problem: Codeunit "Bcmag Problem";
        JsonRead: Codeunit "Bcmag Json Read";

    procedure LocateForWrite(TableId: Integer; Token: Text; var RecRef: RecordRef; var Fail: JsonObject): Boolean
    var
        DecodedRef: RecordRef;
        ErrorMsg: Text;
        TokenTableNo: Integer;
    begin
        // The token's table is judged before Decode reads the row: decoding first answered
        // found / not-found about whatever (possibly unexposed) table the token names.
        if not Codec.TableNoOf(Token, TokenTableNo) then begin
            Fail := Problem.NewFailure(404, 'unknown-record', 'Record not found', 'recordId token is not a valid record reference');
            exit(false);
        end;
        if TokenTableNo <> TableId then begin
            Fail := Problem.NewFailure(400, 'record-table-mismatch', 'recordId / tableId mismatch', 'recordId belongs to a different table than tableId');
            exit(false);
        end;
        if not Codec.Decode(Token, DecodedRef, ErrorMsg) then begin
            Fail := Problem.NewFailure(404, 'unknown-record', 'Record not found', ErrorMsg);
            exit(false);
        end;
        RecRef.Open(TableId);
        RecRef.SecurityFiltering := SecurityFilter::Filtered;
        RecRef.LockTable();
        RecRef.SetPosition(DecodedRef.GetPosition());
        DecodedRef.Close();
        if not RecRef.Find('=') then begin
            RecRef.Close();
            Fail := Problem.NewFailure(404, 'unknown-record', 'Record not found', 'record not found or not within your security scope');
            exit(false);
        end;
        exit(true);
    end;

    procedure CheckConcurrency(var RecRef: RecordRef; Data: JsonObject; var Fail: JsonObject): Boolean
    var
        Setup: Record "Bcmag Setup";
        Tok: JsonToken;
        ProvidedEtag, CurrentEtag: Text;
    begin
        Setup.GetSingleton();
        CurrentEtag := Projector.EtagOf(RecRef);
        if Data.Get('etag', Tok) then
            if not JsonRead.ReadText(Tok, 'etag', ProvidedEtag, Fail) then exit(false);

        if CurrentEtag = '' then begin
            // Table has no system fields — last-write-wins unless the tenant requires ETags.
            if Setup."Require ETag On Writes" then begin
                Fail := Problem.NewFailure(409, 'no-etag-available', 'No ETag available',
                    'this table has no system fields so no ETag can be produced, but the tenant requires ETag on writes');
                exit(false);
            end;
            exit(true);
        end;

        if ProvidedEtag = '' then begin
            if Setup."Require ETag On Writes" then begin
                Fail := Problem.NewFailure(409, 'etag-required', 'ETag required',
                    'this tenant requires data.etag (the @etag from a prior read) on writes');
                exit(false);
            end;
            exit(true);
        end;

        if ProvidedEtag <> CurrentEtag then begin
            Fail := Problem.NewFailure(412, 'precondition-failed', 'ETag mismatch',
                'the record changed since you read it (data.etag does not match); re-read and retry');
            exit(false);
        end;
        exit(true);
    end;

    procedure CurrentEtag(var RecRef: RecordRef): Text
    begin
        exit(Projector.EtagOf(RecRef));
    end;
}
