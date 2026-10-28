codeunit 94122 "Bcmag Value Coercer"
{
    // Applies a JSON {field: value} object onto a RecordRef for insert/modify. Each value is
    // coerced to the field's AL type and applied via FieldRef.Validate (default) or .Value.
    // Validation errors are caught per-field and reported as 422 with the offending field.
    //
    // Masked write-back guard (modify only): a caller that reads a field Masked sees its mask rendering,
    // and a client that round-trips a record it read would write that rendering over the real value —
    // silently and for good. The read that served the rendering need not have run under this write's
    // verdict: a caller holding a lift (user exception, Unmask tier) reads masked with "unmask": false
    // and may then write without it, and an exception may be granted between read and write. So the
    // incoming value is compared with EVERY rendering the caller could have been served — under this
    // request's verdict, the opt-out ("strict") verdict and the baseline, each when Masked, profiles
    // deduplicated — of the record's STORED value (re-read, so an earlier field's OnValidate in the same
    // call cannot shift it), rendered by the same masker the projector uses. A match is refused
    // 400 masked-value. A blank stored value has nothing to destroy and is not judged.

    var
        Resolver: Codeunit "Bcmag Field Name Resolver";
        Problem: Codeunit "Bcmag Problem";
        FieldPolicy: Codeunit "Bcmag Field Policy";
        JsonRead: Codeunit "Bcmag Json Read";

    // Existing = true on the modify path (RecRef holds a stored record); false for an insert.
    procedure ApplyValues(var RecRef: RecordRef; Values: JsonObject; ByFieldNo: Boolean; Validate: Boolean; Existing: Boolean; var Fail: JsonObject): Boolean
    var
        Stored: RecordRef;
        Tok: JsonToken;
        KeyName, ErrMsg: Text;
        FieldNo: Integer;
        FieldRefVal: FieldRef;
        Suggest: JsonObject;
        Profiles: List of [Code[20]];
        StoredLoaded, StoredFound: Boolean;
    begin
        foreach KeyName in Values.Keys() do begin
            Values.Get(KeyName, Tok);
            if not ResolveField(RecRef, KeyName, ByFieldNo, FieldNo, Fail) then
                exit(false);
            // Field policy BEFORE any Validate runs for this field — a denied write must not
            // execute the validation trigger (its side effects would leak past the denial).
            // Covers both insert and modify, and both values and valuesByFieldNo shapes.
            if not FieldPolicy.IsWritable(RecRef.Number, FieldNo) then begin
                Fail := Problem.NewFailure(403, 'field-restricted', 'Field access restricted',
                    StrSubstNo('field "%1" is not writable under the current field policy', KeyName));
                exit(false);
            end;
            if Existing then
                if MaskedRenderings(RecRef.Number, FieldNo, Profiles) then begin
                    if not StoredLoaded then begin
                        StoredFound := LoadStored(RecRef, Stored);
                        StoredLoaded := true;
                    end;
                    if StoredFound then
                        if EchoesAnyMask(Stored.Number, Stored.Field(FieldNo), Tok, Profiles) then begin
                            Clear(Suggest);
                            Suggest.Add('field', KeyName);
                            Fail := Problem.NewFailureSuggest(400, 'masked-value', 'Masked value',
                                'the value is the masked rendering of the current value; send the real value or omit the field', Suggest);
                            exit(false);
                        end;
                end;
            FieldRefVal := RecRef.Field(FieldNo);
            if not ApplyOne(FieldRefVal, Tok, Validate, ErrMsg) then begin
                Clear(Suggest);
                Suggest.Add('field', KeyName);
                Fail := Problem.NewFailureSuggest(422, 'validation', 'Validation failed',
                    StrSubstNo('field "%1": %2', KeyName, ErrMsg), Suggest);
                exit(false);
            end;
        end;
        exit(true);
    end;

    // The record as stored (not as this call has changed it so far). Read once per call, and only when a
    // Masked field is being written.
    local procedure LoadStored(RecRef: RecordRef; var Stored: RecordRef): Boolean
    begin
        Stored.Open(RecRef.Number);
        exit(Stored.Get(RecRef.RecordId));
    end;

    // The profiles of every Masked rendering this caller could have been served for the field: this
    // request's verdict, the opt-out verdict and the baseline (all cached by the policy, no reads of
    // their own beyond its per-instance caches). False when none of them is Masked.
    local procedure MaskedRenderings(TableId: Integer; FieldNo: Integer; var Profiles: List of [Code[20]]): Boolean
    var
        ProfileCode: Code[20];
    begin
        Clear(Profiles);
        if FieldPolicy.ReadVerdict(TableId, FieldNo, ProfileCode) = "Bcmag Read Access"::Masked then
            AddProfile(Profiles, ProfileCode);
        if FieldPolicy.StrictReadVerdict(TableId, FieldNo, ProfileCode) = "Bcmag Read Access"::Masked then
            AddProfile(Profiles, ProfileCode);
        if FieldPolicy.BaselineReadVerdict(TableId, FieldNo, ProfileCode) = "Bcmag Read Access"::Masked then
            AddProfile(Profiles, ProfileCode);
        exit(Profiles.Count() > 0);
    end;

    local procedure AddProfile(var Profiles: List of [Code[20]]; ProfileCode: Code[20])
    begin
        if not Profiles.Contains(ProfileCode) then
            Profiles.Add(ProfileCode);
    end;

    local procedure EchoesAnyMask(TableNo: Integer; StoredRef: FieldRef; Tok: JsonToken; Profiles: List of [Code[20]]): Boolean
    var
        Masker: Codeunit "Bcmag Field Masker";
        ProfileCode: Code[20];
    begin
        if StoredRef.Type in [FieldType::Blob, FieldType::Media, FieldType::MediaSet] then
            exit(false);
        if IsBlankValue(TableNo, StoredRef) then
            exit(false);
        foreach ProfileCode in Profiles do
            if EchoesMask(Masker, StoredRef, Tok, ProfileCode) then
                exit(true);
        exit(false);
    end;

    // True when Tok is exactly what a Masked reader saw for the stored value under one profile: the
    // masker's rendering (a string — partial, hash or fixed — or JSON null), compared as text so a
    // number sent for a numeric-looking rendering still matches. A Code field uppercases whatever is
    // assigned to it, so there '****ab' would land as '****AB' — the rendering of 'XYZWAB' — and the
    // comparison is case-insensitive.
    local procedure EchoesMask(var Masker: Codeunit "Bcmag Field Masker"; StoredRef: FieldRef; Tok: JsonToken; ProfileCode: Code[20]): Boolean
    var
        Rendering: JsonObject;
        RenderedTok: JsonToken;
    begin
        Masker.AddMaskedValue(Rendering, 'value', StoredRef, ProfileCode);
        Rendering.Get('value', RenderedTok);
        if JsonRead.IsNull(RenderedTok) then
            exit(JsonRead.IsNull(Tok));
        if not JsonRead.IsNonNullValue(Tok) then
            exit(false);
        if StoredRef.Type = FieldType::Code then
            exit(UpperCase(Tok.AsValue().AsText()) = UpperCase(RenderedTok.AsValue().AsText()));
        exit(Tok.AsValue().AsText() = RenderedTok.AsValue().AsText());
    end;

    // The field holds its type's blank value. Compared through a blank record of the same table, so the
    // invariant Format of both sides comes from the same type (no per-type blank table to drift).
    local procedure IsBlankValue(TableNo: Integer; StoredRef: FieldRef): Boolean
    var
        BlankRec: RecordRef;
    begin
        BlankRec.Open(TableNo, true);
        exit(Format(StoredRef.Value, 0, 9) = Format(BlankRec.Field(StoredRef.Number).Value, 0, 9));
    end;

    local procedure ResolveField(var RecRef: RecordRef; KeyName: Text; ByFieldNo: Boolean; var FieldNo: Integer; var Fail: JsonObject): Boolean
    var
        Suggestion: Text;
        Suggest: JsonObject;
    begin
        if ByFieldNo then begin
            if not Evaluate(FieldNo, KeyName) then begin
                Fail := Problem.NewFailure(400, 'unknown-field', 'Invalid field number', StrSubstNo('"%1" is not a valid field number', KeyName));
                exit(false);
            end;
        end else
            if not Resolver.ResolveByName(RecRef.Number, KeyName, FieldNo, Suggestion) then begin
                Clear(Suggest);
                if Suggestion <> '' then begin
                    Suggest.Add('field', Suggestion);
                    Fail := Problem.NewFailureSuggest(400, 'unknown-field', 'Unknown field',
                        StrSubstNo('unknown field "%1" — did you mean "%2"?', KeyName, Suggestion), Suggest);
                end else
                    Fail := Problem.NewFailure(400, 'unknown-field', 'Unknown field', StrSubstNo('unknown field "%1"', KeyName));
                exit(false);
            end;
        if not RecRef.FieldExist(FieldNo) then begin
            Fail := Problem.NewFailure(400, 'unknown-field', 'Unknown field', StrSubstNo('field %1 does not exist', FieldNo));
            exit(false);
        end;
        exit(true);
    end;

    local procedure ApplyOne(var FieldRefVal: FieldRef; Tok: JsonToken; Validate: Boolean; var ErrMsg: Text): Boolean
    var
        NewVal: Variant;
        BuildErr: Text;
        BuiltOk: Boolean;
    begin
        if JsonRead.IsNull(Tok) then begin
            // Null clears the field to a TYPED blank (an empty Variant would error).
            BuildBlank(FieldRefVal, NewVal);
            if not TrySet(FieldRefVal, NewVal, Validate) then begin
                ErrMsg := GetLastErrorText();
                exit(false);
            end;
            exit(true);
        end;
        // BuildVariant reads the JSON value with typed accessors (AsBigInteger/AsBoolean/AsText/...)
        // that THROW on a type mismatch (e.g. a JSON object/array where a scalar is expected). Run it
        // inside a try so such a mismatch becomes a 422 'validation' (the caller wraps a false return
        // with the field name) instead of an unguarded AL error the dispatcher would surface as 500.
        if not TryBuildVariant(FieldRefVal, Tok, NewVal, BuildErr, BuiltOk) then begin
            ErrMsg := GetLastErrorText();
            exit(false);
        end;
        if not BuiltOk then begin
            ErrMsg := BuildErr;
            exit(false);
        end;
        if not TrySet(FieldRefVal, NewVal, Validate) then begin
            ErrMsg := GetLastErrorText();
            exit(false);
        end;
        exit(true);
    end;

    [TryFunction]
    local procedure TryBuildVariant(FieldRefVal: FieldRef; Tok: JsonToken; var NewVal: Variant; var BuildErr: Text; var BuiltOk: Boolean)
    begin
        BuiltOk := BuildVariant(FieldRefVal, Tok, NewVal, BuildErr);
    end;

    local procedure BuildVariant(FieldRefVal: FieldRef; Tok: JsonToken; var NewVal: Variant; var ErrMsg: Text): Boolean
    var
        Val: JsonValue;
        DecV: Decimal;
        BigV: BigInteger;
        DateV: Date;
        TimeV: Time;
        DtV: DateTime;
        DurV: Duration;
        GuidV: Guid;
        OrdV: Integer;
        Obj: JsonObject;
        SubTok: JsonToken;
    begin
        case FieldRefVal.Type of
            FieldType::Integer, FieldType::BigInteger:
                begin
                    BigV := Tok.AsValue().AsBigInteger();
                    NewVal := BigV;
                end;
            FieldType::Decimal:
                begin
                    Val := Tok.AsValue();
                    if ValueIsString(Val) then begin
                        if not Evaluate(DecV, Val.AsText(), 9) then begin
                            ErrMsg := StrSubstNo('"%1" is not a valid decimal', Val.AsText());
                            exit(false);
                        end;
                    end else
                        DecV := Val.AsDecimal();
                    NewVal := DecV;
                end;
            FieldType::Boolean:
                NewVal := Tok.AsValue().AsBoolean();
            FieldType::Code, FieldType::Text:
                NewVal := Tok.AsValue().AsText();
            FieldType::Date:
                begin
                    if not Evaluate(DateV, Tok.AsValue().AsText(), 9) then begin
                        ErrMsg := 'expected a date (YYYY-MM-DD)';
                        exit(false);
                    end;
                    NewVal := DateV;
                end;
            FieldType::Time:
                begin
                    if not Evaluate(TimeV, Tok.AsValue().AsText(), 9) then begin
                        ErrMsg := 'expected a time (HH:MM:SS)';
                        exit(false);
                    end;
                    NewVal := TimeV;
                end;
            FieldType::DateTime:
                begin
                    if not Evaluate(DtV, Tok.AsValue().AsText(), 9) then begin
                        ErrMsg := 'expected an RFC 3339 UTC datetime';
                        exit(false);
                    end;
                    NewVal := DtV;
                end;
            FieldType::Duration:
                begin
                    // Mirror the read side (Format(Dur,0,9)) so a value round-trips.
                    if not Evaluate(DurV, Tok.AsValue().AsText(), 9) then begin
                        ErrMsg := 'expected a duration (ISO 8601, e.g. PT1H30M)';
                        exit(false);
                    end;
                    NewVal := DurV;
                end;
            FieldType::Guid:
                begin
                    if not Evaluate(GuidV, Tok.AsValue().AsText()) then begin
                        ErrMsg := 'expected a GUID';
                        exit(false);
                    end;
                    NewVal := GuidV;
                end;
            FieldType::Option:
                begin
                    // Accept an ordinal, an {ord} object, or a name string (let Validate map it).
                    if Tok.IsObject() then begin
                        Obj := Tok.AsObject();
                        if Obj.Get('ord', SubTok) then begin
                            OrdV := SubTok.AsValue().AsInteger();
                            NewVal := OrdV;
                        end else
                            if Obj.Get('name', SubTok) then
                                NewVal := SubTok.AsValue().AsText()
                            else begin
                                ErrMsg := 'option object must have "ord" or "name"';
                                exit(false);
                            end;
                    end else
                        if ValueIsString(Tok.AsValue()) then
                            NewVal := Tok.AsValue().AsText()
                        else begin
                            OrdV := Tok.AsValue().AsInteger();
                            NewVal := OrdV;
                        end;
                end;
            else begin
                ErrMsg := StrSubstNo('field type %1 cannot be written', Format(FieldRefVal.Type));
                exit(false);
            end;
        end;
        exit(true);
    end;

    local procedure BuildBlank(FieldRefVal: FieldRef; var NewVal: Variant)
    var
        TextV: Text;
        IntV: Integer;
        DecV: Decimal;
        BoolV: Boolean;
        DateV: Date;
        TimeV: Time;
        DtV: DateTime;
        DurV: Duration;
        GuidV: Guid;
    begin
        case FieldRefVal.Type of
            FieldType::Integer, FieldType::BigInteger, FieldType::Option:
                begin
                    IntV := 0;
                    NewVal := IntV;
                end;
            FieldType::Decimal:
                begin
                    DecV := 0;
                    NewVal := DecV;
                end;
            FieldType::Boolean:
                begin
                    BoolV := false;
                    NewVal := BoolV;
                end;
            FieldType::Date:
                begin
                    DateV := 0D;
                    NewVal := DateV;
                end;
            FieldType::Time:
                begin
                    TimeV := 0T;
                    NewVal := TimeV;
                end;
            FieldType::DateTime:
                begin
                    DtV := 0DT;
                    NewVal := DtV;
                end;
            FieldType::Duration:
                begin
                    DurV := 0;
                    NewVal := DurV;
                end;
            FieldType::Guid:
                begin
                    Clear(GuidV);
                    NewVal := GuidV;
                end;
            else begin
                TextV := '';
                NewVal := TextV;
            end;
        end;
    end;

    // JsonValue has no IsString() (AL0132). A JSON string serialises with surrounding quotes
    // while numbers/booleans/null do not, so a leading '"' reliably distinguishes a string —
    // letting us tell a quoted decimal ("12.50") from a JSON number, and an option name from
    // its ordinal, exactly as before.
    local procedure ValueIsString(JVal: JsonValue): Boolean
    var
        Serialized: Text;
    begin
        if JVal.IsNull() or JVal.IsUndefined() then
            exit(false);
        JVal.WriteTo(Serialized);
        exit(Serialized.StartsWith('"'));
    end;

    [TryFunction]
    local procedure TrySet(var FieldRefVal: FieldRef; NewVal: Variant; Validate: Boolean)
    begin
        if Validate then
            FieldRefVal.Validate(NewVal)
        else
            FieldRefVal.Value := NewVal;
    end;
}
