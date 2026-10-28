codeunit 94107 "Bcmag Record Id Codec"
{
    procedure Encode(RecId: RecordId): Text
    var
        Base64: Codeunit "Base64 Convert";
    begin
        // Format number 0 emits the language-invariant table NAME (e.g. "Customer: ...").
        // Format number 1 would emit the localized table CAPTION ("Kunde: ..." in Danish), which
        // the plain Evaluate in Decode cannot parse in a different session language — so a token
        // minted in a non-English session would 404 on a later read/write. 0 pairs with the
        // default-format Evaluate used in Decode, giving a stable cross-language round-trip.
        // InsertLineBreaks=false: the token is carried in the JSON body (data.recordId), so standard
        // base64 is fine, but line breaks in long composite-PK tokens are not — keep it single-line.
        // (This System App version exposes no ToBase64Url.)
        exit(Base64.ToBase64(Format(RecId, 0, 0), false));
    end;

    procedure Decode(Token: Text; var RecRef: RecordRef; var ErrorMsg: Text): Boolean
    var
        Base64: Codeunit "Base64 Convert";
        Decoded: Text;
        RecId: RecordId;
        Found: Boolean;
    begin
        if not TryDecodeText(Base64, Token, Decoded) then begin
            ErrorMsg := 'recordId token is not valid base64';
            exit(false);
        end;
        if not Evaluate(RecId, Decoded) then begin
            ErrorMsg := 'recordId token does not decode to a RecordId';
            exit(false);
        end;
        // Read under the caller's security filter: an out-of-scope record reads as "not found" (so a
        // crafted recordId can't probe existence), and any read error (e.g. a blank RecordId) is caught
        // and reported as 404 rather than surfacing as a raw 500.
        if not TryGetFiltered(RecRef, RecId, Found) then begin
            ErrorMsg := 'recordId is not accessible';
            exit(false);
        end;
        if not Found then begin
            ErrorMsg := 'recordId points to a non-existent record or is outside your security scope';
            exit(false);
        end;
        exit(true);
    end;

    // The table a token addresses, WITHOUT touching the database — the record may be gone (the row a
    // delete response describes) and must still be judged by its table. False for a token that is not
    // one of ours.
    procedure TableNoOf(Token: Text; var TableNo: Integer): Boolean
    var
        Base64: Codeunit "Base64 Convert";
        Decoded: Text;
        RecId: RecordId;
    begin
        TableNo := 0;
        if not TryDecodeText(Base64, Token, Decoded) then
            exit(false);
        if not Evaluate(RecId, Decoded) then
            exit(false);
        TableNo := RecId.TableNo();
        exit(TableNo <> 0);
    end;

    [TryFunction]
    local procedure TryDecodeText(var Base64: Codeunit "Base64 Convert"; Token: Text; var Decoded: Text)
    begin
        Decoded := Base64.FromBase64(Token);
    end;

    [TryFunction]
    local procedure TryGetFiltered(var RecRef: RecordRef; RecId: RecordId; var Found: Boolean)
    begin
        RecRef.Open(RecId.TableNo());
        RecRef.SecurityFiltering := SecurityFilter::Filtered;
        Found := RecRef.Get(RecId);
    end;
}
