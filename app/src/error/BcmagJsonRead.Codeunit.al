codeunit 94145 "Bcmag Json Read"
{
    // Typed reads of caller-supplied `data` members.
    //
    // Why this exists: `Tok.AsValue().AsInteger()` RAISES when the member is an object/array, a
    // null, or a string that will not coerce. Inside a handler that raise is caught by the
    // Codeunit.Run boundary and surfaces as a synthesised 500 carrying a raw AL error and no
    // `suggest` — which tells an agent "internal error" when the truth is "you sent a string where
    // a number goes". Every other input mistake in this protocol is a typed 400 with a repair path,
    // so wrong-typed members must be too. Route every read of a caller-controlled member through
    // here rather than calling AsValue() directly.
    //
    // Each Read* returns false with `Fail` populated (400 'invalid-field', naming the member and the
    // type it wanted). Presence and null-handling stay at the call site — the ops disagree on
    // whether an absent member is a 400, a default, or simply skipped, and that is their business.

    var
        Problem: Codeunit "Bcmag Problem";

    procedure ReadInteger(Tok: JsonToken; MemberName: Text; var Value: Integer; var Fail: JsonObject): Boolean
    begin
        if not IsUsableValue(Tok) then begin
            Fail := Invalid(MemberName, 'a number');
            exit(false);
        end;
        if not TryInteger(Tok, Value) then begin
            Fail := Invalid(MemberName, 'a number');
            exit(false);
        end;
        exit(true);
    end;

    procedure ReadText(Tok: JsonToken; MemberName: Text; var Value: Text; var Fail: JsonObject): Boolean
    begin
        if not IsUsableValue(Tok) then begin
            Fail := Invalid(MemberName, 'a string');
            exit(false);
        end;
        if not TryText(Tok, Value) then begin
            Fail := Invalid(MemberName, 'a string');
            exit(false);
        end;
        exit(true);
    end;

    procedure ReadBoolean(Tok: JsonToken; MemberName: Text; var Value: Boolean; var Fail: JsonObject): Boolean
    begin
        if not IsUsableValue(Tok) then begin
            Fail := Invalid(MemberName, 'a boolean (true or false)');
            exit(false);
        end;
        if not TryBoolean(Tok, Value) then begin
            Fail := Invalid(MemberName, 'a boolean (true or false)');
            exit(false);
        end;
        exit(true);
    end;

    procedure ReadArray(Tok: JsonToken; MemberName: Text; var Value: JsonArray; var Fail: JsonObject): Boolean
    begin
        if not Tok.IsArray() then begin
            Fail := Invalid(MemberName, 'an array');
            exit(false);
        end;
        Value := Tok.AsArray();
        exit(true);
    end;

    procedure ReadObject(Tok: JsonToken; MemberName: Text; var Value: JsonObject; var Fail: JsonObject): Boolean
    begin
        if not Tok.IsObject() then begin
            Fail := Invalid(MemberName, 'an object');
            exit(false);
        end;
        Value := Tok.AsObject();
        exit(true);
    end;

    // A JSON null is not a usable value for any of the typed reads: a caller that means "omit"
    // should omit. Call sites that deliberately treat null as absent check for it themselves
    // before calling in here.
    local procedure IsUsableValue(Tok: JsonToken): Boolean
    begin
        exit(IsNonNullValue(Tok));
    end;

    // AL evaluates BOTH operands of and/or, so `Tok.IsValue() and Tok.AsValue().IsNull()` raises
    // "Unable to convert JsonToken to JsonValue" whenever the token is an object or array. These two
    // tests are the safe spelling; use them instead of inlining the guard.
    procedure IsNonNullValue(Tok: JsonToken): Boolean
    begin
        if not Tok.IsValue() then
            exit(false);
        exit(not Tok.AsValue().IsNull());
    end;

    // Obj.Name present and a non-null scalar. Get + IsValue + AsValue nested, never and-ed.
    procedure GetValue(Obj: JsonObject; Name: Text; var Tok: JsonToken): Boolean
    begin
        if not Obj.Get(Name, Tok) then
            exit(false);
        exit(IsNonNullValue(Tok));
    end;

    procedure IsNull(Tok: JsonToken): Boolean
    begin
        if not Tok.IsValue() then
            exit(false);
        exit(Tok.AsValue().IsNull());
    end;

    local procedure Invalid(MemberName: Text; Wanted: Text) Fail: JsonObject
    begin
        Fail := Problem.NewFailure(400, 'invalid-field', StrSubstNo('Invalid %1', MemberName),
            StrSubstNo('data.%1 must be %2', MemberName, Wanted));
    end;

    [TryFunction]
    local procedure TryInteger(Tok: JsonToken; var Value: Integer)
    begin
        Value := Tok.AsValue().AsInteger();
    end;

    [TryFunction]
    local procedure TryText(Tok: JsonToken; var Value: Text)
    begin
        Value := Tok.AsValue().AsText();
    end;

    [TryFunction]
    local procedure TryBoolean(Tok: JsonToken; var Value: Boolean)
    begin
        Value := Tok.AsValue().AsBoolean();
    end;
}
