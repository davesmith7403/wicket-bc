codeunit 94114 "Bcmag Op Read Blob"
{
    var
        Codec: Codeunit "Bcmag Record Id Codec";
        Exposure: Record "Bcmag Exposure";
        Problem: Codeunit "Bcmag Problem";
        FieldPolicy: Codeunit "Bcmag Field Policy";
        JsonRead: Codeunit "Bcmag Json Read";

    procedure Run(Data: JsonObject; var Response: JsonObject; var Fail: JsonObject; var Cost: Integer): Boolean
    var
        Tok: JsonToken;
        TableId, FieldNo: Integer;
        Token: Text;
        DecodedRef, RecRef: RecordRef;
        FieldRec: Record Field;
        TempBlob: Codeunit "Temp Blob";
        InStr: InStream;
        Base64: Codeunit "Base64 Convert";
        Base64Bytes, ContentType: Text;
        Result: JsonObject;
        ErrorMsg: Text;
        TokenTableNo: Integer;
    begin
        Cost := 1;
        if not Data.Get('tableId', Tok) then begin
            Fail := Problem.NewFailure(400, 'missing-field', 'Missing tableId', 'data.tableId is required');
            exit(false);
        end;
        if not JsonRead.ReadInteger(Tok, 'tableId', TableId, Fail) then exit(false);
        if not Exposure.IsAllowed(Exposure."Object Type"::Table, TableId, 'read') then begin
            Fail := Problem.NewFailure(403, 'not-exposed', 'Table not exposed', StrSubstNo('table %1 is not exposed', TableId));
            exit(false);
        end;
        if not Data.Get('recordId', Tok) then begin
            Fail := Problem.NewFailure(400, 'missing-field', 'Missing recordId', 'data.recordId is required (the @recordId from a prior query row)');
            exit(false);
        end;
        if not JsonRead.ReadText(Tok, 'recordId', Token, Fail) then exit(false);
        if not Data.Get('fieldNo', Tok) then begin
            Fail := Problem.NewFailure(400, 'missing-field', 'Missing fieldNo', 'data.fieldNo is required');
            exit(false);
        end;
        if not JsonRead.ReadInteger(Tok, 'fieldNo', FieldNo, Fail) then exit(false);

        // The token's table is judged BEFORE anything touches the database: Decode reads the row,
        // so decoding a token for some other (possibly unexposed) table first would answer
        // "exists" vs "not found" about a table the caller was never cleared to read.
        if not Codec.TableNoOf(Token, TokenTableNo) then begin
            Fail := Problem.NewFailure(404, 'unknown-record', 'Record not found', 'recordId token is not a valid record reference');
            exit(false);
        end;
        if TokenTableNo <> TableId then begin
            Fail := Problem.NewFailure(400, 'record-table-mismatch', 'recordId / tableId mismatch', 'recordId belongs to a different table than tableId');
            exit(false);
        end;

        // Field policy FIRST, and the field is named by NUMBER only — the caller supplied a number,
        // so echoing its name (or saying "is not a BLOB") would disclose a restricted field. A field
        // number that does not exist answers the same 403 as a restricted one (the CheckSelectReadable
        // posture in Op Query), so a probe cannot tell "hidden" from "absent".
        if not FieldPolicy.IsReadable(TableId, FieldNo) then begin
            Fail := RestrictedField(FieldNo);
            exit(false);
        end;
        if not FieldRec.Get(TableId, FieldNo) then begin
            Fail := RestrictedField(FieldNo);
            exit(false);
        end;
        if FieldRec.ObsoleteState = FieldRec.ObsoleteState::Removed then begin
            Fail := RestrictedField(FieldNo);
            exit(false);
        end;
        if not (FieldRec.Type in [FieldRec.Type::BLOB, FieldRec.Type::Media, FieldRec.Type::MediaSet]) then begin
            Fail := Problem.NewFailure(400, 'not-binary', 'Field is not binary', StrSubstNo('field %1 is not a BLOB/Media/MediaSet field', FieldNo));
            exit(false);
        end;
        // A Masked verdict is readable, but only as a mask rendering — and bytes have no partial form.
        // Returning them would emit the value in clear, so a masked binary is refused outright.
        if FieldPolicy.IsMasked(TableId, FieldNo) then begin
            Fail := Problem.NewFailure(403, 'field-masked', 'Field is masked',
                StrSubstNo('field %1 is readable only masked, and a binary value has no masked form', FieldNo));
            exit(false);
        end;

        if not Codec.Decode(Token, DecodedRef, ErrorMsg) then begin
            Fail := Problem.NewFailure(404, 'unknown-record', 'Record not found', ErrorMsg);
            exit(false);
        end;

        // Re-fetch under the caller's record-level security filter so a known/forged token
        // cannot read a record outside the caller's security scope.
        RecRef.Open(TableId);
        RecRef.SecurityFiltering := SecurityFilter::Filtered;
        RecRef.SetPosition(DecodedRef.GetPosition());
        DecodedRef.Close();
        if not RecRef.Find('=') then begin
            RecRef.Close();
            Fail := Problem.NewFailure(404, 'unknown-record', 'Record not found', 'record not found or not within your security scope');
            exit(false);
        end;

        if not ReadBytes(RecRef, FieldRec, InStr, ContentType, TempBlob, Fail) then begin
            RecRef.Close();
            exit(false);
        end;
        Base64Bytes := Base64.ToBase64(InStr);
        RecRef.Close();

        if ContentType = '' then
            ContentType := SniffFromBase64(Base64Bytes);

        Result.Add('contentType', ContentType);
        Result.Add('bytesBase64', Base64Bytes);
        Clear(Response);
        Response.Add('value', Result);
        exit(true);
    end;

    local procedure ReadBytes(var RecRef: RecordRef; FieldRec: Record Field; var InStr: InStream; var ContentType: Text; var TempBlob: Codeunit "Temp Blob"; var Fail: JsonObject): Boolean
    var
        FieldRefVal: FieldRef;
        MediaId: Guid;
        TenantMedia: Record "Tenant Media";
    begin
        FieldRefVal := RecRef.Field(FieldRec."No.");
        case FieldRec.Type of
            FieldRec.Type::BLOB:
                begin
                    FieldRefVal.CalcField();
                    TempBlob.FromRecordRef(RecRef, FieldRec."No.");
                    if not TempBlob.HasValue() then begin
                        Fail := Problem.NewFailure(404, 'empty-blob', 'Empty blob', 'the BLOB field has no content');
                        exit(false);
                    end;
                    if TempBlob.Length() > MaxBlobBytes() then begin
                        Fail := TooLarge(TempBlob.Length());
                        exit(false);
                    end;
                    TempBlob.CreateInStream(InStr);
                    exit(true);
                end;
            FieldRec.Type::Media:
                begin
                    // 'Media' is not a valid standalone variable type (AL0157). A Media field's
                    // value is its Media ID (a GUID) into the Tenant Media table.
                    MediaId := FieldRefVal.Value;
                    if IsNullGuid(MediaId) then begin
                        Fail := Problem.NewFailure(404, 'empty-blob', 'Empty media', 'the media field has no content');
                        exit(false);
                    end;
                    if not TenantMedia.Get(MediaId) then begin
                        Fail := Problem.NewFailure(404, 'empty-blob', 'Media not found', 'the media content could not be located');
                        exit(false);
                    end;
                    TenantMedia.CalcFields(Content);
                    if TenantMedia.Content.Length() > MaxBlobBytes() then begin
                        Fail := TooLarge(TenantMedia.Content.Length());
                        exit(false);
                    end;
                    TenantMedia.Content.CreateInStream(InStr);
                    if TenantMedia."Mime Type" <> '' then
                        ContentType := TenantMedia."Mime Type";
                    exit(true);
                end;
            else begin
                Fail := Problem.NewFailure(422, 'mediaset-unsupported', 'MediaSet not supported',
                    'reading a MediaSet field is not supported in v1; read an individual Media or BLOB field instead');
                exit(false);
            end;
        end;
    end;

    local procedure RestrictedField(FieldNo: Integer) Fail: JsonObject
    begin
        Fail := Problem.NewFailure(403, 'field-restricted', 'Field access restricted',
            StrSubstNo('field %1 is not readable under the current field policy', FieldNo));
    end;

    // readBlob answers inline: the bytes are base64'd into one JSON response (~4/3 the size), so an
    // unbounded BLOB would build a response the service tier and the agent's context cannot carry.
    // A fixed ceiling for now; a Setup field ("Max Blob Bytes") is the natural follow-up.
    local procedure MaxBlobBytes(): Integer
    begin
        exit(10 * 1024 * 1024);
    end;

    local procedure TooLarge(Length: Integer) Fail: JsonObject
    begin
        Fail := Problem.NewFailure(413, 'blob-too-large', 'Binary too large',
            StrSubstNo('the binary is %1 bytes; readBlob returns at most %2 bytes inline', Length, MaxBlobBytes()));
    end;

    local procedure SniffFromBase64(B64: Text): Text
    begin
        case true of
            B64.StartsWith('iVBORw0KGgo'):
                exit('image/png');
            B64.StartsWith('/9j/'):
                exit('image/jpeg');
            B64.StartsWith('R0lGOD'):
                exit('image/gif');
            B64.StartsWith('JVBER'):
                exit('application/pdf');
            B64.StartsWith('UEsDB'):
                exit('application/zip');
            B64.StartsWith('PD94bWw'), B64.StartsWith('PHN2Zw'):
                exit('image/svg+xml');
        end;
        exit('application/octet-stream');
    end;
}
