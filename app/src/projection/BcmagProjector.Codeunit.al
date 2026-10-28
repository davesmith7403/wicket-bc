codeunit 94106 "Bcmag Projector"
{
    var
        TypeMapper: Codeunit "Bcmag Type Mapper";
        Codec: Codeunit "Bcmag Record Id Codec";
        HashKey: Codeunit "Bcmag Hash Key";
        FieldPolicy: Codeunit "Bcmag Field Policy";
        Masker: Codeunit "Bcmag Field Masker";
        PolicyCtx: Codeunit "Bcmag Op Runner Context";
        // Field metadata resolved once per table, not once per row: the Field virtual table is a
        // metadata read, and a page of 1000 rows x 20 fields used to issue 20000 of them.
        MetaTableNo: Integer;
        MetaName: Dictionary of [Integer, Text];
        MetaKind: Dictionary of [Integer, Integer];
        MetaHasModifiedAt: Boolean;
        // Strong-ETag hash input (Normal, non-binary fields in number order), also per table.
        HashTableNo: Integer;
        HashFieldNos: List of [Integer];
        // Set by PrepareRead: the selected FlowFields are computed by the Find itself.
        PreparedTableNo: Integer;
        PreparedAutoCalc: Boolean;
        // Read verdicts, resolved once per field per table and policy generation — never per row. A
        // field enters MaskChecked the first time a row projects it (so only fields actually emitted
        // are asked about, and a lift is never logged for a field nobody read); MaskProfileByField
        // holds the Masked ones with their profile. The generation is the Op Runner Context's: it
        // moves on every request and every in-session policy write, and this projector can outlive
        // both (the query handler holds it as a global), so a stale mask or a stale Clear is never served.
        MaskTableNo: Integer;
        MaskGeneration: Integer;
        MaskLoaded: Boolean;
        MaskChecked: Dictionary of [Integer, Boolean];
        MaskProfileByField: Dictionary of [Integer, Code[20]];

    procedure ProjectRow(RecRef: RecordRef; SelectedFieldNos: List of [Integer]; IncludeFlowFields: Boolean; DecimalStringThreshold: BigInteger) Result: JsonObject
    begin
        // Back-compat overload: reads the Strong ETag flag itself (the write plane calls this form).
        exit(ProjectRow(RecRef, SelectedFieldNos, IncludeFlowFields, DecimalStringThreshold, StrongEtagEnabled()));
    end;

    // The query op reads Strong ETag once and passes it per row, so the per-row path never re-reads Setup.
    procedure ProjectRow(RecRef: RecordRef; SelectedFieldNos: List of [Integer]; IncludeFlowFields: Boolean; DecimalStringThreshold: BigInteger; StrongEtag: Boolean) Result: JsonObject
    begin
        exit(Project(RecRef, SelectedFieldNos, IncludeFlowFields, DecimalStringThreshold, StrongEtag, false));
    end;

    // Row projection for a loop that called PrepareRead on the same RecordRef first: FlowFields
    // the Find already computed (SetAutoCalcFields) are not recalculated per row.
    procedure ProjectPreparedRow(RecRef: RecordRef; SelectedFieldNos: List of [Integer]; IncludeFlowFields: Boolean; DecimalStringThreshold: BigInteger; StrongEtag: Boolean) Result: JsonObject
    begin
        exit(Project(RecRef, SelectedFieldNos, IncludeFlowFields, DecimalStringThreshold, StrongEtag,
            PreparedAutoCalc and (PreparedTableNo = RecRef.Number)));
    end;

    // Call once, after every filter/SetView and before the first Find of a projection loop. Narrows
    // the SELECT to the columns ProjectRow will read — the selected Normal fields; the primary key,
    // SystemId and the audit fields (SystemModifiedAt feeds @etag) are always loaded by the platform
    // — and asks the platform to compute the selected FlowFields in the same query. Strong ETag
    // hashes every scalar field, so it keeps the full load. A field outside the load set would still
    // be read correctly (a just-in-time load), only slower; the set is built from the same
    // metadata ProjectRow uses so that does not happen on the hot path.
    procedure PrepareRead(var RecRef: RecordRef; SelectedFieldNos: List of [Integer]; IncludeFlowFields: Boolean; StrongEtag: Boolean)
    var
        FlowFieldNos: List of [Integer];
        FieldNo, Kind: Integer;
        LoadStarted: Boolean;
    begin
        EnsureMeta(RecRef.Number);
        PreparedTableNo := RecRef.Number;
        PreparedAutoCalc := false;
        foreach FieldNo in SelectedFieldNos do
            if MetaKind.Get(FieldNo, Kind) then
                case Kind of
                    KindNormal():
                        if not StrongEtag then
                            if RecRef.FieldExist(FieldNo) then begin
                                if LoadStarted then
                                    RecRef.AddLoadFields(FieldNo)
                                else
                                    RecRef.SetLoadFields(FieldNo);
                                LoadStarted := true;
                            end;
                    KindFlowField():
                        if IncludeFlowFields and not FlowFieldNos.Contains(FieldNo) then
                            FlowFieldNos.Add(FieldNo);
                end;
        // Only the PK was selected (or nothing loadable): load just the always-loaded set.
        if (not LoadStarted) and (not StrongEtag) then
            RecRef.SetLoadFields(RecRef.KeyIndex(1).FieldIndex(1).Number());
        PreparedAutoCalc := SetAutoCalc(RecRef, FlowFieldNos);
    end;

    // RecordRef.SetAutoCalcFields is variadic with no additive form, so the arity is spelled out.
    // Beyond ten FlowFields the projection falls back to one CalcField per field per row — correct,
    // just the old cost.
    local procedure SetAutoCalc(var RecRef: RecordRef; F: List of [Integer]): Boolean
    begin
        case F.Count() of
            0:
                exit(false);
            1:
                RecRef.SetAutoCalcFields(F.Get(1));
            2:
                RecRef.SetAutoCalcFields(F.Get(1), F.Get(2));
            3:
                RecRef.SetAutoCalcFields(F.Get(1), F.Get(2), F.Get(3));
            4:
                RecRef.SetAutoCalcFields(F.Get(1), F.Get(2), F.Get(3), F.Get(4));
            5:
                RecRef.SetAutoCalcFields(F.Get(1), F.Get(2), F.Get(3), F.Get(4), F.Get(5));
            6:
                RecRef.SetAutoCalcFields(F.Get(1), F.Get(2), F.Get(3), F.Get(4), F.Get(5), F.Get(6));
            7:
                RecRef.SetAutoCalcFields(F.Get(1), F.Get(2), F.Get(3), F.Get(4), F.Get(5), F.Get(6), F.Get(7));
            8:
                RecRef.SetAutoCalcFields(F.Get(1), F.Get(2), F.Get(3), F.Get(4), F.Get(5), F.Get(6), F.Get(7), F.Get(8));
            9:
                RecRef.SetAutoCalcFields(F.Get(1), F.Get(2), F.Get(3), F.Get(4), F.Get(5), F.Get(6), F.Get(7), F.Get(8), F.Get(9));
            10:
                RecRef.SetAutoCalcFields(F.Get(1), F.Get(2), F.Get(3), F.Get(4), F.Get(5), F.Get(6), F.Get(7), F.Get(8), F.Get(9), F.Get(10));
            else
                exit(false);
        end;
        exit(true);
    end;

    local procedure Project(RecRef: RecordRef; SelectedFieldNos: List of [Integer]; IncludeFlowFields: Boolean; DecimalStringThreshold: BigInteger; StrongEtag: Boolean; FlowFieldsCalculated: Boolean) Result: JsonObject
    var
        FieldNo, Kind: Integer;
        FieldRef: FieldRef;
        ProfileCode: Code[20];
        MaskedNames: JsonArray;
    begin
        Clear(Result);
        EnsureMeta(RecRef.Number);
        EnsureMaskState(RecRef.Number);
        foreach FieldNo in SelectedFieldNos do
            // Unknown, Blob/Media/MediaSet (fetch via readBlob) and FlowFilter (a filter, not a
            // value) fields are never projected — EnsureMeta files them as KindSkip or omits them.
            if MetaKind.Get(FieldNo, Kind) then
                if (Kind = KindNormal()) or ((Kind = KindFlowField()) and IncludeFlowFields) then
                    if RecRef.FieldExist(FieldNo) then begin
                        FieldRef := RecRef.Field(FieldNo);
                        if (Kind = KindFlowField()) and not FlowFieldsCalculated then
                            FieldRef.CalcField();
                        if IsMaskedField(RecRef.Number, FieldNo, ProfileCode) then begin
                            Masker.AddMaskedValue(Result, MetaName.Get(FieldNo), FieldRef, ProfileCode);
                            MaskedNames.Add(MetaName.Get(FieldNo));
                        end else
                            TypeMapper.AddFieldValue(Result, MetaName.Get(FieldNo), FieldRef, DecimalStringThreshold);
                    end;

        // @masked names (by the same keys as the row's members) every field this row carries as a mask
        // rendering rather than its value. It is per row, not per response, so a row keeps its own
        // account of what it hides wherever it travels — a wrapper response, an async package, or an
        // idempotency replay that re-authorizes the stored body against the policy in force now.
        // Absent when nothing in the row is masked.
        if MaskedNames.Count() > 0 then
            Result.Add('@masked', MaskedNames);

        // @recordId is the opaque token a caller carries into readBlob/modify/delete.
        Result.Add('@recordId', Codec.Encode(RecRef.RecordId));
        // @systemId is the stable per-record GUID — the handle an `action` addresses a record by
        // (target.systemId). Present on every real table (field 2000000000).
        AddSystemId(RecRef, Result);
        AddEtag(RecRef, Result, StrongEtag);
    end;

    // One Field-table pass per table: name + projection kind for every field. Removed fields stay
    // out (RecRef.Field would throw for them), so they read as unknown.
    local procedure EnsureMeta(TableNo: Integer)
    var
        FieldRec: Record Field;
        Kind: Integer;
    begin
        if (MetaTableNo = TableNo) and (TableNo <> 0) then
            exit;
        Clear(MetaName);
        Clear(MetaKind);
        FieldRec.SetRange(TableNo, TableNo);
        FieldRec.SetFilter(ObsoleteState, '<>%1', FieldRec.ObsoleteState::Removed);
        if FieldRec.FindSet() then
            repeat
                if FieldRec.Type in [FieldRec.Type::BLOB, FieldRec.Type::Media, FieldRec.Type::MediaSet] then
                    Kind := KindSkip()
                else
                    case FieldRec.Class of
                        FieldRec.Class::Normal:
                            Kind := KindNormal();
                        FieldRec.Class::FlowField:
                            Kind := KindFlowField();
                        else
                            Kind := KindSkip();
                    end;
                MetaName.Set(FieldRec."No.", FieldRec.FieldName);
                MetaKind.Set(FieldRec."No.", Kind);
            until FieldRec.Next() = 0;
        MetaHasModifiedAt := MetaKind.ContainsKey(2000000003);
        MetaTableNo := TableNo;
    end;

    // Drops the verdict cache when the table or the policy generation changed. The masker is reset
    // with it: its per-profile cache does not follow the generation itself, and an edited mask profile
    // must render from the next request on.
    local procedure EnsureMaskState(TableNo: Integer)
    var
        Generation: Integer;
    begin
        Generation := PolicyCtx.PolicyGeneration();
        if MaskLoaded then
            if (MaskTableNo = TableNo) and (MaskGeneration = Generation) then
                exit;
        if (not MaskLoaded) or (MaskGeneration <> Generation) then
            Clear(Masker);
        Clear(MaskChecked);
        Clear(MaskProfileByField);
        MaskTableNo := TableNo;
        MaskGeneration := Generation;
        MaskLoaded := true;
    end;

    // One policy question per field per table and generation; every later row answers from the
    // dictionaries.
    local procedure IsMaskedField(TableNo: Integer; FieldNo: Integer; var ProfileCode: Code[20]): Boolean
    begin
        if not MaskChecked.ContainsKey(FieldNo) then begin
            if FieldPolicy.ReadVerdict(TableNo, FieldNo, ProfileCode) = "Bcmag Read Access"::Masked then
                MaskProfileByField.Add(FieldNo, ProfileCode);
            MaskChecked.Add(FieldNo, true);
        end;
        exit(MaskProfileByField.Get(FieldNo, ProfileCode));
    end;

    local procedure KindSkip(): Integer
    begin
        exit(0);
    end;

    local procedure KindNormal(): Integer
    begin
        exit(1);
    end;

    local procedure KindFlowField(): Integer
    begin
        exit(2);
    end;

    local procedure AddSystemId(RecRef: RecordRef; var Row: JsonObject)
    var
        SystemId: Guid;
    begin
        if not RecRef.FieldExist(RecRef.SystemIdNo()) then
            exit;
        SystemId := RecRef.Field(RecRef.SystemIdNo()).Value;
        if not IsNullGuid(SystemId) then
            Row.Add('@systemId', LowerCase(DelChr(Format(SystemId, 0, 4), '=', '{}')));
    end;

    local procedure AddEtag(RecRef: RecordRef; var Row: JsonObject; StrongEtag: Boolean)
    var
        Etag: Text;
    begin
        Etag := EtagOf(RecRef, StrongEtag);
        if Etag <> '' then
            Row.Add('@etag', Etag);
    end;

    // ETag derived from SystemModifiedAt (base64). Empty when the table has no system fields.
    // NOTE: the strictly-correct source is the SQL row version — exposed in AL (BC 25+) as the
    // monotonic, collision-free `SystemRowVersion` field. But it is reachable ONLY on a strongly-typed
    // Record: RecordRef has no SystemRowVersion property and no SystemRowVersionNo() field-number
    // accessor (verified against the 28.2 symbols + Learn — RecordRef exposes SystemIdNo /
    // SystemCreatedAtNo / SystemCreatedByNo / SystemModifiedAtNo / SystemModifiedByNo only), and there
    // is no documented stable field number to read it via RecRef.Field(). Wicket is generic over
    // RecordRef by design, so the rowversion is genuinely out of reach here. SystemModifiedAt is the
    // best RecordRef-accessible signal. It is DateTime = MILLISECOND resolution (00:00:00.000 …
    // .999), so two modifies of the SAME record within the SAME millisecond produce an identical ETag
    // and the later one could slip past the concurrency check (LocateForWrite still LockTable-serializes
    // the writes; the residual gap is only detecting an interleaved external change that landed in the
    // same millisecond). Narrow, but real. A value-hash ETag would close it at a per-row read cost —
    // offered as an opt-in, not the default.
    // Back-compat overload (write plane): reads the Strong ETag flag itself.
    procedure EtagOf(RecRef: RecordRef): Text
    begin
        exit(EtagOf(RecRef, StrongEtagEnabled()));
    end;

    procedure EtagOf(RecRef: RecordRef; StrongEtag: Boolean): Text
    var
        Modified: DateTime;
        Base64: Codeunit "Base64 Convert";
        Token: Text;
    begin
        EnsureMeta(RecRef.Number);
        if not MetaHasModifiedAt then
            exit('');
        Modified := RecRef.Field(2000000003).Value;
        Token := Format(Modified, 0, 9);
        // Strong mode folds a hash of the row's field values into the token, so a change that lands in
        // the SAME millisecond as the caller's read still shifts the ETag (the SystemModifiedAt-only
        // token cannot). It costs a full field read+hash per row, so it is opt-in (Setup "Strong ETag").
        if StrongEtag then
            Token += '|' + FieldValueHash(RecRef);
        exit(Base64.ToBase64(Token, false));
    end;

    // HMAC-SHA-256 (tenant key, so a hidden low-entropy value cannot be confirmed by guessing offline) over the row's readable scalar fields (Normal class; skips blobs, media, flowfields and
    // flowfilters — the same fields the projection emits), in field-number order for determinism. The
    // read projection and the write concurrency check both route through EtagOf, so they hash identically.
    local procedure FieldValueHash(RecRef: RecordRef): Text
    var
        Builder: TextBuilder;
        FieldNo: Integer;
    begin
        EnsureHashFields(RecRef.Number);
        foreach FieldNo in HashFieldNos do
            if RecRef.FieldExist(FieldNo) then begin
                Builder.Append(Format(FieldNo));
                Builder.Append('=');
                Builder.Append(Format(RecRef.Field(FieldNo).Value, 0, 9));
                Builder.Append(';');
            end;
        exit(HashKey.Hmac(Builder.ToText()));
    end;

    // The hash input list is resolved once per table (not per row). The filter is unchanged from the
    // per-row version, so tokens minted before and after this cache are identical.
    local procedure EnsureHashFields(TableNo: Integer)
    var
        FieldRec: Record Field;
    begin
        if (HashTableNo = TableNo) and (TableNo <> 0) then
            exit;
        Clear(HashFieldNos);
        FieldRec.SetRange(TableNo, TableNo);
        FieldRec.SetRange(Class, FieldRec.Class::Normal);
        FieldRec.SetFilter(Type, '<>%1&<>%2&<>%3', FieldRec.Type::BLOB, FieldRec.Type::Media, FieldRec.Type::MediaSet);
        if FieldRec.FindSet() then
            repeat
                HashFieldNos.Add(FieldRec."No.");
            until FieldRec.Next() = 0;
        HashTableNo := TableNo;
    end;

    local procedure StrongEtagEnabled(): Boolean
    var
        Setup: Record "Bcmag Setup";
    begin
        Setup.GetSingleton();
        exit(Setup."Strong ETag");
    end;

    procedure HasSystemFields(TableId: Integer): Boolean
    var
        FieldRec: Record Field;
    begin
        exit(FieldRec.Get(TableId, 2000000003));
    end;
}
