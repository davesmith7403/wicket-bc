codeunit 94113 "Bcmag Op Query"
{
    var
        Setup: Record "Bcmag Setup";
        Exposure: Record "Bcmag Exposure";
        Problem: Codeunit "Bcmag Problem";
        Resolver: Codeunit "Bcmag Field Name Resolver";
        Lexer: Codeunit "Bcmag Filter Lexer";
        Parser: Codeunit "Bcmag Filter Parser";
        Applier: Codeunit "Bcmag Filter Applier";
        Projector: Codeunit "Bcmag Projector";
        Codec: Codeunit "Bcmag Record Id Codec";
        FieldPolicy: Codeunit "Bcmag Field Policy";
        OpAggregate: Codeunit "Bcmag Op Aggregate";
        JsonRead: Codeunit "Bcmag Json Read";
        ValidateOnly: Boolean;

    // Runs every request-shaping step of Run — exposure, select, orderBy, filter (with its field-policy
    // checks) and the modified window — and stops right before the first row is read. The idempotency
    // replay authorizer uses it: a stored query result must be refused when the fields it was FILTERED
    // or ORDERED by have since been restricted, because row membership and order are the inference
    // oracle those checks exist to close, and the stored body alone cannot show which fields shaped it.
    procedure ValidateShape(Data: JsonObject; var Fail: JsonObject): Boolean
    var
        Response: JsonObject;
        Cost: Integer;
        Ok: Boolean;
    begin
        ValidateOnly := true;
        Ok := Run(Data, Response, Fail, Cost);
        ValidateOnly := false;
        exit(Ok);
    end;

    procedure Run(Data: JsonObject; var Response: JsonObject; var Fail: JsonObject; var Cost: Integer): Boolean
    var
        Tok: JsonToken;
        TableId: Integer;
        SelectedFieldNos: List of [Integer];
        IncludeFlowFields, WantCount, Descending, HasMore, Keyset: Boolean;
        FilterText, ErrorMsg, CursorText, KeysetPosition, LastPosition: Text;
        Top, Skip, Returned, Examined: Integer;
        OrderByFieldNos: List of [Integer];
        FilterTokens: JsonArray;
        Ast: JsonObject;
        RecRef: RecordRef;
        ValueArr: JsonArray;
        Row: JsonObject;
        Suggest: JsonObject;
        AggObj, IncludeObj: JsonObject;
        SelectArr, OrderByArr: JsonArray;
        Found: Boolean;
    begin
        Setup.GetSingleton();
        if not GetTableId(Data, TableId, Fail) then exit(false);

        if not Exposure.IsAllowed(Exposure."Object Type"::Table, TableId, 'read') then begin
            Fail := Problem.NewFailure(403, 'not-exposed', 'Table not exposed',
                StrSubstNo('table %1 is not exposed for read; enroll it in Wicket Exposure or switch Mode to Open', TableId));
            exit(false);
        end;

        // Aggregate mode: the usual tableId/exposure/filter steps ran (or run below inside
        // RunAggregate for the filter), but the result is one summary object computed
        // server-side instead of a row page.
        if Data.Get('aggregate', Tok) then begin
            if not JsonRead.ReadObject(Tok, 'aggregate', AggObj, Fail) then exit(false);
            exit(RunAggregate(Data, AggObj, TableId, Response, Fail, Cost));
        end;

        if Data.Get('select', Tok) and Data.Get('selectFieldNo', Tok) then begin
            Clear(Suggest);
            Suggest.Add('use', 'select');
            Fail := Problem.NewFailureSuggest(400, 'select-and-selectFieldNo', 'Ambiguous selection',
                'pass either "select" or "selectFieldNo", not both', Suggest);
            exit(false);
        end;

        // Every caller-shaped member is type-checked before it is unwrapped: a string where an array
        // goes (select: "Name"), or an object where a boolean goes, is a typed 400 naming the member —
        // never an AsArray()/AsObject() raise that the Run boundary would report as a 500.
        if Data.Get('select', Tok) then begin
            if not JsonRead.ReadArray(Tok, 'select', SelectArr, Fail) then exit(false);
            if not CapArray(SelectArr, 'select', Fail) then exit(false);
            if ContainsStar(SelectArr) then begin
                if not ExpandStarSelect(TableId, SelectArr, SelectedFieldNos, Fail) then exit(false);
            end else begin
                if not ResolveSelectByName(TableId, SelectArr, SelectedFieldNos, Fail) then exit(false);
                if not CheckSelectReadable(TableId, SelectedFieldNos, Fail) then exit(false);
            end;
        end else
            if Data.Get('selectFieldNo', Tok) then begin
                if not JsonRead.ReadArray(Tok, 'selectFieldNo', SelectArr, Fail) then exit(false);
                if not CapArray(SelectArr, 'selectFieldNo', Fail) then exit(false);
                if not ResolveSelectByNo(SelectArr, SelectedFieldNos, Fail) then exit(false);
                if not CheckSelectReadable(TableId, SelectedFieldNos, Fail) then exit(false);
            end;

        if SelectedFieldNos.Count() = 0 then
            UsePrimaryKeyFields(TableId, SelectedFieldNos);

        if Data.Get('include', Tok) then begin
            if not JsonRead.ReadObject(Tok, 'include', IncludeObj, Fail) then exit(false);
            if IncludeObj.Get('flowFields', Tok) then
                if not JsonRead.ReadBoolean(Tok, 'include.flowFields', IncludeFlowFields, Fail) then exit(false);
        end;

        if Data.Get('filter', Tok) then
            if not JsonRead.ReadText(Tok, 'filter', FilterText, Fail) then exit(false);
        if StrLen(FilterText) > Setup."Max Filter Length" then begin
            Fail := Problem.NewFailure(413, 'payload-too-large', 'Filter too large',
                StrSubstNo('filter exceeds the %1-character limit', Setup."Max Filter Length"));
            exit(false);
        end;

        if Data.Get('count', Tok) then
            if not JsonRead.ReadBoolean(Tok, 'count', WantCount, Fail) then exit(false);

        Top := Setup."Default Top";
        if Data.Get('top', Tok) then
            if not JsonRead.ReadInteger(Tok, 'top', Top, Fail) then exit(false);
        if Top > Setup."Max Top" then Top := Setup."Max Top";
        if Top < 1 then Top := 1;

        Skip := 0;
        if Data.Get('skip', Tok) then
            if not JsonRead.ReadInteger(Tok, 'skip', Skip, Fail) then exit(false);
        if Data.Get('cursor', Tok) then begin
            if not JsonRead.ReadText(Tok, 'cursor', CursorText, Fail) then exit(false);
            if not DecodeCursor(CursorText, TableId, Skip, KeysetPosition, Fail) then exit(false);
        end;
        if Skip < 0 then Skip := 0;
        // A keyset cursor replaces any offset: the position already says where the next page starts.
        if KeysetPosition <> '' then Skip := 0;

        RecRef.Open(TableId);
        RecRef.ReadIsolation := IsolationLevel::ReadUncommitted;
        RecRef.SecurityFiltering := SecurityFilter::Filtered;

        if Data.Get('orderBy', Tok) then begin
            if not JsonRead.ReadArray(Tok, 'orderBy', OrderByArr, Fail) then begin
                RecRef.Close();
                exit(false);
            end;
            if not ApplyOrderBy(RecRef, TableId, OrderByArr, OrderByFieldNos, Descending, Fail) then begin
                RecRef.Close();
                exit(false);
            end;
        end;

        if FilterText <> '' then begin
            if not Lexer.Tokenize(FilterText, FilterTokens, ErrorMsg) then begin
                RecRef.Close();
                Fail := Problem.NewFailure(400, 'invalid-filter', 'Invalid $filter expression', ErrorMsg);
                exit(false);
            end;
            if not Parser.Parse(FilterTokens, Ast, ErrorMsg) then begin
                RecRef.Close();
                Fail := Problem.NewFailure(400, 'invalid-filter', 'Invalid $filter expression', ErrorMsg);
                exit(false);
            end;
            if not Applier.Apply(RecRef, Ast, ErrorMsg) then begin
                RecRef.Close();
                Fail := BuildFilterFailure(ErrorMsg);
                exit(false);
            end;
        end;

        if not ApplyModifiedWindow(Data, RecRef, TableId, Fail) then begin
            RecRef.Close();
            exit(false);
        end;
        if ValidateOnly then begin
            RecRef.Close();
            exit(true);
        end;

        // Paging mode. Without orderBy the table iterates in primary-key order, so the cursor
        // carries the last returned row's PK position and the next page starts strictly after it
        // (Find('>') — a row deleted between pages cannot derail it). No row is re-read, so every
        // page costs only its own rows against the scan budget however deep the traversal goes.
        // With orderBy the sort is on arbitrary (possibly non-unique) fields and there is no PK
        // position to resume from, so paging stays offset: the skipped rows are genuinely scanned
        // and count against the budget. A keyset cursor under orderBy (or an offset cursor for
        // another shape) is refused rather than silently reinterpreted.
        Keyset := OrderByFieldNos.Count() = 0;
        if (KeysetPosition <> '') and not Keyset then begin
            RecRef.Close();
            Fail := InvalidCursor('this cursor was issued for a query without orderBy; repeat the original request shape or restart without a cursor');
            exit(false);
        end;

        // Tell the platform which columns the projection reads (and which FlowFields to compute in
        // the same round trip). Last, after every SetView/filter, right before the first Find.
        Projector.PrepareRead(RecRef, SelectedFieldNos, IncludeFlowFields, Setup."Strong ETag");

        // Sort direction is encoded in the view (ORDER clause); iterate forward so Skip and
        // the offset cursor stay consistent for both ascending and descending orderBy.
        Returned := 0;
        Examined := 0;
        if KeysetPosition <> '' then begin
            if not TrySetPosition(RecRef, KeysetPosition) then begin
                RecRef.Close();
                Fail := InvalidCursor('the cursor does not address a position on this table');
                exit(false);
            end;
            Found := RecRef.Find('>');
        end else
            Found := RecRef.FindSet(false);
        // The budget guards rows examined for THIS page. The look-ahead row that only proves
        // "there is more" is not counted, so a page that exactly exhausts a budget-sized set
        // succeeds instead of failing on the probe.
        while Found do begin
            if Returned >= Top then begin
                HasMore := true;
                break;
            end;
            if Examined >= Setup."Per-Call Scan Budget" then begin
                RecRef.Close();
                Fail := BuildScanBudgetFailure(TableId, Keyset);
                exit(false);
            end;
            Examined += 1;
            if Examined > Skip then begin
                Row := Projector.ProjectPreparedRow(RecRef, SelectedFieldNos, IncludeFlowFields, Setup."Decimal String Threshold", Setup."Strong ETag");
                ValueArr.Add(Row);
                Returned += 1;
                LastPosition := RecRef.GetPosition(false);
            end;
            Found := RecRef.Next() <> 0;
        end;

        Cost := Examined;
        Clear(Response);
        Response.Add('value', ValueArr);
        if HasMore then
            if Keyset then
                Response.Add('@nextLink', EncodeKeysetCursor(TableId, LastPosition))
            else
                Response.Add('@nextLink', EncodeCursor(Skip + Top));
        if WantCount then
            Response.Add('@count', RecRef.Count());
        if Keyset then
            Response.Add('@pagingMode', 'keyset')
        else
            Response.Add('@pagingMode', 'offset');
        RecRef.Close();
        exit(true);
    end;

    // Aggregate path: reject the row-plane keys, then run the SAME filter pipeline Run uses
    // (length cap, lex/parse/apply, field-policy 403 marker mapping) before delegating the
    // computations to "Bcmag Op Aggregate". The block is kept textually parallel to Run so the
    // two paths cannot drift in how a filter is applied.
    local procedure RunAggregate(Data: JsonObject; Agg: JsonObject; TableId: Integer; var Response: JsonObject; var Fail: JsonObject; var Cost: Integer): Boolean
    var
        Tok: JsonToken;
        RecRef: RecordRef;
        FilterTokens: JsonArray;
        Ast: JsonObject;
        FilterText, ErrorMsg, ConflictKey: Text;
        Ok: Boolean;
    begin
        // Mutually exclusive with everything that shapes a row page: an aggregate returns one
        // summary object, so paging/projection/ordering keys can only signal caller confusion.
        foreach ConflictKey in RowPlaneKeys() do
            if Data.Contains(ConflictKey) then begin
                Fail := Problem.NewFailure(400, 'invalid-aggregate', 'Invalid aggregate request',
                    StrSubstNo('"aggregate" cannot be combined with "%1" — an aggregate returns one summary object, not rows', ConflictKey));
                exit(false);
            end;

        if Data.Get('filter', Tok) then
            if not JsonRead.ReadText(Tok, 'filter', FilterText, Fail) then exit(false);
        if StrLen(FilterText) > Setup."Max Filter Length" then begin
            Fail := Problem.NewFailure(413, 'payload-too-large', 'Filter too large',
                StrSubstNo('filter exceeds the %1-character limit', Setup."Max Filter Length"));
            exit(false);
        end;

        RecRef.Open(TableId);
        RecRef.ReadIsolation := IsolationLevel::ReadUncommitted;
        RecRef.SecurityFiltering := SecurityFilter::Filtered;

        if FilterText <> '' then begin
            if not Lexer.Tokenize(FilterText, FilterTokens, ErrorMsg) then begin
                RecRef.Close();
                Fail := Problem.NewFailure(400, 'invalid-filter', 'Invalid $filter expression', ErrorMsg);
                exit(false);
            end;
            if not Parser.Parse(FilterTokens, Ast, ErrorMsg) then begin
                RecRef.Close();
                Fail := Problem.NewFailure(400, 'invalid-filter', 'Invalid $filter expression', ErrorMsg);
                exit(false);
            end;
            if not Applier.Apply(RecRef, Ast, ErrorMsg) then begin
                RecRef.Close();
                Fail := BuildFilterFailure(ErrorMsg);
                exit(false);
            end;
        end;

        // The modified window constrains aggregates exactly like the row plane: it is applied to
        // the same RecRef the aggregate computes over, after (and composed with) the filter.
        if not ApplyModifiedWindow(Data, RecRef, TableId, Fail) then begin
            RecRef.Close();
            exit(false);
        end;
        if ValidateOnly then begin
            RecRef.Close();
            exit(true);
        end;

        Ok := OpAggregate.Run(TableId, Agg, RecRef, Response, Fail, Cost);
        RecRef.Close();
        exit(Ok);
    end;

    // Optional data.modifiedAfter / data.modifiedBefore (ISO 8601 datetime strings) constrain
    // SystemModifiedAt (field 2000000003): SystemModifiedAt >= modifiedAfter AND <= modifiedBefore,
    // ANDed with the caller's filter. Runs AFTER the filter applier so a filter that already
    // constrains SystemModifiedAt is detectable via GetFilter — FieldRef.SetRange/SetFilter on the
    // same field would REPLACE that filter (silently widening the result), so the overlap is a
    // hard 400 instead. Both routes into the field (name and #2000000003) are caught this way.
    // Policy consistency: filtering by SystemModifiedAt through the grammar requires the field to
    // be policy-readable (the applier's resolution-time check); these members are the same
    // inference oracle, so they honor the identical 403.
    local procedure ApplyModifiedWindow(Data: JsonObject; var RecRef: RecordRef; TableId: Integer; var Fail: JsonObject): Boolean
    var
        FieldRefVal: FieldRef;
        ModifiedAfter, ModifiedBefore: DateTime;
        HasAfter, HasBefore: Boolean;
    begin
        if not GetWindowMember(Data, 'modifiedAfter', ModifiedAfter, HasAfter, Fail) then exit(false);
        if not GetWindowMember(Data, 'modifiedBefore', ModifiedBefore, HasBefore, Fail) then exit(false);
        if not (HasAfter or HasBefore) then exit(true);

        if not RecRef.FieldExist(SystemModifiedAtFieldNo()) then begin
            Fail := Problem.NewFailure(400, 'invalid-field', 'No SystemModifiedAt on table',
                StrSubstNo('table %1 has no SystemModifiedAt system field, so modifiedAfter/modifiedBefore cannot be applied', TableId));
            exit(false);
        end;
        if not FieldPolicy.IsReadable(TableId, SystemModifiedAtFieldNo()) then begin
            Fail := Problem.NewFailure(403, 'field-restricted', 'Field access restricted',
                StrSubstNo('field %1 is not readable under the current field policy', SystemModifiedAtFieldNo()));
            exit(false);
        end;

        // SystemModifiedAt masked: a window is a filter on it.
        if FieldPolicy.IsMasked(TableId, SystemModifiedAtFieldNo()) then begin
            Fail := Problem.NewFailure(403, 'field-masked', 'Field is masked',
                StrSubstNo('field %1 (SystemModifiedAt) is masked and cannot be used in modifiedAfter/modifiedBefore', SystemModifiedAtFieldNo()));
            exit(false);
        end;

        FieldRefVal := RecRef.Field(SystemModifiedAtFieldNo());
        if FieldRefVal.GetFilter() <> '' then begin
            Fail := Problem.NewFailure(400, 'invalid-field', 'Conflicting SystemModifiedAt constraints',
                StrSubstNo('the filter already constrains SystemModifiedAt (field %1); combining it with modifiedAfter/modifiedBefore would replace that filter and silently widen the result — express the whole range in one place', SystemModifiedAtFieldNo()));
            exit(false);
        end;

        // An inverted window would reach SetRange and silently return zero rows — which an
        // incremental-sync caller reads as "nothing changed" and then advances its watermark past
        // the records it never saw. Silent data loss in a sync loop is worse than a rejected call.
        if HasAfter and HasBefore and (ModifiedAfter > ModifiedBefore) then begin
            Fail := Problem.NewFailure(400, 'invalid-field', 'Inverted modified window',
                'data.modifiedAfter is later than data.modifiedBefore, so the window selects nothing — swap them');
            exit(false);
        end;

        if HasAfter and HasBefore then
            FieldRefVal.SetRange(ModifiedAfter, ModifiedBefore)
        else
            if HasAfter then
                FieldRefVal.SetFilter('>=%1', ModifiedAfter)
            else
                FieldRefVal.SetFilter('<=%1', ModifiedBefore);
        exit(true);
    end;

    // Defensive member read: absent or empty string -> ignored; wrong JSON type or an
    // unparseable datetime -> typed 400 naming the member (same TryFunction-coercion posture
    // as the action target's systemId). Evaluate(..., 9) parses the ISO 8601 round-trip form.
    local procedure GetWindowMember(Data: JsonObject; MemberName: Text; var Value: DateTime; var Present: Boolean; var Fail: JsonObject): Boolean
    var
        Tok: JsonToken;
        Raw: Text;
    begin
        Present := false;
        if not Data.Get(MemberName, Tok) then exit(true);
        if not Tok.IsValue() then begin
            Fail := InvalidWindowMember(MemberName);
            exit(false);
        end;
        if Tok.AsValue().IsNull() then exit(true);
        if not TryTokenText(Tok, Raw) then begin
            Fail := InvalidWindowMember(MemberName);
            exit(false);
        end;
        if Raw = '' then exit(true);
        if not Evaluate(Value, Raw, 9) then begin
            Fail := InvalidWindowMember(MemberName);
            exit(false);
        end;
        Present := true;
        exit(true);
    end;

    local procedure InvalidWindowMember(MemberName: Text) Fail: JsonObject
    begin
        Fail := Problem.NewFailure(400, 'invalid-field', StrSubstNo('Invalid %1', MemberName),
            StrSubstNo('data.%1 must be an ISO 8601 datetime string, e.g. "2026-01-31T12:00:00Z"', MemberName));
    end;

    [TryFunction]
    local procedure TryTokenText(Tok: JsonToken; var Raw: Text)
    begin
        Raw := Tok.AsValue().AsText();
    end;

    local procedure SystemModifiedAtFieldNo(): Integer
    begin
        exit(2000000003);
    end;

    local procedure RowPlaneKeys() KeyList: List of [Text]
    begin
        KeyList.Add('select');
        KeyList.Add('selectFieldNo');
        KeyList.Add('orderBy');
        KeyList.Add('top');
        KeyList.Add('skip');
        KeyList.Add('cursor');
        KeyList.Add('count');
    end;

    local procedure GetTableId(Data: JsonObject; var TableId: Integer; var Fail: JsonObject): Boolean
    var
        Tok: JsonToken;
    begin
        if not Data.Get('tableId', Tok) then begin
            Fail := Problem.NewFailure(400, 'missing-field', 'Missing tableId', 'data.tableId is required');
            exit(false);
        end;
        if not JsonRead.ReadInteger(Tok, 'tableId', TableId, Fail) then exit(false);
        exit(true);
    end;

    local procedure CapArray(Arr: JsonArray; FieldName: Text; var Fail: JsonObject): Boolean
    var
        Setup2: Record "Bcmag Setup";
    begin
        Setup2.GetSingleton();
        if Arr.Count() > Setup2."Max Select Fields" then begin
            Fail := Problem.NewFailure(413, 'payload-too-large', 'Too many fields',
                StrSubstNo('"%1" has %2 entries; the limit is %3', FieldName, Arr.Count(), Setup2."Max Select Fields"));
            exit(false);
        end;
        exit(true);
    end;

    local procedure ResolveSelectByName(TableId: Integer; Names: JsonArray; var FieldNos: List of [Integer]; var Fail: JsonObject): Boolean
    var
        Tok: JsonToken;
        Name, Suggestion: Text;
        FieldNo, i: Integer;
        Suggest: JsonObject;
    begin
        for i := 0 to Names.Count() - 1 do begin
            Names.Get(i, Tok);
            if not JsonRead.ReadText(Tok, 'select[]', Name, Fail) then exit(false);
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
            FieldNos.Add(FieldNo);
        end;
        exit(true);
    end;

    // Field policy runs at RESOLUTION time — once per requested field, never inside the row
    // loop. An explicitly requested restricted field is a hard 403 (silently dropping it would
    // misrepresent the projection). The detail names the field by NUMBER, never by name: this
    // path also serves selectFieldNo, and resolving the name would disclose a restricted field's
    // name to a caller who only supplied a number. An unresolvable number reads as restricted
    // (fail-closed), keeping nonexistent and denied field numbers indistinguishable.
    local procedure CheckSelectReadable(TableId: Integer; FieldNos: List of [Integer]; var Fail: JsonObject): Boolean
    var
        FieldNo: Integer;
    begin
        foreach FieldNo in FieldNos do
            if not FieldPolicy.IsReadable(TableId, FieldNo) then begin
                Fail := Problem.NewFailure(403, 'field-restricted', 'Field access restricted',
                    StrSubstNo('field %1 is not readable under the current field policy', FieldNo));
                exit(false);
            end;
        exit(true);
    end;

    local procedure ContainsStar(Names: JsonArray): Boolean
    var
        Tok: JsonToken;
        Ignored: JsonObject;
        Name: Text;
        i: Integer;
    begin
        // A non-string entry is simply "not a star" here; ResolveSelectByName then answers the
        // typed 400 for it.
        for i := 0 to Names.Count() - 1 do begin
            Names.Get(i, Tok);
            if JsonRead.ReadText(Tok, 'select[]', Name, Ignored) then
                if Name = '*' then
                    exit(true);
        end;
        exit(false);
    end;

    // select ["*"] expands to every scalar field: Normal + FlowField, not removed, binaries
    // (BLOB/Media/MediaSet) excluded. Field iteration order gives field number ascending.
    // FlowFields stay in the list; the Projector skips them unless include.flowFields is true.
    local procedure ExpandStarSelect(TableId: Integer; Names: JsonArray; var FieldNos: List of [Integer]; var Fail: JsonObject): Boolean
    var
        FieldRec: Record Field;
        Suggest: JsonObject;
    begin
        if Names.Count() > 1 then begin
            Suggest.Add('use', 'pass "*" as the only select entry, or list fields explicitly');
            Fail := Problem.NewFailureSuggest(400, 'invalid-select', 'Invalid select',
                '"*" cannot be combined with other select entries', Suggest);
            exit(false);
        end;
        FieldRec.SetRange(TableNo, TableId);
        FieldRec.SetFilter(Class, '%1|%2', FieldRec.Class::Normal, FieldRec.Class::FlowField);
        FieldRec.SetFilter(ObsoleteState, '<>%1', FieldRec.ObsoleteState::Removed);
        FieldRec.SetFilter(Type, '<>%1&<>%2&<>%3', FieldRec.Type::BLOB, FieldRec.Type::Media, FieldRec.Type::MediaSet);
        if FieldRec.FindSet() then
            repeat
                // Restricted fields are silently excluded — "*" means "everything I may read",
                // so the expansion narrows with the field policy instead of erroring.
                if FieldPolicy.IsReadable(TableId, FieldRec."No.") then
                    FieldNos.Add(FieldRec."No.");
            until FieldRec.Next() = 0;
        if FieldNos.Count() > Setup."Max Select Fields" then begin
            Fail := Problem.NewFailure(413, 'payload-too-large', 'Too many fields',
                StrSubstNo('"*" expands to %1 fields on table %2; the limit is %3 — select explicit fields instead', FieldNos.Count(), TableId, Setup."Max Select Fields"));
            exit(false);
        end;
        exit(true);
    end;

    local procedure ResolveSelectByNo(Nos: JsonArray; var FieldNos: List of [Integer]; var Fail: JsonObject): Boolean
    var
        Tok: JsonToken;
        i, FieldNo : Integer;
    begin
        for i := 0 to Nos.Count() - 1 do begin
            Nos.Get(i, Tok);
            if not JsonRead.ReadInteger(Tok, 'selectFieldNo[]', FieldNo, Fail) then exit(false);
            FieldNos.Add(FieldNo);
        end;
        exit(true);
    end;

    local procedure UsePrimaryKeyFields(TableId: Integer; var FieldNos: List of [Integer])
    var
        KeyRec: Record "Key";
        FieldRec: Record Field;
        Parts: List of [Text];
        Part: Text;
    begin
        KeyRec.SetRange(TableNo, TableId);
        KeyRec.SetRange("No.", 1);
        if not KeyRec.FindFirst() then exit;
        Parts := KeyRec."Key".Split(',');
        foreach Part in Parts do begin
            FieldRec.SetRange(TableNo, TableId);
            FieldRec.SetRange(FieldName, DelChr(Part, '<>', ' '));
            if FieldRec.FindFirst() then
                FieldNos.Add(FieldRec."No.");
        end;
    end;

    // Ascending or all-descending sort by indexed fields. SetView SORTING requires the
    // field set to match an existing key (guarded). Mixed asc/desc is rejected.
    // SORTING uses the field-NUMBER form (Field<no>): a name inside a view string is resolved by
    // the platform against the session's metadata, and the number form is the one GetView(false)
    // itself emits, so it means the same thing in every UI language.
    local procedure ApplyOrderBy(var RecRef: RecordRef; TableId: Integer; OrderBy: JsonArray; var FieldNos: List of [Integer]; var Descending: Boolean; var Fail: JsonObject): Boolean
    var
        Tok: JsonToken;
        Entry, FieldName, Suggestion, Names, SortingList, MaskedKeyField: Text;
        i, FieldNo: Integer;
        IsDesc, First: Boolean;
    begin
        First := true;
        for i := 0 to OrderBy.Count() - 1 do begin
            OrderBy.Get(i, Tok);
            if not JsonRead.ReadText(Tok, 'orderBy[]', Entry, Fail) then exit(false);
            ParseOrderEntry(Entry, FieldName, IsDesc);
            if First then begin
                Descending := IsDesc;
                First := false;
            end else
                if IsDesc <> Descending then begin
                    Fail := Problem.NewFailure(400, 'invalid-orderby', 'Mixed sort direction',
                        'v1 requires every orderBy term to share one direction (all asc or all desc)');
                    exit(false);
                end;
            if not Resolver.ResolveByName(TableId, FieldName, FieldNo, Suggestion) then begin
                Fail := Problem.NewFailure(400, 'unknown-field', 'Unknown orderBy field',
                    StrSubstNo('unknown orderBy field "%1" on table %2', FieldName, TableId));
                exit(false);
            end;
            // Ordering by a restricted field would leak its relative values through row order —
            // the same 403 the select path returns closes that inference oracle.
            if not FieldPolicy.IsReadable(TableId, FieldNo) then begin
                Fail := Problem.NewFailure(403, 'field-restricted', 'Field access restricted',
                    StrSubstNo('field "%1" is not readable under the current field policy', FieldName));
                exit(false);
            end;
            // A masked field is readable, but sorting by it ranks the values the mask hides.
            if FieldPolicy.IsMasked(TableId, FieldNo) then begin
                Fail := Problem.NewFailure(403, 'field-masked', 'Field is masked',
                    StrSubstNo('field "%1" is masked and cannot be used in orderBy', FieldName));
                exit(false);
            end;
            FieldNos.Add(FieldNo);
            if Names = '' then Names := '"' + FieldName + '"' else Names += ',"' + FieldName + '"';
            if SortingList = '' then SortingList := 'Field' + Format(FieldNo, 0, 9) else SortingList += ',Field' + Format(FieldNo, 0, 9);
        end;
        if not TrySetSorting(RecRef, SortingList, Descending) then begin
            Fail := Problem.NewFailure(400, 'invalid-orderby', 'Cannot sort by these fields',
                StrSubstNo('orderBy (%1) does not match an index on table %2; order by indexed fields or omit orderBy', Names, TableId));
            exit(false);
        end;
        // The platform sorts by the WHOLE key it selected, not just the requested prefix: ordering
        // by A under key (A, B) breaks ties by B, so row order would rank a restricted B among equal
        // A values. Refuse that like any other restricted use. The detail names only what the caller
        // supplied — never the restricted segment.
        // Hidden wins over masked (no behavior change for hidden; a masked key segment names the field).
        case EffectiveKeyBlock(RecRef, TableId, MaskedKeyField) of
            1:
                begin
                    Fail := Problem.NewFailure(403, 'field-restricted', 'Field access restricted',
                        StrSubstNo('orderBy (%1) resolves to an index that also orders by a field not readable under the current field policy; order by other fields or omit orderBy', Names));
                    exit(false);
                end;
            2:
                begin
                    Fail := Problem.NewFailure(403, 'field-masked', 'Field is masked',
                        StrSubstNo('orderBy (%1) resolves to an index that also orders by masked field "%2"; order by other fields or omit orderBy', Names, MaskedKeyField));
                    exit(false);
                end;
        end;
        exit(true);
    end;

    // 0 = every key field Clear, 1 = a key field is Hidden (takes precedence), 2 = a key field is
    // Masked (MaskedField names the first one). A masked segment still ranks its hidden values.
    local procedure EffectiveKeyBlock(var RecRef: RecordRef; TableId: Integer; var MaskedField: Text): Integer
    var
        CurrentKeyRef: KeyRef;
        FieldNo, i, Result: Integer;
    begin
        CurrentKeyRef := RecRef.KeyIndex(RecRef.CurrentKeyIndex());
        for i := 1 to CurrentKeyRef.FieldCount() do begin
            FieldNo := CurrentKeyRef.FieldIndex(i).Number();
            if not FieldPolicy.IsReadable(TableId, FieldNo) then
                exit(1);
            if (Result = 0) and FieldPolicy.IsMasked(TableId, FieldNo) then begin
                Result := 2;
                MaskedField := CurrentKeyRef.FieldIndex(i).Name();
            end;
        end;
        exit(Result);
    end;

    local procedure ParseOrderEntry(Entry: Text; var FieldName: Text; var IsDesc: Boolean)
    var
        Lowered: Text;
    begin
        Entry := DelChr(Entry, '<>', ' ');
        Lowered := LowerCase(Entry);
        if Lowered.EndsWith(' desc') then begin
            IsDesc := true;
            FieldName := DelChr(CopyStr(Entry, 1, StrLen(Entry) - 5), '>', ' ');
        end else
            if Lowered.EndsWith(' asc') then begin
                IsDesc := false;
                FieldName := DelChr(CopyStr(Entry, 1, StrLen(Entry) - 4), '>', ' ');
            end else begin
                IsDesc := false;
                FieldName := Entry;
            end;
    end;

    [TryFunction]
    local procedure TrySetSorting(var RecRef: RecordRef; SortingList: Text; Descending: Boolean)
    var
        Order: Text;
    begin
        if Descending then Order := 'Descending' else Order := 'Ascending';
        RecRef.SetView('SORTING(' + SortingList + ') ORDER(' + Order + ')');
    end;

    local procedure BuildFilterFailure(ErrorMsg: Text) Fail: JsonObject
    var
        Suggest: JsonObject;
        FieldName: Text;
    begin
        // A policy denial travels the applier's text ErrorMsg channel like a syntax error, but
        // it must NOT surface as 400 'invalid-filter': the applier prefixes it with the
        // RestrictedMarker and it maps to the same 403 the select path returns — otherwise
        // `Field gt X` would act as a row-membership oracle on fields the caller may not read.
        // The masked marker is checked first and stripped, so marker text never reaches the detail.
        if ErrorMsg.StartsWith(FieldPolicy.MaskedMarker()) then
            exit(Problem.NewFailure(403, 'field-masked', 'Field is masked',
                CopyStr(ErrorMsg, StrLen(FieldPolicy.MaskedMarker()) + 1)));
        if ErrorMsg.StartsWith(FieldPolicy.RestrictedMarker()) then
            exit(Problem.NewFailure(403, 'field-restricted', 'Field access restricted',
                CopyStr(ErrorMsg, StrLen(FieldPolicy.RestrictedMarker()) + 1)));
        FieldName := ExtractSuggestedField(ErrorMsg);
        if FieldName <> '' then begin
            Suggest.Add('field', FieldName);
            Fail := Problem.NewFailureSuggest(400, 'invalid-filter', 'Invalid $filter expression', ErrorMsg, Suggest);
        end else
            Fail := Problem.NewFailure(400, 'invalid-filter', 'Invalid $filter expression', ErrorMsg);
    end;

    local procedure ExtractSuggestedField(ErrorMsg: Text): Text
    var
        Marker, Tail: Text;
        Pos, EndPos: Integer;
    begin
        // Pull the field from: ... did you mean "Name"?
        Marker := 'did you mean "';
        Pos := StrPos(ErrorMsg, Marker);
        if Pos = 0 then exit('');
        Tail := CopyStr(ErrorMsg, Pos + StrLen(Marker));
        EndPos := StrPos(Tail, '"');
        if EndPos = 0 then exit('');
        exit(CopyStr(Tail, 1, EndPos - 1));
    end;

    local procedure BuildScanBudgetFailure(TableId: Integer; Keyset: Boolean) Fail: JsonObject
    var
        Suggest: JsonObject;
    begin
        Suggest.Add('tighten', 'add a filter on an indexed field to reduce the scanned set');
        // Offset paging re-scans every skipped row, so a deep page can exhaust the budget on its
        // own; keyset paging (no orderBy) resumes at the last position and never does.
        if not Keyset then
            Suggest.Add('paging', 'omit orderBy to page by primary key (keyset): each page then scans only its own rows');
        Fail := Problem.NewFailureSuggest(422, 'scan-budget', 'Scan budget exceeded',
            StrSubstNo('the query scanned more than %1 rows on table %2; tighten the filter', Setup."Per-Call Scan Budget", TableId), Suggest);
    end;

    // Cursor formats (base64, single line):
    //   'skip:<n>'                   offset cursor (orderBy queries; also every cursor issued before
    //                                keyset paging existed — still honoured, so an agent mid-traversal
    //                                across an upgrade keeps paging)
    //   'pos:<tableId>:<position>'   keyset cursor: RecRef.GetPosition(false) of the last returned row
    //                                (field-number form, so it survives a language switch). The table
    //                                number binds it to one table.
    // The PK values inside a keyset cursor are the same values the page's @recordId tokens already
    // carry, so the cursor discloses nothing the page did not.
    local procedure EncodeCursor(NextSkip: Integer) Cursor: Text
    var
        Base64: Codeunit "Base64 Convert";
    begin
        exit(Base64.ToBase64('skip:' + Format(NextSkip, 0, 9), false));
    end;

    local procedure EncodeKeysetCursor(TableId: Integer; Position: Text): Text
    var
        Base64: Codeunit "Base64 Convert";
    begin
        exit(Base64.ToBase64('pos:' + Format(TableId, 0, 9) + ':' + Position, false));
    end;

    // A cursor is opaque server output. One that does not decode is a caller defect (truncated,
    // edited, or from another table) — restarting silently at page 1 would make an agent re-read
    // and double-count rows, so it is a 400 instead. An empty string still means "no cursor".
    local procedure DecodeCursor(Cursor: Text; TableId: Integer; var Skip: Integer; var Position: Text; var Fail: JsonObject): Boolean
    var
        Base64: Codeunit "Base64 Convert";
        Decoded, Rest: Text;
        Parsed, Sep: Integer;
    begin
        Position := '';
        if Cursor = '' then exit(true);
        if not TryDecodeCursor(Base64, Cursor, Decoded) then begin
            Fail := InvalidCursor('the cursor is not valid base64; pass the @nextLink value unchanged');
            exit(false);
        end;
        if Decoded.StartsWith('skip:') then begin
            // Format 9 is what EncodeCursor writes now; pre-keyset cursors were minted with
            // StrSubstNo (session-formatted, e.g. '1,000'), so fall back to the session parse.
            if not Evaluate(Parsed, CopyStr(Decoded, 6), 9) then
                if not Evaluate(Parsed, CopyStr(Decoded, 6)) then begin
                    Fail := InvalidCursor('the cursor is malformed; pass the @nextLink value unchanged');
                    exit(false);
                end;
            if Parsed < 0 then begin
                Fail := InvalidCursor('the cursor is malformed; pass the @nextLink value unchanged');
                exit(false);
            end;
            Skip := Parsed;
            exit(true);
        end;
        if Decoded.StartsWith('pos:') then begin
            Rest := CopyStr(Decoded, 5);
            Sep := StrPos(Rest, ':');
            if (Sep > 1) and Evaluate(Parsed, CopyStr(Rest, 1, Sep - 1), 9) then
                if Parsed = TableId then begin
                    Position := CopyStr(Rest, Sep + 1);
                    if Position <> '' then
                        exit(true);
                end else begin
                    Fail := InvalidCursor(StrSubstNo('the cursor was issued for another table, not table %1', TableId));
                    exit(false);
                end;
        end;
        Fail := InvalidCursor('the cursor is malformed; pass the @nextLink value unchanged');
        exit(false);
    end;

    local procedure InvalidCursor(Detail: Text) Fail: JsonObject
    var
        Suggest: JsonObject;
    begin
        Suggest.Add('use', 'pass data.cursor exactly as the previous response''s @nextLink, with the same tableId/filter/orderBy; omit it to start from the first page');
        Fail := Problem.NewFailureSuggest(400, 'invalid-cursor', 'Invalid cursor', Detail, Suggest);
    end;

    [TryFunction]
    local procedure TryDecodeCursor(var Base64: Codeunit "Base64 Convert"; Cursor: Text; var Decoded: Text)
    begin
        Decoded := Base64.FromBase64(Cursor);
    end;

    // SetPosition raises on a position that names fields the table does not have or values that
    // do not fit them; the caller maps that to 400 invalid-cursor.
    [TryFunction]
    local procedure TrySetPosition(var RecRef: RecordRef; Position: Text)
    begin
        RecRef.SetPosition(Position);
    end;
}
