codeunit 94105 "Bcmag Type Mapper"
{
    // AL value -> JSON per spec §9. AddFieldValue adds the typed value directly to the
    // target object (so Option can emit a {ord,name} object, which a bare JsonValue cannot
    // hold). FieldRefToJson is a thin convenience used by unit tests.

    procedure AddFieldValue(var Target: JsonObject; Name: Text; FieldRef: FieldRef; DecimalStringThreshold: BigInteger)
    var
        IntVal: Integer;
        BigVal: BigInteger;
        DecVal: Decimal;
        BoolVal: Boolean;
        DateVal: Date;
        TimeVal: Time;
        DtVal: DateTime;
        TextVal: Text;
        GuidVal: Guid;
        DurVal: Duration;
        DfVal: DateFormula;
        RecIdVal: RecordId;
        OptionObj: JsonObject;
        NullVal: JsonValue;
    begin
        NullVal.SetValueToNull();
        case FieldRef.Type of
            FieldType::Integer:
                begin
                    IntVal := FieldRef.Value;
                    Target.Add(Name, IntVal);
                end;
            FieldType::BigInteger:
                begin
                    BigVal := FieldRef.Value;
                    Target.Add(Name, Format(BigVal, 0, 9));
                end;
            FieldType::Decimal:
                begin
                    DecVal := FieldRef.Value;
                    if Abs(DecVal) >= DecimalStringThreshold then
                        Target.Add(Name, Format(DecVal, 0, 9))
                    else
                        Target.Add(Name, DecVal);
                end;
            FieldType::Boolean:
                begin
                    BoolVal := FieldRef.Value;
                    Target.Add(Name, BoolVal);
                end;
            FieldType::Code, FieldType::Text:
                begin
                    // Emitted verbatim: a Text value's leading/trailing spaces are data (a Code value
                    // cannot carry them), and trimming here would make a read disagree with the
                    // filter that matched it.
                    TextVal := FieldRef.Value;
                    if TextVal = '' then
                        Target.Add(Name, NullVal)
                    else
                        Target.Add(Name, TextVal);
                end;
            FieldType::Date:
                begin
                    DateVal := FieldRef.Value;
                    if DateVal = 0D then
                        Target.Add(Name, NullVal)
                    else
                        Target.Add(Name, Format(DateVal, 0, 9));
                end;
            FieldType::Time:
                begin
                    TimeVal := FieldRef.Value;
                    if TimeVal = 0T then
                        Target.Add(Name, NullVal)
                    else
                        Target.Add(Name, Format(TimeVal, 0, 9));
                end;
            FieldType::DateTime:
                begin
                    DtVal := FieldRef.Value;
                    if DtVal = 0DT then
                        Target.Add(Name, NullVal)
                    else
                        Target.Add(Name, FormatUtc(DtVal));
                end;
            FieldType::Duration:
                begin
                    DurVal := FieldRef.Value;
                    if DurVal = 0 then
                        Target.Add(Name, NullVal)
                    else
                        Target.Add(Name, Format(DurVal, 0, 9));
                end;
            FieldType::Guid:
                begin
                    GuidVal := FieldRef.Value;
                    if IsNullGuid(GuidVal) then
                        Target.Add(Name, NullVal)
                    else
                        Target.Add(Name, LowerCase(DelChr(Format(GuidVal), '<>', '{}')));
                end;
            FieldType::Option:
                begin
                    // 'name' is the language-invariant member name — the same string describe's
                    // optionMembers[].name carries. Format(FieldRef.Value) would be the caption in
                    // the session language, so the pair would only match on English sessions.
                    IntVal := FieldRef.Value;
                    OptionObj.Add('ord', IntVal);
                    OptionObj.Add('name', OptionMemberName(FieldRef, IntVal));
                    Target.Add(Name, OptionObj);
                end;
            FieldType::DateFormula:
                begin
                    DfVal := FieldRef.Value;
                    TextVal := Format(DfVal, 0, 9);
                    if TextVal = '' then
                        Target.Add(Name, NullVal)
                    else
                        Target.Add(Name, TextVal);
                end;
            FieldType::RecordId:
                begin
                    RecIdVal := FieldRef.Value;
                    TextVal := Format(RecIdVal, 0, 9);
                    if TextVal = '' then
                        Target.Add(Name, NullVal)
                    else
                        Target.Add(Name, TextVal);
                end;
            FieldType::TableFilter:
                begin
                    TextVal := Format(FieldRef.Value);
                    if TextVal = '' then
                        Target.Add(Name, NullVal)
                    else
                        Target.Add(Name, TextVal);
                end;
            else
                Target.Add(Name, NullVal);
        end;
    end;

    procedure FieldRefToJson(FieldRef: FieldRef; DecimalStringThreshold: BigInteger) Result: JsonToken
    var
        Holder: JsonObject;
        Tok: JsonToken;
    begin
        AddFieldValue(Holder, 'v', FieldRef, DecimalStringThreshold);
        Holder.Get('v', Tok);
        Result := Tok;
    end;

    // A stored ordinal that is no longer a member (data written before a value was removed) has no
    // name; the ordinal itself is then the only honest identifier, so the name is empty rather
    // than a 500 for the whole page.
    local procedure OptionMemberName(FieldRef: FieldRef; Ordinal: Integer): Text
    var
        MemberName: Text;
    begin
        if TryEnumValueName(FieldRef, Ordinal, MemberName) then
            exit(MemberName);
        exit('');
    end;

    [TryFunction]
    local procedure TryEnumValueName(FieldRef: FieldRef; Ordinal: Integer; var MemberName: Text)
    begin
        MemberName := FieldRef.GetEnumValueNameFromOrdinalValue(Ordinal);
    end;

    // Format(DateTime,0,9) yields the round-trip ISO 8601 form. CurrentDateTime is UTC on
    // BC SaaS; we additionally guarantee a trailing 'Z' so consumers always read UTC.
    local procedure FormatUtc(Dt: DateTime): Text
    var
        Iso: Text;
    begin
        Iso := Format(Dt, 0, 9);
        if (StrLen(Iso) > 0) and (Iso[StrLen(Iso)] <> 'Z') and (StrPos(Iso, '+') = 0) then
            Iso += 'Z';
        exit(Iso);
    end;
}
