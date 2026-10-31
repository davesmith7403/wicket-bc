codeunit 94159 "Bcmag Op Changes"
{
    // "changes" operation: the change history (Setup "Record Changes"), newest first, each entry with
    // its field changes. Refused (403 changes-off) when Setup "Agent Can Read Changes" is off or the
    // history is off. Caller-scoped like "requests": a caller sees only the entries made under its own
    // user, unless it holds the Wicket - Audit Changes gate (write permission on "Bcmag Changes Gate"),
    // which also unlocks the data.user filter (403 changes-forbidden without it).
    //
    // Values were stored at the field policy's baseline; the policy is applied again on read with the
    // caller's strict verdict (never a lift), and only ever downgrades: a field that has since become
    // Masked shows the mask rendering of a stored clear value, one that has become Hidden shows no
    // values, and a stored mask or "hidden" is never shown more clearly.
    //
    // data: from, to (ISO date-time), tableId, viaConnection (the connection name; "connection" is the
    // MCP server's per-call override), kind (created/changed/deleted/action/
    // procedure), user (gate only), top (default 20, capped at 100), cursor (the @nextLink).

    Access = Public;
    Permissions = tabledata "Bcmag Change Entry" = R, tabledata "Bcmag Field Change" = R;

    var
        Problem: Codeunit "Bcmag Problem";
        JsonRead: Codeunit "Bcmag Json Read";
        Masker: Codeunit "Bcmag Field Masker";
        CursorPrefixTok: Label 'changes:', Locked = true;

    procedure Run(Data: JsonObject; var Response: JsonObject; var Fail: JsonObject; var Cost: Integer): Boolean
    var
        Gate: Record "Bcmag Changes Gate";
        Tok: JsonToken;
    begin
        if not RunScoped(Data, Gate.WritePermission(), Response, Fail) then
            exit(false);
        Response.Get('value', Tok);
        Cost := Tok.AsArray().Count();
        exit(true);
    end;

    // SeeEveryone is the gate check; Run passes the real one. Internal so the tests can show both
    // scopes while running as SUPER, which holds every gate.
    internal procedure RunScoped(Data: JsonObject; SeeEveryone: Boolean; var Response: JsonObject; var Fail: JsonObject): Boolean
    var
        Setup: Record "Bcmag Setup";
        Entry: Record "Bcmag Change Entry";
        Policy: Codeunit "Bcmag Field Policy";
        Arr: JsonArray;
        Top, Returned: Integer;
        HasMore: Boolean;
    begin
        Setup.GetSingleton();
        if (not Setup."Agent Can Read Changes") or (Setup."Record Changes" = Setup."Record Changes"::Off) then begin
            Fail := Problem.NewFailure(403, 'changes-off', 'Change history not available',
                'the change history is off, or not readable by the agent, on the Wicket Setup card (Change History)');
            exit(false);
        end;

        if not ApplyFilters(Data, SeeEveryone, Entry, Top, Fail) then
            exit(false);

        if Entry.FindSet() then
            repeat
                if Returned >= Top then
                    HasMore := true
                else begin
                    Arr.Add(ProjectEntry(Entry, Policy));
                    Returned += 1;
                end;
            until HasMore or (Entry.Next() = 0);

        Clear(Response);
        Response.Add('value', Arr);
        if HasMore then
            Response.Add('@nextLink', EncodeCursor(LastEntryNo(Arr)));
        exit(true);
    end;

    // How a stored field change is shown now: the more restrictive of how it was stored and the
    // policy's strict verdict for this reader. Clears the values when hidden; masks a stored clear
    // value when the field is now masked. Shared with the Wicket Changes page.
    procedure ShownAs(var Policy: Codeunit "Bcmag Field Policy"; TableId: Integer; FieldNo: Integer; StoredAs: Enum "Bcmag Read Access"; var OldText: Text; var NewText: Text) Shown: Enum "Bcmag Read Access"
    var
        ProfileCode: Code[20];
        Now: Enum "Bcmag Read Access";
    begin
        Now := Policy.StrictReadVerdict(TableId, FieldNo, ProfileCode);
        Shown := StoredAs;
        if Rank(Now) > Rank(StoredAs) then
            Shown := Now;
        case Shown of
            Shown::Hidden:
                begin
                    OldText := '';
                    NewText := '';
                end;
            Shown::Masked:
                if StoredAs = StoredAs::Clear then begin
                    if OldText <> '' then OldText := Masker.MaskText(OldText, ProfileCode);
                    if NewText <> '' then NewText := Masker.MaskText(NewText, ProfileCode);
                end;
        end;
    end;

    local procedure ApplyFilters(Data: JsonObject; SeeEveryone: Boolean; var Entry: Record "Bcmag Change Entry"; var Top: Integer; var Fail: JsonObject): Boolean
    var
        Tok: JsonToken;
        TextValue: Text;
        IntValue: Integer;
        FromMoment, ToMoment: DateTime;
        AfterEntryNo: BigInteger;
        Kind: Enum "Bcmag Change Kind";
    begin
        Entry.SetCurrentKey("Entry No.");
        Entry.Ascending(false);
        if not SeeEveryone then
            Entry.SetRange("User Security Id", UserSecurityId());

        if HasValue(Data, 'user', Tok) then begin
            if not SeeEveryone then begin
                Fail := Problem.NewFailure(403, 'changes-forbidden', 'Not allowed to read other users'' changes',
                    'data.user needs the Wicket - Audit Changes permission set; without it the history shows your own changes');
                exit(false);
            end;
            if not JsonRead.ReadText(Tok, 'user', TextValue, Fail) then exit(false);
            Entry.SetRange("User Id", CopyStr(UpperCase(TextValue), 1, MaxStrLen(Entry."User Id")));
        end;

        FromMoment := 0DT;
        ToMoment := 0DT;
        if HasValue(Data, 'from', Tok) then
            if not ReadMoment(Tok, 'from', FromMoment, Fail) then exit(false);
        if HasValue(Data, 'to', Tok) then
            if not ReadMoment(Tok, 'to', ToMoment, Fail) then exit(false);
        case true of
            (FromMoment <> 0DT) and (ToMoment <> 0DT):
                Entry.SetRange("Created At", FromMoment, ToMoment);
            FromMoment <> 0DT:
                Entry.SetFilter("Created At", '>=%1', FromMoment);
            ToMoment <> 0DT:
                Entry.SetFilter("Created At", '<=%1', ToMoment);
        end;

        if HasValue(Data, 'tableId', Tok) then begin
            if not JsonRead.ReadInteger(Tok, 'tableId', IntValue, Fail) then exit(false);
            Entry.SetRange("Table Id", IntValue);
        end;
        if HasValue(Data, 'viaConnection', Tok) then begin
            if not JsonRead.ReadText(Tok, 'viaConnection', TextValue, Fail) then exit(false);
            Entry.SetRange(Connection, CopyStr(TextValue, 1, MaxStrLen(Entry.Connection)));
        end;
        if HasValue(Data, 'kind', Tok) then begin
            if not JsonRead.ReadText(Tok, 'kind', TextValue, Fail) then exit(false);
            if not TryMapKind(TextValue, Kind) then begin
                Fail := Problem.NewFailure(400, 'invalid-field', 'Invalid kind',
                    'data.kind must be one of created, changed, deleted, action, procedure');
                exit(false);
            end;
            Entry.SetRange(Kind, Kind);
        end;

        Top := 20;
        if HasValue(Data, 'top', Tok) then
            if not JsonRead.ReadInteger(Tok, 'top', Top, Fail) then exit(false);
        if Top < 1 then
            Top := 1;
        if Top > 100 then
            Top := 100;

        if HasValue(Data, 'cursor', Tok) then begin
            if not JsonRead.ReadText(Tok, 'cursor', TextValue, Fail) then exit(false);
            if not DecodeCursor(TextValue, AfterEntryNo) then begin
                Fail := Problem.NewFailure(400, 'invalid-cursor', 'Invalid cursor',
                    'pass data.cursor exactly as the previous response''s @nextLink, with the same filters');
                exit(false);
            end;
            Entry.SetFilter("Entry No.", '<%1', AfterEntryNo);
        end;
        exit(true);
    end;

    local procedure ProjectEntry(var Entry: Record "Bcmag Change Entry"; var Policy: Codeunit "Bcmag Field Policy") Obj: JsonObject
    var
        FieldChange: Record "Bcmag Field Change";
        Fields: JsonArray;
        Line: JsonObject;
        OldText, NewText : Text;
        Shown: Enum "Bcmag Read Access";
    begin
        Obj.Add('entryNo', Entry."Entry No.");
        Obj.Add('createdAt', Entry."Created At");
        Obj.Add('kind', KindName(Entry.Kind));
        Obj.Add('tableId', Entry."Table Id");
        Obj.Add('tableName', Entry."Table Name");
        Obj.Add('recordKey', Entry."Record Key");
        if not IsNullGuid(Entry."Record SystemId") then
            Obj.Add('systemId', Format(Entry."Record SystemId", 0, 4).ToLower());
        Obj.Add('user', Entry."User Id");
        Obj.Add('connection', Entry.Connection);
        Obj.Add('requestId', Entry."Request Id");
        if Entry.Name <> '' then begin
            Obj.Add('name', Entry.Name);
            Obj.Add('outcome', Entry.Outcome);
            Obj.Add('result', Entry.Result);
        end;
        Obj.Add('fieldCount', Entry."Field Count");

        FieldChange.SetRange("Entry No.", Entry."Entry No.");
        if FieldChange.FindSet() then
            repeat
                Clear(Line);
                OldText := FieldChange."Old Value";
                NewText := FieldChange."New Value";
                Shown := ShownAs(Policy, Entry."Table Id", FieldChange."Field No.", FieldChange."Stored As", OldText, NewText);
                Line.Add('fieldNo', FieldChange."Field No.");
                Line.Add('fieldName', FieldChange."Field Name");
                Line.Add('shownAs', ShownName(Shown));
                if Shown <> Shown::Hidden then begin
                    Line.Add('old', OldText);
                    Line.Add('new', NewText);
                    if FieldChange.Truncated then
                        Line.Add('truncated', true);
                end;
                Fields.Add(Line);
            until FieldChange.Next() = 0;
        Obj.Add('fields', Fields);
    end;

    local procedure HasValue(Data: JsonObject; Name: Text; var Tok: JsonToken): Boolean
    begin
        if not Data.Get(Name, Tok) then
            exit(false);
        exit(JsonRead.IsNonNullValue(Tok));
    end;

    local procedure ReadMoment(Tok: JsonToken; Name: Text; var Moment: DateTime; var Fail: JsonObject): Boolean
    var
        TextValue: Text;
    begin
        if not JsonRead.ReadText(Tok, Name, TextValue, Fail) then exit(false);
        if not Evaluate(Moment, TextValue, 9) then begin
            Fail := Problem.NewFailure(400, 'invalid-field', StrSubstNo('Invalid %1', Name),
                StrSubstNo('data.%1 must be an ISO 8601 date-time, for example 2026-10-29T00:00:00Z', Name));
            exit(false);
        end;
        exit(true);
    end;

    local procedure Rank(Access: Enum "Bcmag Read Access"): Integer
    begin
        case Access of
            Access::Clear:
                exit(0);
            Access::Masked:
                exit(1);
        end;
        exit(2);
    end;

    local procedure ShownName(Access: Enum "Bcmag Read Access"): Text
    begin
        case Access of
            Access::Clear:
                exit('clear');
            Access::Masked:
                exit('masked');
        end;
        exit('hidden');
    end;

    local procedure KindName(Kind: Enum "Bcmag Change Kind"): Text
    begin
        case Kind of
            Kind::Created:
                exit('created');
            Kind::Changed:
                exit('changed');
            Kind::Deleted:
                exit('deleted');
            Kind::Action:
                exit('action');
        end;
        exit('procedure');
    end;

    local procedure TryMapKind(Name: Text; var Kind: Enum "Bcmag Change Kind"): Boolean
    begin
        case LowerCase(Name) of
            'created':
                Kind := Kind::Created;
            'changed':
                Kind := Kind::Changed;
            'deleted':
                Kind := Kind::Deleted;
            'action':
                Kind := Kind::Action;
            'procedure':
                Kind := Kind::ProcedureRun;
            else
                exit(false);
        end;
        exit(true);
    end;

    local procedure LastEntryNo(Arr: JsonArray): BigInteger
    var
        Tok: JsonToken;
    begin
        Arr.Get(Arr.Count() - 1, Tok);
        Tok.AsObject().Get('entryNo', Tok);
        exit(Tok.AsValue().AsBigInteger());
    end;

    local procedure EncodeCursor(EntryNo: BigInteger): Text
    var
        Base64: Codeunit "Base64 Convert";
    begin
        exit(Base64.ToBase64(CursorPrefixTok + Format(EntryNo, 0, 9)));
    end;

    local procedure DecodeCursor(Cursor: Text; var EntryNo: BigInteger): Boolean
    var
        Decoded: Text;
    begin
        if not TryFromBase64(Cursor, Decoded) then
            exit(false);
        if not Decoded.StartsWith(CursorPrefixTok) then
            exit(false);
        exit(Evaluate(EntryNo, CopyStr(Decoded, StrLen(CursorPrefixTok) + 1), 9));
    end;

    [TryFunction]
    local procedure TryFromBase64(Cursor: Text; var Decoded: Text)
    var
        Base64: Codeunit "Base64 Convert";
    begin
        Decoded := Base64.FromBase64(Cursor);
    end;
}
