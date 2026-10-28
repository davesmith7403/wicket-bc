codeunit 94101 "Bcmag Envelope"
{
    // Back-compat overload: callers that predate the optional idempotencyKey member.
    procedure Parse(Body: JsonObject; var Id: Text; var IssuedAt: DateTime; var Origin: Text; var Data: JsonObject; var ErrorMsg: Text): Boolean
    var
        IdemKey: Text;
    begin
        exit(Parse(Body, Id, IssuedAt, Origin, Data, IdemKey, ErrorMsg));
    end;

    procedure Parse(Body: JsonObject; var Id: Text; var IssuedAt: DateTime; var Origin: Text; var Data: JsonObject; var IdemKey: Text; var ErrorMsg: Text): Boolean
    var
        Tok: JsonToken;
    begin
        // Type-check every token before converting it. This runs OUTSIDE the Op Runner's
        // Codeunit.Run boundary, so an unguarded AsValue()/AsObject() on a wrong-typed member
        // (e.g. {"id": {}} or {"data": []}) would raise a raw AL error that escapes as a non-200
        // response with no RFC 7807 body and no log row. Returning a clean 400 keeps the contract.
        if not Body.Get('id', Tok) then begin
            ErrorMsg := 'missing required field "id"';
            exit(false);
        end;
        if not IsString(Tok) then begin
            ErrorMsg := 'field "id" must be a string';
            exit(false);
        end;
        Id := Tok.AsValue().AsText();
        if Id = '' then begin
            ErrorMsg := 'field "id" must not be empty';
            exit(false);
        end;

        if not Body.Get('issuedAt', Tok) then begin
            ErrorMsg := 'missing required field "issuedAt"';
            exit(false);
        end;
        if not IsString(Tok) then begin
            ErrorMsg := 'field "issuedAt" must be a string';
            exit(false);
        end;
        if not Evaluate(IssuedAt, Tok.AsValue().AsText(), 9) then begin
            ErrorMsg := 'field "issuedAt" must be RFC 3339 UTC';
            exit(false);
        end;

        if not Body.Get('origin', Tok) then begin
            ErrorMsg := 'missing required field "origin"';
            exit(false);
        end;
        if not IsString(Tok) then begin
            ErrorMsg := 'field "origin" must be a string';
            exit(false);
        end;
        Origin := Tok.AsValue().AsText();
        if not OriginIsValid(Origin) then begin
            ErrorMsg := 'field "origin" failed validation (max 256 chars, [A-Za-z0-9._@/+\-:])';
            exit(false);
        end;

        if not Body.Get('data', Tok) then begin
            ErrorMsg := 'missing required field "data"';
            exit(false);
        end;
        if not Tok.IsObject() then begin
            ErrorMsg := 'field "data" must be an object';
            exit(false);
        end;
        Data := Tok.AsObject();

        // Optional member: a bound action cannot read HTTP headers, so the Idempotency-Key
        // travels inside the envelope. Absent (or empty) means "no idempotency semantics".
        IdemKey := '';
        if Body.Get('idempotencyKey', Tok) then begin
            if not IsString(Tok) then begin
                ErrorMsg := 'field "idempotencyKey" must be a string';
                exit(false);
            end;
            IdemKey := Tok.AsValue().AsText();
            if not IdemKeyIsValid(IdemKey) then begin
                ErrorMsg := 'field "idempotencyKey" failed validation (max 128 chars, no control characters)';
                exit(false);
            end;
        end;
        exit(true);
    end;

    // A required string member: present as a JSON value and not JSON null. Guards AsText() from
    // throwing on an object/array (not a value) or a null value.
    local procedure IsString(Tok: JsonToken): Boolean
    begin
        if not Tok.IsValue() then exit(false);
        exit(not Tok.AsValue().IsNull());
    end;

    // Max 128 (table field width) and printable only: the key is echoed into log rows and
    // problem details, so control characters (log forgery, terminal escapes) are rejected.
    local procedure IdemKeyIsValid(IdemKey: Text): Boolean
    var
        i: Integer;
        Ch: Char;
    begin
        if StrLen(IdemKey) > 128 then exit(false);
        for i := 1 to StrLen(IdemKey) do begin
            Ch := IdemKey[i];
            if (Ch < 32) or (Ch = 127) then
                exit(false);
        end;
        exit(true);
    end;

    local procedure OriginIsValid(Origin: Text): Boolean
    var
        i: Integer;
        Ch: Char;
    begin
        if StrLen(Origin) > 256 then exit(false);
        if StrLen(Origin) = 0 then exit(false);
        for i := 1 to StrLen(Origin) do begin
            Ch := Origin[i];
            if not (Ch in ['A' .. 'Z', 'a' .. 'z', '0' .. '9', '.', '_', '@', '/', '+', '-', ':']) then
                exit(false);
        end;
        exit(true);
    end;
}
