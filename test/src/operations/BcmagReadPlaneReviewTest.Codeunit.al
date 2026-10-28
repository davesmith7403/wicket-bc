codeunit 94331 "Bcmag Read Plane Review Test"
{
    Subtype = Test;
    TestPermissions = Disabled;

    // Read-plane review fixes: keyset paging + cursor validation (query), policy-first readBlob,
    // token-table-before-lookup (readBlob/pageUrl), invariant option names, bounded languages,
    // the discover denylist, orderBy over a restricted key segment, and aggregate overflow.

    var
        OpQuery: Codeunit "Bcmag Op Query";
        OpReadBlob: Codeunit "Bcmag Op Read Blob";
        OpPageUrl: Codeunit "Bcmag Op Page Url";
        OpDescribe: Codeunit "Bcmag Op Describe";
        OpDiscover: Codeunit "Bcmag Op Discover";
        OpCapabilities: Codeunit "Bcmag Op Capabilities";
        Codec: Codeunit "Bcmag Record Id Codec";
        Problem: Codeunit "Bcmag Problem";
        Helper: Codeunit "Bcmag Test Helper";
        Dispatcher: Codeunit "Bcmag Rpc Dispatcher";
        LibraryAssert: Codeunit "Library Assert";

    local procedure SeedNumbered(RowCount: Integer)
    var
        Customer: Record Customer;
        i: Integer;
    begin
        if not Customer.IsEmpty() then Customer.DeleteAll();
        for i := 1 to RowCount do begin
            Customer.Init();
            Customer."No." := CopyStr(NumberedNo(i), 1, MaxStrLen(Customer."No."));
            Customer.Name := CopyStr(StrSubstNo('Row %1', i), 1, MaxStrLen(Customer.Name));
            Customer.Insert();
        end;
    end;

    // Zero-padded so the primary-key (Code) order is the numeric order.
    local procedure NumberedNo(i: Integer): Text
    begin
        if i < 10 then
            exit('K-0' + Format(i, 0, 9));
        exit('K-' + Format(i, 0, 9));
    end;

    local procedure SetScanBudget(Budget: Integer)
    var
        Setup: Record "Bcmag Setup";
    begin
        Setup.GetSingleton();
        Setup."Per-Call Scan Budget" := Budget;
        Setup.Modify();
    end;

    local procedure CollectNos(Response: JsonObject; var Nos: List of [Text])
    var
        Rows: JsonArray;
        Tok: JsonToken;
        i: Integer;
    begin
        Rows := Helper.ValueArray(Response);
        for i := 0 to Rows.Count() - 1 do begin
            Rows.Get(i, Tok);
            Nos.Add(Helper.TextField(Tok.AsObject(), 'No.'));
        end;
    end;

    local procedure CursorOf(Plain: Text): Text
    var
        Base64: Codeunit "Base64 Convert";
    begin
        exit(Base64.ToBase64(Plain, false));
    end;

    local procedure AssertProblem(Fail: JsonObject; Status: Integer; Slug: Text)
    begin
        LibraryAssert.AreEqual(Status, Helper.StatusOf(Fail), StrSubstNo('expected %1 %2: %3', Status, Slug, Helper.DetailOf(Fail)));
        LibraryAssert.AreEqual(Problem.TypeUri(Slug), Problem.ProblemTypeOf(Fail), StrSubstNo('expected the %1 problem type', Slug));
    end;

    // ---------------------------------------------------------------- query paging

    [Test]
    procedure KeysetPagingVisitsEveryRowOnceUnderASmallBudget()
    var
        Data, Response, Fail: JsonObject;
        Tok: JsonToken;
        Nos: List of [Text];
        Cursor: Text;
        Cost, Pages, i: Integer;
    begin
        // Seven rows, two per page, a scan budget of three: offset paging failed here with 422 on
        // the third page (it re-scanned the skipped rows). Keyset resumes after the last key.
        Helper.ConfigureOpenMode();
        SeedNumbered(7);
        SetScanBudget(3);
        repeat
            Clear(Data);
            Clear(Response);
            Clear(Fail);
            Data.Add('tableId', Database::Customer);
            Data.Add('top', 2);
            if Cursor <> '' then
                Data.Add('cursor', Cursor);
            LibraryAssert.IsTrue(OpQuery.Run(Data, Response, Fail, Cost), StrSubstNo('page %1 should succeed: %2', Pages + 1, Helper.DetailOf(Fail)));
            LibraryAssert.AreEqual('keyset', Helper.TextField(Response, '@pagingMode'), 'no orderBy must page by keyset');
            LibraryAssert.IsTrue(Cost <= 2, 'a keyset page must cost only its own rows');
            CollectNos(Response, Nos);
            Cursor := '';
            if Response.Get('@nextLink', Tok) then
                Cursor := Tok.AsValue().AsText();
            Pages += 1;
        until (Cursor = '') or (Pages > 10);
        LibraryAssert.AreEqual(4, Pages, 'seven rows at two per page is four pages');
        LibraryAssert.AreEqual(7, Nos.Count(), 'every row exactly once');
        for i := 1 to 7 do
            LibraryAssert.AreEqual(NumberedNo(i), Nos.Get(i), 'rows must arrive in primary-key order without gaps or repeats');
    end;

    [Test]
    procedure PageThatExactlyExhaustsTheBudgetSucceeds()
    var
        Data, Response, Fail: JsonObject;
        Tok: JsonToken;
        Cost: Integer;
    begin
        Helper.ConfigureOpenMode();
        SeedNumbered(3);
        SetScanBudget(3);
        Data.Add('tableId', Database::Customer);
        Data.Add('top', 3);
        LibraryAssert.IsTrue(OpQuery.Run(Data, Response, Fail, Cost), StrSubstNo('a budget-sized set must not fail: %1', Helper.DetailOf(Fail)));
        LibraryAssert.AreEqual(3, Helper.ValueArray(Response).Count(), 'all three rows');
        LibraryAssert.IsFalse(Response.Get('@nextLink', Tok), 'no further page');
    end;

    [Test]
    procedure BudgetStillGuardsASinglePage()
    var
        Data, Response, Fail: JsonObject;
        Cost: Integer;
    begin
        Helper.ConfigureOpenMode();
        SeedNumbered(5);
        SetScanBudget(3);
        Data.Add('tableId', Database::Customer);
        Data.Add('top', 5);
        LibraryAssert.IsFalse(OpQuery.Run(Data, Response, Fail, Cost), 'a page larger than the budget must fail');
        AssertProblem(Fail, 422, 'scan-budget');
    end;

    [Test]
    procedure LegacySkipCursorIsStillHonoured()
    var
        Data, Response, Fail: JsonObject;
        Nos: List of [Text];
        Cost: Integer;
    begin
        // Cursors minted before keyset paging ('skip:<n>') keep working after an upgrade.
        Helper.ConfigureOpenMode();
        SeedNumbered(5);
        SetScanBudget(100000); // an earlier test in this codeunit narrows it; isolation is per codeunit
        Data.Add('tableId', Database::Customer);
        Data.Add('top', 10);
        Data.Add('cursor', CursorOf('skip:2'));
        LibraryAssert.IsTrue(OpQuery.Run(Data, Response, Fail, Cost), StrSubstNo('legacy cursor should succeed: %1', Helper.DetailOf(Fail)));
        CollectNos(Response, Nos);
        LibraryAssert.AreEqual(3, Nos.Count(), 'skip:2 over five rows leaves three');
        LibraryAssert.AreEqual(NumberedNo(3), Nos.Get(1), 'resumes at the third row');
    end;

    [Test]
    procedure MalformedCursorIs400NotPageOne()
    var
        Data, Response, Fail: JsonObject;
        Cost: Integer;
    begin
        Helper.ConfigureOpenMode();
        SeedNumbered(3);
        Data.Add('tableId', Database::Customer);
        Data.Add('cursor', '%%% not base64 %%%');
        LibraryAssert.IsFalse(OpQuery.Run(Data, Response, Fail, Cost), 'non-base64 cursor must fail');
        AssertProblem(Fail, 400, 'invalid-cursor');

        Clear(Data);
        Clear(Fail);
        Data.Add('tableId', Database::Customer);
        Data.Add('cursor', CursorOf('hello'));
        LibraryAssert.IsFalse(OpQuery.Run(Data, Response, Fail, Cost), 'a cursor we never issued must fail');
        AssertProblem(Fail, 400, 'invalid-cursor');

        Clear(Data);
        Clear(Fail);
        Data.Add('tableId', Database::Customer);
        Data.Add('cursor', CursorOf('skip:abc'));
        LibraryAssert.IsFalse(OpQuery.Run(Data, Response, Fail, Cost), 'a non-numeric skip cursor must fail');
        AssertProblem(Fail, 400, 'invalid-cursor');
    end;

    [Test]
    procedure KeysetCursorForAnotherTableIs400()
    var
        Data, Response, Fail: JsonObject;
        Cost: Integer;
    begin
        Helper.ConfigureOpenMode();
        SeedNumbered(3);
        Data.Add('tableId', Database::Customer);
        Data.Add('cursor', CursorOf('pos:' + Format(Database::Vendor, 0, 9) + ':Field1=0(X)'));
        LibraryAssert.IsFalse(OpQuery.Run(Data, Response, Fail, Cost), 'a cursor bound to another table must fail');
        AssertProblem(Fail, 400, 'invalid-cursor');
    end;

    [Test]
    procedure OrderByPagesByOffsetAndRefusesAKeysetCursor()
    var
        Data, Response, Fail: JsonObject;
        OrderBy: JsonArray;
        Tok: JsonToken;
        Nos: List of [Text];
        KeysetCursor, OffsetCursor: Text;
        Cost: Integer;
    begin
        Helper.ConfigureOpenMode();
        SeedNumbered(5);
        SetScanBudget(100000); // an earlier test in this codeunit narrows it; isolation is per codeunit

        // Keyset cursor from a plain query...
        Data.Add('tableId', Database::Customer);
        Data.Add('top', 2);
        LibraryAssert.IsTrue(OpQuery.Run(Data, Response, Fail, Cost), 'plain query should succeed');
        LibraryAssert.IsTrue(Response.Get('@nextLink', Tok), 'plain query should page');
        KeysetCursor := Tok.AsValue().AsText();

        // ...an orderBy query reports offset honestly and its own cursor continues it...
        Clear(Data);
        Clear(Response);
        OrderBy.Add('No. desc');
        Data.Add('tableId', Database::Customer);
        Data.Add('top', 2);
        Data.Add('orderBy', OrderBy);
        LibraryAssert.IsTrue(OpQuery.Run(Data, Response, Fail, Cost), StrSubstNo('orderBy query should succeed: %1', Helper.DetailOf(Fail)));
        LibraryAssert.AreEqual('offset', Helper.TextField(Response, '@pagingMode'), 'orderBy pages by offset');
        LibraryAssert.IsTrue(Response.Get('@nextLink', Tok), 'orderBy query should page');
        OffsetCursor := Tok.AsValue().AsText();

        Clear(Data);
        Clear(Response);
        Data.Add('tableId', Database::Customer);
        Data.Add('top', 2);
        Data.Add('orderBy', OrderBy.Clone().AsArray());
        Data.Add('cursor', OffsetCursor);
        LibraryAssert.IsTrue(OpQuery.Run(Data, Response, Fail, Cost), 'offset continuation should succeed');
        CollectNos(Response, Nos);
        LibraryAssert.AreEqual(NumberedNo(3), Nos.Get(1), 'second descending page starts at the third-highest key');

        // ...but a keyset cursor under orderBy is refused, not reinterpreted.
        Clear(Data);
        Clear(Fail);
        Data.Add('tableId', Database::Customer);
        Data.Add('orderBy', OrderBy.Clone().AsArray());
        Data.Add('cursor', KeysetCursor);
        LibraryAssert.IsFalse(OpQuery.Run(Data, Response, Fail, Cost), 'keyset cursor with orderBy must fail');
        AssertProblem(Fail, 400, 'invalid-cursor');
    end;

    [Test]
    procedure OrderByOverIndexWithRestrictedLaterSegmentIs403()
    var
        Customer: Record Customer;
        KeyRec: Record "Key";
        FieldRec: Record Field;
        RecRef: RecordRef;
        EffectiveKey: KeyRef;
        Data, Response, Fail: JsonObject;
        OrderBy: JsonArray;
        FirstName, RestrictedName: Text;
        Parts: List of [Text];
        FirstNo, RestrictedNo, i, Cost: Integer;
        PkFieldNo: Integer;
    begin
        // Ordering by A under the platform-chosen key (A, B, ...) ranks rows by B among equal A.
        // Find a Customer key whose first segment is a single non-PK field and whose effective
        // sort (as the platform resolves SORTING(A)) carries another non-PK field B; restrict B.
        Helper.ConfigureOpenMode();
        SeedNumbered(2);
        PkFieldNo := Customer.FieldNo("No.");
        KeyRec.SetRange(TableNo, Database::Customer);
        KeyRec.SetFilter("No.", '>1');
        if KeyRec.FindSet() then
            repeat
                Parts := KeyRec."Key".Split(',');
                FieldRec.SetRange(TableNo, Database::Customer);
                FieldRec.SetRange(FieldName, DelChr(Parts.Get(1), '<>', ' '));
                if FieldRec.FindFirst() and (FieldRec."No." <> PkFieldNo) then begin
                    RecRef.Open(Database::Customer);
                    RecRef.SetView('SORTING(Field' + Format(FieldRec."No.", 0, 9) + ')');
                    EffectiveKey := RecRef.KeyIndex(RecRef.CurrentKeyIndex());
                    for i := 2 to EffectiveKey.FieldCount() do
                        if (RestrictedNo = 0) and (EffectiveKey.FieldIndex(i).Number() <> PkFieldNo) and
                           (EffectiveKey.FieldIndex(i).Number() <> FieldRec."No.")
                        then begin
                            FirstNo := FieldRec."No.";
                            FirstName := FieldRec.FieldName;
                            RestrictedNo := EffectiveKey.FieldIndex(i).Number();
                            RestrictedName := EffectiveKey.FieldIndex(i).Name();
                        end;
                    RecRef.Close();
                end;
            until (KeyRec.Next() = 0) or (RestrictedNo <> 0);
        // No such index on this Customer build: sorting by one field cannot rank a second one,
        // so there is nothing to leak and nothing to assert.
        if RestrictedNo = 0 then
            exit;

        Helper.SetFieldPolicyMode(Enum::"Bcmag Field Policy Mode"::ByClassification);
        Helper.ExposeField(Database::Customer, FirstNo, true, false);
        Helper.ExposeField(Database::Customer, RestrictedNo, false, false);
        OrderBy.Add(FirstName);
        Data.Add('tableId', Database::Customer);
        Data.Add('orderBy', OrderBy);
        LibraryAssert.IsFalse(OpQuery.Run(Data, Response, Fail, Cost), 'ordering through a restricted key segment must fail');
        AssertProblem(Fail, 403, 'field-restricted');
        LibraryAssert.IsTrue(StrPos(Helper.DetailOf(Fail), RestrictedName) = 0, 'the restricted segment must not be named');
        Helper.UnexposeField(Database::Customer, FirstNo);
        Helper.UnexposeField(Database::Customer, RestrictedNo);
    end;

    [Test]
    procedure OrderByOverIndexWithMaskedLaterSegmentIs403()
    var
        Customer: Record Customer;
        KeyRec: Record "Key";
        FieldRec: Record Field;
        RecRef: RecordRef;
        EffectiveKey: KeyRef;
        Data, Response, Fail: JsonObject;
        OrderBy: JsonArray;
        FirstName, MaskedName: Text;
        Parts: List of [Text];
        SegmentNos: List of [Integer];
        FirstNo, MaskedNo, SegmentNo, i, Cost: Integer;
        PkFieldNo: Integer;
    begin
        // The Masked twin of the restricted-segment test: ordering by a Clear field A under the
        // platform-chosen key (A, B, ...) ranks rows by B among equal A, so a Masked B would leak its
        // hidden values through row order. EffectiveKeyBlock must refuse with 403 field-masked, naming
        // B (a masked field is visible in describe, so naming it discloses nothing new).
        Helper.ConfigureOpenMode();
        SeedNumbered(2);
        PkFieldNo := Customer.FieldNo("No.");
        KeyRec.SetRange(TableNo, Database::Customer);
        KeyRec.SetFilter("No.", '>1');
        if KeyRec.FindSet() then
            repeat
                Parts := KeyRec."Key".Split(',');
                FieldRec.SetRange(TableNo, Database::Customer);
                FieldRec.SetRange(FieldName, DelChr(Parts.Get(1), '<>', ' '));
                if FieldRec.FindFirst() and (FieldRec."No." <> PkFieldNo) then begin
                    RecRef.Open(Database::Customer);
                    RecRef.SetView('SORTING(Field' + Format(FieldRec."No.", 0, 9) + ')');
                    EffectiveKey := RecRef.KeyIndex(RecRef.CurrentKeyIndex());
                    for i := 2 to EffectiveKey.FieldCount() do
                        if (MaskedNo = 0) and (EffectiveKey.FieldIndex(i).Number() <> PkFieldNo) and
                           (EffectiveKey.FieldIndex(i).Number() <> FieldRec."No.")
                        then begin
                            FirstNo := FieldRec."No.";
                            FirstName := FieldRec.FieldName;
                            MaskedNo := EffectiveKey.FieldIndex(i).Number();
                            MaskedName := EffectiveKey.FieldIndex(i).Name();
                        end;
                    // Every segment of the chosen key, so the others can be pinned Clear: a segment the
                    // classification rules hide would win (field-restricted) over the masked one.
                    if (MaskedNo <> 0) and (SegmentNos.Count() = 0) then
                        for i := 1 to EffectiveKey.FieldCount() do
                            if EffectiveKey.FieldIndex(i).Number() <> PkFieldNo then
                                SegmentNos.Add(EffectiveKey.FieldIndex(i).Number());
                    RecRef.Close();
                end;
            until (KeyRec.Next() = 0) or (MaskedNo <> 0);
        // No such index on this Customer build: nothing can be ranked by a second field.
        if MaskedNo = 0 then
            exit;

        Helper.SetFieldPolicyMode(Enum::"Bcmag Field Policy Mode"::ByClassification);
        foreach SegmentNo in SegmentNos do
            Helper.ExposeField(Database::Customer, SegmentNo, true, false);
        Helper.SetFieldAccess(Database::Customer, MaskedNo, "Bcmag Read Access"::Masked, '', false);
        OrderBy.Add(FirstName);
        Data.Add('tableId', Database::Customer);
        Data.Add('orderBy', OrderBy);
        LibraryAssert.IsFalse(OpQuery.Run(Data, Response, Fail, Cost), 'ordering through a masked key segment must fail');
        AssertProblem(Fail, 403, 'field-masked');
        LibraryAssert.IsTrue(StrPos(Helper.DetailOf(Fail), MaskedName) > 0, 'the masked segment is named: ' + Helper.DetailOf(Fail));
        foreach SegmentNo in SegmentNos do
            Helper.UnexposeField(Database::Customer, SegmentNo);
        Helper.SetFieldPolicyMode(Enum::"Bcmag Field Policy Mode"::AllFields);
    end;

    [Test]
    procedure OptionNameInRowsMatchesDescribeMemberName()
    var
        Customer: Record Customer;
        Data, Response, Fail, Row, Opt, Member: JsonObject;
        Select, Fields, Members: JsonArray;
        Tok, SubTok: JsonToken;
        RowName, DescribeName, FieldName: Text;
        Ord, Cost, i: Integer;
    begin
        // The data plane's {ord,name} and describe's optionMembers[] must use the same invariant
        // name, so an agent can join on either.
        Helper.ConfigureOpenMode();
        SeedNumbered(1);
        Customer.Get(NumberedNo(1));
        Customer."Application Method" := Customer."Application Method"::"Apply to Oldest";
        Customer.Modify();
        FieldName := 'Application Method';

        Select.Add(FieldName);
        Data.Add('tableId', Database::Customer);
        Data.Add('select', Select);
        LibraryAssert.IsTrue(OpQuery.Run(Data, Response, Fail, Cost), 'query should succeed');
        Helper.ValueArray(Response).Get(0, Tok);
        Row := Tok.AsObject();
        Row.Get(FieldName, Tok);
        Opt := Tok.AsObject();
        Opt.Get('ord', SubTok);
        Ord := SubTok.AsValue().AsInteger();
        Opt.Get('name', SubTok);
        RowName := SubTok.AsValue().AsText();

        Clear(Data);
        Clear(Response);
        Data.Add('kind', 'table');
        Data.Add('tableId', Database::Customer);
        LibraryAssert.IsTrue(OpDescribe.Run(Data, Response, Fail, Cost), 'describe should succeed');
        Helper.ValueObject(Response).Get('fields', Tok);
        Fields := Tok.AsArray();
        for i := 0 to Fields.Count() - 1 do begin
            Fields.Get(i, Tok);
            if Helper.TextField(Tok.AsObject(), 'name') = FieldName then begin
                Tok.AsObject().Get('optionMembers', SubTok);
                Members := SubTok.AsArray();
            end;
        end;
        for i := 0 to Members.Count() - 1 do begin
            Members.Get(i, Tok);
            Member := Tok.AsObject();
            Member.Get('ord', SubTok);
            if SubTok.AsValue().AsInteger() = Ord then
                DescribeName := Helper.TextField(Member, 'name');
        end;
        LibraryAssert.AreEqual('Apply to Oldest', RowName, 'row name is the invariant member name');
        LibraryAssert.AreEqual(DescribeName, RowName, 'row and describe must agree on the member name');
    end;

    // ---------------------------------------------------------------- readBlob / pageUrl

    [Test]
    procedure ReadBlobOnRestrictedNonBinaryFieldIs403WithoutName()
    var
        Customer: Record Customer;
        Data, Response, Fail: JsonObject;
        Cost: Integer;
    begin
        // The type check used to run first and answered 'field "Credit Limit (LCY)" is not a BLOB'
        // for a field the caller may not read. Policy now runs first and names by number only.
        Helper.ConfigureOpenMode();
        SeedNumbered(1);
        Helper.SetFieldPolicyMode(Enum::"Bcmag Field Policy Mode"::ByClassification);
        Helper.ExposeField(Database::Customer, Customer.FieldNo("Credit Limit (LCY)"), false, false);
        Customer.Get(NumberedNo(1));
        Data.Add('tableId', Database::Customer);
        Data.Add('recordId', Codec.Encode(Customer.RecordId));
        Data.Add('fieldNo', Customer.FieldNo("Credit Limit (LCY)"));
        LibraryAssert.IsFalse(OpReadBlob.Run(Data, Response, Fail, Cost), 'restricted field must fail');
        AssertProblem(Fail, 403, 'field-restricted');
        LibraryAssert.IsTrue(StrPos(Helper.DetailOf(Fail), 'Credit Limit') = 0, 'a restricted field must not be named');
        Helper.UnexposeField(Database::Customer, Customer.FieldNo("Credit Limit (LCY)"));
    end;

    [Test]
    procedure ReadBlobOnUnknownFieldNumberLooksRestricted()
    var
        Customer: Record Customer;
        Data, Response, Fail: JsonObject;
        Cost: Integer;
    begin
        // Unknown and restricted field numbers are indistinguishable (same 403), in every mode.
        Helper.ConfigureOpenMode();
        SeedNumbered(1);
        Customer.Get(NumberedNo(1));
        Data.Add('tableId', Database::Customer);
        Data.Add('recordId', Codec.Encode(Customer.RecordId));
        Data.Add('fieldNo', 1999999);
        LibraryAssert.IsFalse(OpReadBlob.Run(Data, Response, Fail, Cost), 'unknown field must fail');
        AssertProblem(Fail, 403, 'field-restricted');
    end;

    [Test]
    procedure ReadBlobNotBinaryNamesFieldByNumber()
    var
        Customer: Record Customer;
        Data, Response, Fail: JsonObject;
        Cost: Integer;
    begin
        Helper.ConfigureOpenMode();
        SeedNumbered(1);
        Customer.Get(NumberedNo(1));
        Data.Add('tableId', Database::Customer);
        Data.Add('recordId', Codec.Encode(Customer.RecordId));
        Data.Add('fieldNo', Customer.FieldNo(Name));
        LibraryAssert.IsFalse(OpReadBlob.Run(Data, Response, Fail, Cost), 'a readable text field is still not binary');
        AssertProblem(Fail, 400, 'not-binary');
        LibraryAssert.IsTrue(StrPos(Helper.DetailOf(Fail), Format(Customer.FieldNo(Name))) > 0, 'detail names the field by number');
    end;

    [Test]
    procedure ReadBlobJudgesTokenTableBeforeLookingUpTheRecord()
    var
        Vendor: Record Vendor;
        Data, Response, Fail: JsonObject;
        Cost: Integer;
    begin
        // A token for another table answers the same 400 whether or not that record exists — the
        // record is never looked up, so readBlob is no existence oracle for other tables.
        Helper.ConfigureOpenMode();
        SeedNumbered(1);
        Vendor.Init();
        Vendor."No." := 'RPR-NOPE';
        if Vendor.Get(Vendor."No.") then Vendor.Delete();
        Data.Add('tableId', Database::Customer);
        Data.Add('recordId', Codec.Encode(Vendor.RecordId));
        Data.Add('fieldNo', 1);
        LibraryAssert.IsFalse(OpReadBlob.Run(Data, Response, Fail, Cost), 'foreign token must fail');
        AssertProblem(Fail, 400, 'record-table-mismatch');
    end;

    [Test]
    procedure PageUrlJudgesTokenTableBeforeLookingUpTheRecord()
    var
        Vendor: Record Vendor;
        Data, Response, Fail: JsonObject;
        Cost: Integer;
    begin
        Helper.ConfigureOpenMode();
        Vendor.Init();
        Vendor."No." := 'RPR-NOPE';
        if Vendor.Get(Vendor."No.") then Vendor.Delete();
        Data.Add('tableId', Database::Customer);
        Data.Add('recordId', Codec.Encode(Vendor.RecordId));
        LibraryAssert.IsFalse(OpPageUrl.Run(Data, Response, Fail, Cost), 'foreign token must fail');
        AssertProblem(Fail, 400, 'record-table-mismatch');
    end;

    // ---------------------------------------------------------------- describe / discover / capabilities

    [Test]
    procedure DescribeRejectsTooManyLanguages()
    var
        Data, Response, Fail: JsonObject;
        Langs: JsonArray;
        Cost: Integer;
    begin
        Helper.ConfigureOpenMode();
        Langs.Add('ENU');
        Langs.Add('SVE');
        Langs.Add('DEU');
        Langs.Add('FRA');
        Langs.Add('DAN');
        Langs.Add('NLD');
        Data.Add('kind', 'table');
        Data.Add('tableId', Database::Customer);
        Data.Add('languages', Langs);
        LibraryAssert.IsFalse(OpDescribe.Run(Data, Response, Fail, Cost), 'six languages must be refused');
        AssertProblem(Fail, 400, 'invalid-field');
    end;

    [Test]
    procedure DescribeRejectsNonStringLanguageEntry()
    var
        Data, Response, Fail: JsonObject;
        Langs: JsonArray;
        Empty: JsonObject;
        Cost: Integer;
    begin
        // languages:[{}] used to raise inside AsValue() and surface as a 500.
        Helper.ConfigureOpenMode();
        Langs.Add(Empty);
        Data.Add('kind', 'table');
        Data.Add('tableId', Database::Customer);
        Data.Add('languages', Langs);
        LibraryAssert.IsFalse(OpDescribe.Run(Data, Response, Fail, Cost), 'an object entry must be refused');
        AssertProblem(Fail, 400, 'invalid-field');
    end;

    [Test]
    procedure DescribeEmitsInvariantTypeAndClass()
    var
        Data, Response, Fail: JsonObject;
        Fields: JsonArray;
        Tok: JsonToken;
        FieldObj: JsonObject;
        Cost, i: Integer;
        Seen: Boolean;
    begin
        Helper.ConfigureOpenMode();
        Data.Add('kind', 'table');
        Data.Add('tableId', Database::Customer);
        LibraryAssert.IsTrue(OpDescribe.Run(Data, Response, Fail, Cost), 'describe should succeed');
        Helper.ValueObject(Response).Get('fields', Tok);
        Fields := Tok.AsArray();
        for i := 0 to Fields.Count() - 1 do begin
            Fields.Get(i, Tok);
            FieldObj := Tok.AsObject();
            if Helper.TextField(FieldObj, 'name') = 'Credit Limit (LCY)' then begin
                LibraryAssert.AreEqual('Decimal', Helper.TextField(FieldObj, 'type'), 'type is the invariant member name');
                LibraryAssert.AreEqual('Normal', Helper.TextField(FieldObj, 'class'), 'class is the invariant member name');
                Seen := true;
            end;
        end;
        LibraryAssert.IsTrue(Seen, 'Credit Limit (LCY) should be described');
    end;

    [Test]
    procedure DiscoverOpenModeHonoursTheReadDenylist()
    var
        Data, Response, Fail: JsonObject;
        Rows: JsonArray;
        Tok: JsonToken;
        Cost, i: Integer;
    begin
        // Open mode short-circuited IsAllowed, listing the audit/queue tables that query and
        // describe refuse in every mode.
        Helper.ConfigureOpenMode();
        Data.Add('kind', 'tables');
        Data.Add('filter', '*Operation Log*');
        LibraryAssert.IsTrue(OpDiscover.Run(Data, Response, Fail, Cost), 'discover should succeed');
        Rows := Helper.ValueArray(Response);
        for i := 0 to Rows.Count() - 1 do begin
            Rows.Get(i, Tok);
            Tok.AsObject().Get('id', Tok);
            LibraryAssert.AreNotEqual(Database::"Bcmag Operation Log", Tok.AsValue().AsInteger(), 'a denylisted table must not be discoverable');
        end;
    end;

    [Test]
    procedure CapabilitiesExposureModeIsInvariantName()
    var
        Data, Response, Fail: JsonObject;
        Cost: Integer;
    begin
        Helper.ConfigureOpenMode();
        LibraryAssert.IsTrue(OpCapabilities.Run(Data, Response, Fail, Cost), 'capabilities should succeed');
        LibraryAssert.AreEqual('Open', Helper.TextField(Helper.ValueObject(Response), 'exposureMode'), 'exposureMode is the enum member name');
    end;

    // ---------------------------------------------------------------- aggregate

    [Test]
    procedure IntegerSumOverflowIsNeverBlamedOnTheCaller()
    var
        Customer: Record Customer;
        FieldRec: Record Field;
        RecRef: RecordRef;
        Data, Response, Agg: JsonObject;
        SumArr: JsonArray;
        Tok: JsonToken;
        Status: Integer;
    begin
        // Two rows of 2,000,000,000 in an Integer column: the total does not fit the field type.
        // Either the platform computes it (then it must be right) or the op answers 422 — never
        // a 400 that tells the caller their well-formed request was wrong.
        Helper.ConfigureOpenMode();
        SeedNumbered(2);
        FieldRec.SetRange(TableNo, Database::Customer);
        FieldRec.SetRange(Type, FieldRec.Type::Integer);
        FieldRec.SetRange(Class, FieldRec.Class::Normal);
        FieldRec.SetFilter(ObsoleteState, '<>%1', FieldRec.ObsoleteState::Removed);
        FieldRec.SetFilter("No.", '<%1', 2000000000);
        if not FieldRec.FindFirst() then
            exit;
        if Customer.FindSet() then
            repeat
                RecRef.GetTable(Customer);
                RecRef.Field(FieldRec."No.").Value := 2000000000;
                RecRef.Modify();
            until Customer.Next() = 0;

        SumArr.Add(FieldRec.FieldName);
        Agg.Add('sum', SumArr);
        Data.Add('tableId', Database::Customer);
        Data.Add('aggregate', Agg);
        // Through the dispatcher: SQL's SUM over an int column can overflow inside the database, which
        // cancels the command in a way no try function catches. The Run boundary still turns it into a
        // server-side problem (500, retryable) — what must never happen is a 400 blaming the request.
        Helper.CommitFixtures();
        Response := Dispatcher.RunEx('query', Helper.Envelope(Data), '', Status);
        if Status = 200 then begin
            Helper.ValueObject(Response).Get('sum', Tok);
            Tok.AsObject().Get(FieldRec.FieldName, Tok);
            LibraryAssert.AreEqual(4000000000.0, Tok.AsValue().AsDecimal(), 'a computed total must be exact');
            exit;
        end;
        LibraryAssert.IsTrue(Status in [422, 500], StrSubstNo('an overflowing total is a server limit (422/500), got %1 %2', Status, Helper.TypeOf(Response)));
    end;
}
