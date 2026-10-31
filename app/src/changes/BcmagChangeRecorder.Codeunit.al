codeunit 94158 "Bcmag Change Recorder"
{
    // Writes the change history (Setup "Record Changes"): one "Bcmag Change Entry" per record the agent
    // created, changed or deleted, with one "Bcmag Field Change" per changed field, and one entry per
    // action or procedure run. The write handlers call it after their write succeeded, inside the same
    // transaction, so a write that fails or rolls back leaves no history.
    //
    // Values are stored as the field policy shows the field at its BASELINE (without the caller's
    // unmask grants or exceptions): the history is read later by other people, and an unmask grant
    // must not leave clear copies behind. Masked → the mask rendering; Hidden → no values. The policy
    // is applied again when the history is read (the changes operation).
    //
    // Compared and stored as Format(value, 0, 9) (XML format: locale-independent), except Option
    // fields, stored as their member name. Blob, Media and MediaSet fields are never written by Wicket;
    // a created or deleted record lists one that holds a value, without values.
    Permissions = tabledata "Bcmag Change Entry" = RI, tabledata "Bcmag Field Change" = RI;

    var
        Setup: Record "Bcmag Setup";
        Policy: Codeunit "Bcmag Field Policy";
        Masker: Codeunit "Bcmag Field Masker";
        RunnerCtx: Codeunit "Bcmag Op Runner Context";
        BinaryTok: Label '<binary>', Locked = true;
        SucceededTxt: Label 'Succeeded', Locked = true;
        FailedTxt: Label 'Failed - may have changed data', Locked = true;

    procedure SucceededOutcome(): Text
    begin
        exit(SucceededTxt);
    end;

    procedure FailedOutcome(): Text
    begin
        exit(FailedTxt);
    end;

    /// The record's stored values by field number, as text — taken before a change or delete.
    procedure Snapshot(var RecRef: RecordRef) Values: Dictionary of [Integer, Text]
    var
        FldRef: FieldRef;
        i: Integer;
    begin
        for i := 1 to RecRef.FieldCount() do begin
            FldRef := RecRef.FieldIndex(i);
            if Recordable(FldRef) then
                Values.Set(FldRef.Number(), ValueText(FldRef));
        end;
    end;

    procedure RecordCreated(var After: RecordRef)
    var
        Empty: Dictionary of [Integer, Text];
    begin
        if not Enabled() then exit;
        WriteEntry("Bcmag Change Kind"::Created, After, DefaultsOf(After.Number()), Empty, Snapshot(After));
    end;

    procedure RecordChanged(Before: Dictionary of [Integer, Text]; var After: RecordRef)
    begin
        if not Enabled() then exit;
        WriteEntry("Bcmag Change Kind"::Changed, After, Before, Before, Snapshot(After));
    end;

    procedure RecordDeleted(Before: Dictionary of [Integer, Text]; var Deleted: RecordRef)
    begin
        if not Enabled() then exit;
        WriteEntry("Bcmag Change Kind"::Deleted, Deleted, DefaultsOf(Deleted.Number()), Before, DefaultsOf(Deleted.Number()));
    end;

    /// An action or enrolled procedure run: one entry, no field lines. TableId 0 when there is no target.
    procedure RecordRun(Kind: Enum "Bcmag Change Kind"; RunName: Text; TableId: Integer; TargetSystemId: Guid; Outcome: Text; ResultText: Text)
    var
        Entry: Record "Bcmag Change Entry";
        RecRef: RecordRef;
    begin
        if not Enabled() then exit;
        InitEntry(Entry, Kind);
        Entry.Name := CopyStr(RunName, 1, MaxStrLen(Entry.Name));
        Entry.Outcome := CopyStr(Outcome, 1, MaxStrLen(Entry.Outcome));
        Entry.Result := CopyStr(ResultText, 1, MaxStrLen(Entry.Result));
        Entry."Record SystemId" := TargetSystemId;
        if TableId <> 0 then begin
            Entry."Table Id" := TableId;
            RecRef.Open(TableId);
            Entry."Table Name" := CopyStr(RecRef.Name(), 1, MaxStrLen(Entry."Table Name"));
            Entry."Record SystemId" := TargetSystemId;
            if not IsNullGuid(TargetSystemId) then
                if RecRef.GetBySystemId(TargetSystemId) then
                    Entry."Record Key" := CopyStr(KeyText(RecRef), 1, MaxStrLen(Entry."Record Key"));
            RecRef.Close();
        end;
        Entry.Insert();
    end;

    local procedure Enabled(): Boolean
    begin
        Setup.GetSingleton();
        exit(Setup."Record Changes" <> Setup."Record Changes"::Off);
    end;

    // Changed fields are those whose text differs between Compare (the reference) and After; Old shows
    // the value from OldValues (empty for a created record), New the value from NewValues (empty for a
    // deleted one).
    local procedure WriteEntry(Kind: Enum "Bcmag Change Kind"; var RecRef: RecordRef; Compare: Dictionary of [Integer, Text]; OldValues: Dictionary of [Integer, Text]; NewValues: Dictionary of [Integer, Text])
    var
        Entry: Record "Bcmag Change Entry";
        FieldChange: Record "Bcmag Field Change";
        Current: Dictionary of [Integer, Text];
        FieldNo: Integer;
        OldText, NewText, CompareText, CurrentText: Text;
        LineNo: Integer;
    begin
        if Kind = Kind::Deleted then
            Current := OldValues
        else
            Current := NewValues;
        InitEntry(Entry, Kind);
        Entry."Table Id" := RecRef.Number();
        Entry."Table Name" := CopyStr(RecRef.Name(), 1, MaxStrLen(Entry."Table Name"));
        Entry."Record Key" := CopyStr(KeyText(RecRef), 1, MaxStrLen(Entry."Record Key"));
        Entry."Record SystemId" := RecRef.Field(RecRef.SystemIdNo()).Value();
        Entry.Insert();

        foreach FieldNo in Current.Keys() do begin
            CurrentText := Current.Get(FieldNo);
            CompareText := '';
            if Compare.ContainsKey(FieldNo) then
                CompareText := Compare.Get(FieldNo);
            if CurrentText <> CompareText then begin
                OldText := '';
                NewText := '';
                if OldValues.ContainsKey(FieldNo) and (Kind <> Kind::Created) then
                    OldText := OldValues.Get(FieldNo);
                if NewValues.ContainsKey(FieldNo) and (Kind <> Kind::Deleted) then
                    NewText := NewValues.Get(FieldNo);
                LineNo += 10000;
                AddLine(FieldChange, Entry."Entry No.", LineNo, RecRef, FieldNo, OldText, NewText);
            end;
        end;
        Entry."Field Count" := LineNo div 10000;
        Entry.Modify();
    end;

    local procedure InitEntry(var Entry: Record "Bcmag Change Entry"; Kind: Enum "Bcmag Change Kind")
    begin
        Entry.Init();
        Entry."Entry No." := 0;
        Entry.Kind := Kind;
        Entry."Created At" := CurrentDateTime();
        Entry."Request Id" := CopyStr(RunnerCtx.GetRequestId(), 1, MaxStrLen(Entry."Request Id"));
        Entry.Connection := CopyStr(ConnectionOf(RunnerCtx.GetOrigin()), 1, MaxStrLen(Entry.Connection));
        Entry."User Security Id" := UserSecurityId();
        Entry."User Id" := CopyStr(UserId(), 1, MaxStrLen(Entry."User Id"));
    end;

    local procedure AddLine(var FieldChange: Record "Bcmag Field Change"; EntryNo: BigInteger; LineNo: Integer; var RecRef: RecordRef; FieldNo: Integer; OldText: Text; NewText: Text)
    var
        FldRef: FieldRef;
        ProfileCode: Code[20];
        Access: Enum "Bcmag Read Access";
        Cut: Boolean;
    begin
        FldRef := RecRef.Field(FieldNo);
        Access := Policy.BaselineReadVerdict(RecRef.Number(), FieldNo, ProfileCode);
        FieldChange.Init();
        FieldChange."Entry No." := EntryNo;
        FieldChange."Line No." := LineNo;
        FieldChange."Field No." := FieldNo;
        FieldChange."Field Name" := CopyStr(FldRef.Name(), 1, MaxStrLen(FieldChange."Field Name"));
        FieldChange."Stored As" := Access;
        if (Setup."Record Changes" = Setup."Record Changes"::OldAndNewValues) and (Access <> Access::Hidden) and not IsBinary(FldRef) then begin
            if Access = Access::Masked then begin
                if OldText <> '' then OldText := Masker.MaskText(OldText, ProfileCode);
                if NewText <> '' then NewText := Masker.MaskText(NewText, ProfileCode);
            end;
            FieldChange."Old Value" := Fit(OldText, Cut);
            FieldChange.Truncated := Cut;
            FieldChange."New Value" := Fit(NewText, Cut);
            FieldChange.Truncated := FieldChange.Truncated or Cut;
        end;
        FieldChange.Insert();
    end;

    local procedure Fit(Value: Text; var Cut: Boolean): Text
    var
        Max: Integer;
    begin
        Max := Setup."Max Value Length";
        if Max <= 0 then
            Max := 250;
        Cut := StrLen(Value) > Max;
        if Cut then
            exit(CopyStr(Value, 1, Max));
        exit(Value);
    end;

    // The values a new, empty record of the table holds: what "not set" means for a created or
    // deleted record.
    local procedure DefaultsOf(TableId: Integer) Values: Dictionary of [Integer, Text]
    var
        RecRef: RecordRef;
    begin
        RecRef.Open(TableId);
        RecRef.Init();
        Values := Snapshot(RecRef);
        RecRef.Close();
    end;

    local procedure Recordable(var FldRef: FieldRef): Boolean
    begin
        if FldRef.Class() <> FieldClass::Normal then
            exit(false);
        if FldRef.Number() >= 2000000000 then // system fields (SystemId, SystemCreatedAt, ...)
            exit(false);
        exit(FldRef.Active());
    end;

    local procedure IsBinary(var FldRef: FieldRef): Boolean
    begin
        exit(FldRef.Type() in [FieldType::Blob, FieldType::Media, FieldType::MediaSet]);
    end;

    local procedure ValueText(var FldRef: FieldRef): Text
    var
        Ordinal: Integer;
    begin
        case FldRef.Type() of
            FieldType::Blob:
                begin
                    FldRef.CalcField();
                    if HasBlobValue(FldRef) then
                        exit(BinaryTok);
                    exit('');
                end;
            FieldType::Media, FieldType::MediaSet:
                begin
                    if Format(FldRef.Value(), 0, 9) in ['', '00000000-0000-0000-0000-000000000000'] then
                        exit('');
                    exit(BinaryTok);
                end;
            FieldType::Option:
                begin
                    Ordinal := FldRef.Value();
                    exit(FldRef.GetEnumValueNameFromOrdinalValue(Ordinal));
                end;
        end;
        exit(Format(FldRef.Value(), 0, 9));
    end;

    local procedure HasBlobValue(var FldRef: FieldRef): Boolean
    var
        TempBlob: Codeunit "Temp Blob";
    begin
        TempBlob.FromFieldRef(FldRef);
        exit(TempBlob.HasValue());
    end;

    local procedure KeyText(var RecRef: RecordRef) Result: Text
    var
        KeyRef: KeyRef;
        i: Integer;
    begin
        KeyRef := RecRef.KeyIndex(1);
        for i := 1 to KeyRef.FieldCount() do begin
            if i > 1 then
                Result += ', ';
            Result += Format(KeyRef.FieldIndex(i).Value());
        end;
    end;

    // The connection is the origin's part after "+" (mcp.wicket/<version>+<connection>); a client
    // that names no connection is shown by its origin.
    local procedure ConnectionOf(Origin: Text): Text
    var
        Plus: Integer;
    begin
        Plus := StrPos(Origin, '+');
        if Plus > 0 then
            exit(CopyStr(Origin, Plus + 1));
        exit(Origin);
    end;
}
