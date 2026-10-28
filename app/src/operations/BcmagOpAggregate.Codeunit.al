codeunit 94130 "Bcmag Op Aggregate"
{
    // Server-side aggregation for the query operation: count/sum/avg/min/max computed over the
    // SAME injection-hardened filtered set the row plane reads. "Bcmag Op Query" resolves
    // tableId, exposure and filters, then hands the opened, filtered RecordRef here; this
    // codeunit only validates the aggregate shape, enforces the field policy, and computes.
    // Field policy is airtight by design: an aggregate over a hidden field (sum, min, even a
    // filtered count on it upstream) is an inference oracle, so every named field must pass
    // IsReadable before anything is computed.

    var
        Setup: Record "Bcmag Setup";
        Problem: Codeunit "Bcmag Problem";
        Resolver: Codeunit "Bcmag Field Name Resolver";
        FieldPolicy: Codeunit "Bcmag Field Policy";
        TypeMapper: Codeunit "Bcmag Type Mapper";
        JsonRead: Codeunit "Bcmag Json Read";

    procedure Run(TableId: Integer; Agg: JsonObject; var RecRef: RecordRef; var Response: JsonObject; var Fail: JsonObject; var Cost: Integer): Boolean
    var
        Tok: JsonToken;
        SumFieldNos, AvgFieldNos, MinFieldNos, MaxFieldNos: List of [Integer];
        Result, SumObj, AvgObj, MinObj, MaxObj: JsonObject;
        WantCount: Boolean;
        RowCount: Integer;
    begin
        Setup.GetSingleton();
        if not ValidateKeys(Agg, Fail) then exit(false);
        if Agg.Get('count', Tok) then
            if not JsonRead.ReadBoolean(Tok, 'aggregate.count', WantCount, Fail) then exit(false);
        if not ResolveFieldList(TableId, Agg, 'sum', true, SumFieldNos, Fail) then exit(false);
        if not ResolveFieldList(TableId, Agg, 'avg', true, AvgFieldNos, Fail) then exit(false);
        if not ResolveFieldList(TableId, Agg, 'min', false, MinFieldNos, Fail) then exit(false);
        if not ResolveFieldList(TableId, Agg, 'max', false, MaxFieldNos, Fail) then exit(false);

        if not WantCount and (SumFieldNos.Count() + AvgFieldNos.Count() + MinFieldNos.Count() + MaxFieldNos.Count() = 0) then begin
            Fail := Problem.NewFailure(400, 'invalid-aggregate', 'Invalid aggregate request',
                '"aggregate" must request at least one of count, sum, avg, min, max');
            exit(false);
        end;

        // Cost = 1 base + one unit per aggregate computation performed.
        Cost := 1;
        if WantCount or (AvgFieldNos.Count() > 0) then
            RowCount := RecRef.Count();

        if WantCount then begin
            Result.Add('count', RowCount);
            Cost += 1;
        end;
        if SumFieldNos.Count() > 0 then begin
            if not ComputeSums(RecRef, SumFieldNos, SumObj, Fail) then exit(false);
            Result.Add('sum', SumObj);
            Cost += SumFieldNos.Count();
        end;
        if AvgFieldNos.Count() > 0 then begin
            if not ComputeAvgs(RecRef, AvgFieldNos, RowCount, AvgObj, Fail) then exit(false);
            Result.Add('avg', AvgObj);
            Cost += AvgFieldNos.Count();
        end;
        if MinFieldNos.Count() > 0 then begin
            if not ComputeExtremes(RecRef, MinFieldNos, true, MinObj, Fail) then exit(false);
            Result.Add('min', MinObj);
            Cost += MinFieldNos.Count();
        end;
        if MaxFieldNos.Count() > 0 then begin
            if not ComputeExtremes(RecRef, MaxFieldNos, false, MaxObj, Fail) then exit(false);
            Result.Add('max', MaxObj);
            Cost += MaxFieldNos.Count();
        end;

        Clear(Response);
        Response.Add('value', Result);
        exit(true);
    end;

    // Strict shape check: a typo like "mim" must fail loudly, not silently compute nothing.
    local procedure ValidateKeys(Agg: JsonObject; var Fail: JsonObject): Boolean
    var
        Allowed: List of [Text];
        KeyName: Text;
    begin
        Allowed.Add('count');
        Allowed.Add('sum');
        Allowed.Add('avg');
        Allowed.Add('min');
        Allowed.Add('max');
        foreach KeyName in Agg.Keys() do
            if not Allowed.Contains(KeyName) then begin
                Fail := Problem.NewFailure(400, 'invalid-aggregate', 'Invalid aggregate request',
                    StrSubstNo('unknown aggregate key "%1"; supported: count, sum, avg, min, max', KeyName));
                exit(false);
            end;
        exit(true);
    end;

    // Resolves one aggregate field list by name (Levenshtein suggestion on miss, like select),
    // then enforces the field policy and the per-computation type rules. Duplicates are folded
    // so the same field never produces two identical result keys (JsonObject.Add would error).
    local procedure ResolveFieldList(TableId: Integer; Agg: JsonObject; KeyName: Text; Summable: Boolean; var FieldNos: List of [Integer]; var Fail: JsonObject): Boolean
    var
        FieldRec: Record Field;
        Tok, EntryTok: JsonToken;
        Arr: JsonArray;
        Suggest: JsonObject;
        Name, Suggestion: Text;
        FieldNo, i: Integer;
    begin
        if not Agg.Get(KeyName, Tok) then exit(true);
        if not JsonRead.ReadArray(Tok, 'aggregate.' + KeyName, Arr, Fail) then exit(false);
        if Arr.Count() > Setup."Max Select Fields" then begin
            Fail := Problem.NewFailure(413, 'payload-too-large', 'Too many fields',
                StrSubstNo('"aggregate.%1" has %2 entries; the limit is %3', KeyName, Arr.Count(), Setup."Max Select Fields"));
            exit(false);
        end;
        for i := 0 to Arr.Count() - 1 do begin
            Arr.Get(i, EntryTok);
            if not JsonRead.ReadText(EntryTok, 'aggregate.' + KeyName + '[]', Name, Fail) then exit(false);
            if not Resolver.ResolveByName(TableId, Name, FieldNo, Suggestion) then begin
                Clear(Suggest);
                if Suggestion <> '' then begin
                    Suggest.Add('field', Suggestion);
                    Fail := Problem.NewFailureSuggest(400, 'unknown-field', 'Unknown field',
                        StrSubstNo('unknown field "%1" on table %2 — did you mean "%3"?', Name, TableId, Suggestion), Suggest);
                end else
                    Fail := Problem.NewFailure(400, 'unknown-field', 'Unknown field',
                        StrSubstNo('unknown field "%1" on table %2', Name, TableId));
                exit(false);
            end;
            // Inference-oracle guard: aggregating a restricted field discloses it as surely as
            // selecting it, so the same 403 the select path returns closes the channel.
            if not FieldPolicy.IsReadable(TableId, FieldNo) then begin
                Fail := Problem.NewFailure(403, 'field-restricted', 'Field access restricted',
                    StrSubstNo('field "%1" is not readable under the current field policy', Name));
                exit(false);
            end;
            // Masked is readable but min/max/sum/avg/groupBy would compute over the hidden values.
            if FieldPolicy.IsMasked(TableId, FieldNo) then begin
                Fail := Problem.NewFailure(403, 'field-masked', 'Field is masked',
                    StrSubstNo('field "%1" is masked and cannot be aggregated or grouped on', Name));
                exit(false);
            end;
            FieldRec.Get(TableId, FieldNo);
            if not CheckAggregateType(FieldRec, KeyName, Summable, Fail) then exit(false);
            if not FieldNos.Contains(FieldNo) then
                FieldNos.Add(FieldNo);
        end;
        exit(true);
    end;

    local procedure CheckAggregateType(FieldRec: Record Field; KeyName: Text; Summable: Boolean; var Fail: JsonObject): Boolean
    begin
        // CalcSum (and any set-level computation) runs on stored columns; a FlowField is
        // computed per row, so the platform cannot aggregate it server-side.
        if FieldRec.Class = FieldRec.Class::FlowField then begin
            Fail := Problem.NewFailure(400, 'invalid-aggregate', 'Invalid aggregate request',
                StrSubstNo('"%1" over FlowField "%2" is unsupported in v1 — FlowFields are computed per row and cannot be aggregated server-side', KeyName, FieldRec.FieldName));
            exit(false);
        end;
        if FieldRec.Class <> FieldRec.Class::Normal then begin
            Fail := Problem.NewFailure(400, 'invalid-aggregate', 'Invalid aggregate request',
                StrSubstNo('"%1" cannot aggregate "%2": the field holds a filter, not a value', KeyName, FieldRec.FieldName));
            exit(false);
        end;
        if Summable then begin
            if not (FieldRec.Type in [FieldRec.Type::Decimal, FieldRec.Type::Integer, FieldRec.Type::BigInteger, FieldRec.Type::Duration]) then begin
                Fail := Problem.NewFailure(400, 'invalid-aggregate', 'Invalid aggregate request',
                    StrSubstNo('"%1" requires a numeric field (Decimal, Integer, BigInteger or Duration); "%2" is not summable', KeyName, FieldRec.FieldName));
                exit(false);
            end;
        end else
            if FieldRec.Type in [FieldRec.Type::BLOB, FieldRec.Type::Media, FieldRec.Type::MediaSet] then begin
                Fail := Problem.NewFailure(400, 'invalid-aggregate', 'Invalid aggregate request',
                    StrSubstNo('"%1" cannot aggregate binary field "%2"', KeyName, FieldRec.FieldName));
                exit(false);
            end;
        exit(true);
    end;

    local procedure ComputeSums(var RecRef: RecordRef; FieldNos: List of [Integer]; var Target: JsonObject; var Fail: JsonObject): Boolean
    var
        FieldRec: Record Field;
        FieldRef: FieldRef;
        FieldNo: Integer;
    begin
        foreach FieldNo in FieldNos do begin
            FieldRec.Get(RecRef.Number, FieldNo);
            FieldRef := RecRef.Field(FieldNo);
            if not TryCalcSum(FieldRef) then begin
                Fail := ComputeFailure('sum', FieldRec);
                exit(false);
            end;
            AddDecimal(Target, FieldRec.FieldName, ReadNumeric(FieldRef));
        end;
        exit(true);
    end;

    local procedure ComputeAvgs(var RecRef: RecordRef; FieldNos: List of [Integer]; RowCount: Integer; var Target: JsonObject; var Fail: JsonObject): Boolean
    var
        FieldRec: Record Field;
        FieldRef: FieldRef;
        FieldNo: Integer;
    begin
        foreach FieldNo in FieldNos do begin
            FieldRec.Get(RecRef.Number, FieldNo);
            // An average of nothing is undefined, not zero — emit null per field.
            if RowCount = 0 then begin
                AddNull(Target, FieldRec.FieldName);
                continue;
            end;
            FieldRef := RecRef.Field(FieldNo);
            if not TryCalcSum(FieldRef) then begin
                Fail := ComputeFailure('avg', FieldRec);
                exit(false);
            end;
            AddDecimal(Target, FieldRec.FieldName, ReadNumeric(FieldRef) / RowCount);
        end;
        exit(true);
    end;

    // min = first row / max = last row under an ascending sort on the field. SetView REPLACES
    // the whole view including filters, so the WHERE clause captured from GetView travels
    // verbatim into every per-field sorting view — the applied filter set is preserved
    // byte-for-byte whichever way the platform treats a WHERE-less view. The original view is
    // restored after each field so later computations see the untouched state.
    // Both clauses use the field-NUMBER form: GetView(false) emits WHERE(Field5=FILTER(..)) and
    // SORTING(Field<no>) is spliced in beside it. GetView(true) would emit field CAPTIONS in the
    // session language, which SetView cannot reliably map back outside English sessions. The
    // keyword search is case-insensitive: a WHERE clause silently lost here would compute min/max
    // over the whole table instead of the filtered set.
    local procedure ComputeExtremes(var RecRef: RecordRef; FieldNos: List of [Integer]; UseMin: Boolean; var Target: JsonObject; var Fail: JsonObject): Boolean
    var
        FieldRec: Record Field;
        FieldNo, Pos: Integer;
        SavedView, WherePart: Text;
        Found: Boolean;
    begin
        SavedView := RecRef.GetView(false);
        Pos := StrPos(UpperCase(SavedView), ' WHERE(');
        if Pos > 0 then
            WherePart := CopyStr(SavedView, Pos);
        foreach FieldNo in FieldNos do begin
            FieldRec.Get(RecRef.Number, FieldNo);
            if not TrySetView(RecRef, 'SORTING(Field' + Format(FieldNo, 0, 9) + ') ORDER(Ascending)' + WherePart) then begin
                RecRef.SetView(SavedView);
                Fail := Problem.NewFailure(400, 'invalid-aggregate', 'Invalid aggregate request',
                    StrSubstNo('cannot sort table %1 by field "%2"', RecRef.Number, FieldRec.FieldName));
                exit(false);
            end;
            if UseMin then
                Found := RecRef.FindFirst()
            else
                Found := RecRef.FindLast();
            if Found then
                TypeMapper.AddFieldValue(Target, FieldRec.FieldName, RecRef.Field(FieldNo), Setup."Decimal String Threshold")
            else
                AddNull(Target, FieldRec.FieldName);
            RecRef.SetView(SavedView);
        end;
        exit(true);
    end;

    // The request was already validated (field exists, readable, summable), so a CalcSum that still
    // fails is not the caller's mistake: in practice it is the server-side total overflowing the
    // field's own type — CalcSum returns the sum typed like the field, so an Integer column whose
    // total passes 2,147,483,647 cannot be represented. 422 (well-formed, not computable), not 400.
    local procedure ComputeFailure(KeyName: Text; FieldRec: Record Field) Fail: JsonObject
    var
        Suggest: JsonObject;
    begin
        Suggest.Add('tighten', 'narrow the filter so the total fits the field type, or aggregate in slices and add the partial results');
        if FieldRec.Type = FieldRec.Type::Integer then
            Fail := Problem.NewFailureSuggest(422, 'aggregate-overflow', 'Aggregate not computable',
                StrSubstNo('%1 over Integer field "%2" could not be computed: the total exceeds the Integer range (%3)', KeyName, FieldRec.FieldName, GetLastErrorText()), Suggest)
        else
            Fail := Problem.NewFailureSuggest(422, 'aggregate-overflow', 'Aggregate not computable',
                StrSubstNo('%1 over field "%2" could not be computed server-side: %3', KeyName, FieldRec.FieldName, GetLastErrorText()), Suggest);
    end;

    [TryFunction]
    local procedure TryCalcSum(var FieldRef: FieldRef)
    begin
        FieldRef.CalcSum();
    end;

    [TryFunction]
    local procedure TrySetView(var RecRef: RecordRef; ViewText: Text)
    begin
        RecRef.SetView(ViewText);
    end;

    // After CalcSum the sum sits in FieldRef.Value typed like the field; fold every summable
    // type into Decimal so sums and averages emit through one numeric convention.
    local procedure ReadNumeric(FieldRef: FieldRef): Decimal
    var
        IntVal: Integer;
        BigVal: BigInteger;
        DurVal: Duration;
        DecVal: Decimal;
    begin
        case FieldRef.Type of
            FieldType::Decimal:
                DecVal := FieldRef.Value;
            FieldType::Integer:
                begin
                    IntVal := FieldRef.Value;
                    DecVal := IntVal;
                end;
            FieldType::BigInteger:
                begin
                    BigVal := FieldRef.Value;
                    DecVal := BigVal;
                end;
            FieldType::Duration:
                begin
                    DurVal := FieldRef.Value;
                    BigVal := DurVal;
                    DecVal := BigVal;
                end;
        end;
        exit(DecVal);
    end;

    // Mirrors the Decimal emission in "Bcmag Type Mapper" (its AddFieldValue needs a FieldRef,
    // which a computed sum/avg of a non-Decimal source field does not have): values below the
    // Decimal String Threshold travel as JSON numbers, at/above it as invariant strings. A
    // computed aggregate is a number, not a field value, so field-type conventions like
    // BigInteger-as-string or Duration-null-at-zero deliberately do not apply here — an empty
    // set therefore sums to a plain numeric 0.
    local procedure AddDecimal(var Target: JsonObject; Name: Text; Value: Decimal)
    begin
        if Abs(Value) >= Setup."Decimal String Threshold" then
            Target.Add(Name, Format(Value, 0, 9))
        else
            Target.Add(Name, Value);
    end;

    local procedure AddNull(var Target: JsonObject; Name: Text)
    var
        NullVal: JsonValue;
    begin
        NullVal.SetValueToNull();
        Target.Add(Name, NullVal);
    end;
}
