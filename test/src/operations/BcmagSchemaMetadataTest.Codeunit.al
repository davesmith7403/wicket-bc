codeunit 94338 "Bcmag Schema Metadata Test"
{
    Subtype = Test;
    TestPermissions = Disabled;

    // The schema-knowledge surface: which app owns an object (discover/describe `app`, discover's
    // publisher filter), describe's content hash (describeVersion / ifNoneMatch / notModified), the
    // opt-in reverse relations (referencedBy) and capabilities.structureVersion.

    var
        Discover: Codeunit "Bcmag Op Discover";
        Describe: Codeunit "Bcmag Op Describe";
        Capabilities: Codeunit "Bcmag Op Capabilities";
        Helper: Codeunit "Bcmag Test Helper";
        LibraryAssert: Codeunit "Library Assert";

    [Test]
    procedure DiscoverRowsNameTheOwningApp()
    var
        Row: JsonObject;
    begin
        Helper.ConfigureOpenMode();
        LibraryAssert.IsTrue(FindDiscoverRow('', Database::"Bcmag Setup", Row), 'the Setup table must be listed in Open mode');
        LibraryAssert.AreEqual('Wicket', AppMember(Row, 'name'), 'app.name of a Wicket table');
        LibraryAssert.AreEqual('Dave The Wicketkeeper', AppMember(Row, 'publisher'), 'app.publisher of a Wicket table');
        LibraryAssert.AreEqual('4057cf1f-1b34-409a-a570-c6fdf625c434', AppMember(Row, 'id'), 'app.id is the app id');
        LibraryAssert.IsTrue(StrLen(AppMember(Row, 'version')) >= 7, 'app.version is major.minor.build.revision');
    end;

    [Test]
    procedure PublisherFilterListsOnlyThatPublishersObjects()
    var
        Data, Response, Row: JsonObject;
        Fail: JsonObject;
        Tok, RowTok: JsonToken;
        Rows: JsonArray;
        Cost: Integer;
        SawSetup: Boolean;
    begin
        Helper.ConfigureOpenMode();
        Data.Add('kind', 'tables');
        Data.Add('publisher', 'Dave The Wicketkeeper');
        Data.Add('top', 1000);
        LibraryAssert.IsTrue(Discover.Run(Data, Response, Fail, Cost), 'discover with a publisher filter should succeed');
        Response.Get('value', Tok);
        Rows := Tok.AsArray();
        LibraryAssert.IsTrue(Rows.Count() > 0, 'the publisher filter must find the Wicket tables');
        foreach RowTok in Rows do begin
            Row := RowTok.AsObject();
            LibraryAssert.AreEqual('Dave The Wicketkeeper', AppMember(Row, 'publisher'), 'every row must belong to the filtered publisher');
            Row.Get('id', Tok);
            if Tok.AsValue().AsInteger() = Database::"Bcmag Setup" then
                SawSetup := true;
        end;
        LibraryAssert.IsTrue(SawSetup, 'the Setup table must be among the publisher''s tables');

        // Base Application tables do not belong to that publisher.
        LibraryAssert.IsFalse(FindDiscoverRow('Dave The Wicketkeeper', Database::Customer, Row), 'Customer must not match publisher Dave The Wicketkeeper');
    end;

    [Test]
    procedure DescribeCarriesAppAndRevalidatesByHash()
    var
        Value, NotModified: JsonObject;
        Tok: JsonToken;
        Version: Text;
    begin
        Helper.ConfigureOpenMode();
        Value := DescribeTable(Database::"Bcmag Setup", '', false);
        LibraryAssert.AreEqual('Dave The Wicketkeeper', AppMember(Value, 'publisher'), 'describe names the owning app');
        LibraryAssert.IsTrue(Value.Get('describeVersion', Tok), 'describeVersion missing');
        Version := Tok.AsValue().AsText();
        LibraryAssert.AreEqual(64, StrLen(Version), 'describeVersion is a SHA-256 hex digest');

        NotModified := DescribeTable(Database::"Bcmag Setup", Version, false);
        LibraryAssert.IsTrue(NotModified.Get('notModified', Tok), 'a matching ifNoneMatch must answer notModified');
        LibraryAssert.IsTrue(Tok.AsValue().AsBoolean(), 'notModified must be true');
        LibraryAssert.IsFalse(NotModified.Contains('fields'), 'a notModified answer carries no schema');

        Value := DescribeTable(Database::"Bcmag Setup", 'stale-version', false);
        LibraryAssert.IsTrue(Value.Contains('fields'), 'a stale ifNoneMatch must get the full answer');
        LibraryAssert.IsFalse(Value.Contains('notModified'), 'a full answer is not marked notModified');
    end;

    [Test]
    procedure DescribeVersionMovesWhenTheFieldPolicyChanges()
    var
        Customer: Record Customer;
        Before, After: Text;
    begin
        // The hash covers what this caller sees, so hiding a field must invalidate a cached answer.
        Helper.ConfigureOpenMode();
        Helper.SetFieldPolicyMode("Bcmag Field Policy Mode"::ByClassification);
        Before := VersionOf(DescribeTable(Database::Customer, '', false));
        Helper.SetFieldAccess(Database::Customer, Customer.FieldNo(Name), "Bcmag Read Access"::Hidden, '', false);
        After := VersionOf(DescribeTable(Database::Customer, '', false));
        LibraryAssert.AreNotEqual(Before, After, 'hiding a field must change describeVersion');
        Helper.ConfigureOpenMode();
    end;

    [Test]
    procedure ReferencedByListsReadableRelationsOnly()
    var
        CustLedgerEntry: Record "Cust. Ledger Entry";
        FieldNo: Integer;
    begin
        FieldNo := CustLedgerEntry.FieldNo("Customer No.");
        Helper.ConfigureOpenMode();
        LibraryAssert.IsTrue(HasReference(DescribeTable(Database::Customer, '', true), Database::"Cust. Ledger Entry", FieldNo),
            'Cust. Ledger Entry."Customer No." relates to Customer');
        LibraryAssert.IsFalse(DescribeTable(Database::Customer, '', false).Contains('referencedBy'), 'referencedBy is opt-in');

        // A hidden field's name never appears.
        Helper.SetFieldPolicyMode("Bcmag Field Policy Mode"::ByClassification);
        Helper.SetFieldAccess(Database::"Cust. Ledger Entry", FieldNo, "Bcmag Read Access"::Hidden, '', false);
        LibraryAssert.IsFalse(HasReference(DescribeTable(Database::Customer, '', true), Database::"Cust. Ledger Entry", FieldNo),
            'a hidden referencing field must not be listed');
        Helper.UnexposeField(Database::"Cust. Ledger Entry", FieldNo);

        // A table the caller may not read is not listed either.
        Helper.ConfigureAllowlistedMode();
        Helper.ExposeTable(Database::Customer, true, false, false, false);
        Helper.UnexposeTable(Database::"Cust. Ledger Entry");
        LibraryAssert.IsFalse(HasReference(DescribeTable(Database::Customer, '', true), Database::"Cust. Ledger Entry", FieldNo),
            'an unexposed referencing table must not be listed');
        Helper.ExposeTable(Database::"Cust. Ledger Entry", true, false, false, false);
        LibraryAssert.IsTrue(HasReference(DescribeTable(Database::Customer, '', true), Database::"Cust. Ledger Entry", FieldNo),
            'an exposed referencing table is listed');

        Helper.UnexposeTable(Database::"Cust. Ledger Entry");
        Helper.UnexposeTable(Database::Customer);
        Helper.ConfigureOpenMode();
    end;

    [Test]
    procedure CapabilitiesPublishAStableStructureVersion()
    var
        First, Second: Text;
    begin
        Helper.ConfigureOpenMode();
        First := StructureVersion();
        Second := StructureVersion();
        LibraryAssert.AreEqual(64, StrLen(First), 'structureVersion is a SHA-256 hex digest');
        LibraryAssert.AreEqual(First, Second, 'structureVersion is stable while no app changes');
    end;

    local procedure FindDiscoverRow(Publisher: Text; TableId: Integer; var Found: JsonObject): Boolean
    var
        Data, Response: JsonObject;
        Fail: JsonObject;
        Tok, RowTok: JsonToken;
        Cost: Integer;
    begin
        Data.Add('kind', 'tables');
        Data.Add('top', 1000);
        Data.Add('filter', '@' + ObjectCaption(TableId));
        if Publisher <> '' then
            Data.Add('publisher', Publisher);
        LibraryAssert.IsTrue(Discover.Run(Data, Response, Fail, Cost), 'discover should succeed');
        Response.Get('value', Tok);
        foreach RowTok in Tok.AsArray() do begin
            Found := RowTok.AsObject();
            Found.Get('id', Tok);
            if Tok.AsValue().AsInteger() = TableId then
                exit(true);
        end;
        exit(false);
    end;

    local procedure ObjectCaption(TableId: Integer): Text
    var
        AllObj: Record AllObjWithCaption;
    begin
        AllObj.Get(AllObj."Object Type"::Table, TableId);
        exit(AllObj."Object Caption");
    end;

    local procedure DescribeTable(TableId: Integer; IfNoneMatch: Text; WithReferencedBy: Boolean): JsonObject
    var
        Data, Response, Include: JsonObject;
        Fail: JsonObject;
        Tok: JsonToken;
        Cost: Integer;
    begin
        Data.Add('kind', 'table');
        Data.Add('tableId', TableId);
        if IfNoneMatch <> '' then
            Data.Add('ifNoneMatch', IfNoneMatch);
        if WithReferencedBy then begin
            Include.Add('referencedBy', true);
            Data.Add('include', Include);
        end;
        LibraryAssert.IsTrue(Describe.Run(Data, Response, Fail, Cost), 'describe should succeed');
        Response.Get('value', Tok);
        exit(Tok.AsObject());
    end;

    local procedure VersionOf(Value: JsonObject): Text
    var
        Tok: JsonToken;
    begin
        Value.Get('describeVersion', Tok);
        exit(Tok.AsValue().AsText());
    end;

    local procedure HasReference(Value: JsonObject; TableId: Integer; FieldNo: Integer): Boolean
    var
        Tok, EntryTok, IdTok, NoTok: JsonToken;
    begin
        if not Value.Get('referencedBy', Tok) then
            exit(false);
        foreach EntryTok in Tok.AsArray() do begin
            EntryTok.AsObject().Get('tableId', IdTok);
            EntryTok.AsObject().Get('fieldNo', NoTok);
            if (IdTok.AsValue().AsInteger() = TableId) and (NoTok.AsValue().AsInteger() = FieldNo) then
                exit(true);
        end;
        exit(false);
    end;

    local procedure AppMember(Row: JsonObject; Member: Text): Text
    var
        Tok: JsonToken;
    begin
        LibraryAssert.IsTrue(Row.Get('app', Tok), 'app missing');
        LibraryAssert.IsTrue(Tok.IsObject(), 'app must be an object for an app-owned table');
        Tok.AsObject().Get(Member, Tok);
        exit(Tok.AsValue().AsText());
    end;

    local procedure StructureVersion(): Text
    var
        Data, Response: JsonObject;
        Fail: JsonObject;
        Tok: JsonToken;
        Cost: Integer;
    begin
        LibraryAssert.IsTrue(Capabilities.Run(Data, Response, Fail, Cost), 'capabilities should succeed');
        Response.Get('value', Tok);
        Tok.AsObject().Get('structureVersion', Tok);
        exit(Tok.AsValue().AsText());
    end;
}
