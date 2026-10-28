codeunit 94104 "Bcmag Field Name Resolver"
{
    var
        FieldPolicy: Codeunit "Bcmag Field Policy";

    procedure ResolveByName(TableId: Integer; Name: Text; var FieldNo: Integer; var Suggestion: Text): Boolean
    var
        FieldRec: Record Field;
        BestDistance: Integer;
        Distance: Integer;
    begin
        Suggestion := '';
        FieldNo := 0;
        FieldRec.SetRange(TableNo, TableId);
        if FieldRec.IsEmpty() then exit(false);

        FieldRec.SetRange(FieldName, Name);
        if FieldRec.FindFirst() then begin
            FieldNo := FieldRec."No.";
            exit(true);
        end;

        // Suggestion scan: only real (non-system) fields, and skip candidates whose length
        // is already further than BestDistance from the input (cheap pre-filter before the
        // O(n·m) Levenshtein). A restricted field is never suggested — echoing its name would
        // disclose exactly what the field policy hides (the IsReadable check is only paid when a
        // candidate would otherwise win, so the common case adds nothing; in AllFields mode it is
        // always true, so suggestions are unchanged).
        FieldRec.SetRange(FieldName);
        FieldRec.SetFilter("No.", '<2000000000');
        BestDistance := 3;
        if FieldRec.FindSet() then
            repeat
                if Abs(StrLen(FieldRec.FieldName) - StrLen(Name)) < BestDistance then begin
                    Distance := Levenshtein(LowerCase(Name), LowerCase(FieldRec.FieldName));
                    if (Distance < BestDistance) and FieldPolicy.IsReadable(TableId, FieldRec."No.") then begin
                        BestDistance := Distance;
                        Suggestion := FieldRec.FieldName;
                    end;
                end;
            until FieldRec.Next() = 0;
        exit(false);
    end;

    local procedure Levenshtein(A: Text; B: Text): Integer
    var
        D: array[64, 64] of Integer;
        i, j: Integer;
        Cost: Integer;
        Min: Integer;
        ALen, BLen: Integer;
    begin
        ALen := StrLen(A);
        BLen := StrLen(B);
        if ALen > 60 then ALen := 60;
        if BLen > 60 then BLen := 60;

        for i := 0 to ALen do D[i + 1, 1] := i;
        for j := 0 to BLen do D[1, j + 1] := j;

        for i := 1 to ALen do
            for j := 1 to BLen do begin
                if A[i] = B[j] then Cost := 0 else Cost := 1;
                Min := D[i, j + 1] + 1;
                if D[i + 1, j] + 1 < Min then Min := D[i + 1, j] + 1;
                if D[i, j] + Cost < Min then Min := D[i, j] + Cost;
                D[i + 1, j + 1] := Min;
            end;
        exit(D[ALen + 1, BLen + 1]);
    end;
}
