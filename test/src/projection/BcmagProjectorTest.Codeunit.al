codeunit 94305 "Bcmag Projector Test"
{
    Subtype = Test;
    TestPermissions = Disabled;

    var
        Projector: Codeunit "Bcmag Projector";
        Helper: Codeunit "Bcmag Test Helper";
        LibraryAssert: Codeunit "Library Assert";

    [Test]
    procedure ProjectsSelectedFieldsOnly()
    var
        Customer: Record Customer;
        RecRef: RecordRef;
        Fields: List of [Integer];
        Row: JsonObject;
        Tok: JsonToken;
    begin
        Customer.Init();
        Customer."No." := 'P-1';
        Customer.Name := 'Acme';
        Customer.Address := 'Königstraße 1';
        Customer.Insert();

        RecRef.GetTable(Customer);
        Fields.Add(Customer.FieldNo("No."));
        Fields.Add(Customer.FieldNo(Name));
        Row := Projector.ProjectRow(RecRef, Fields, false, 9007199254740992L);

        LibraryAssert.IsTrue(Row.Get('No.', Tok), 'No. missing');
        LibraryAssert.IsTrue(Row.Get('Name', Tok), 'Name missing');
        LibraryAssert.IsFalse(Row.Get('Address', Tok), 'Address should not appear');
        LibraryAssert.IsTrue(Row.Get('@recordId', Tok), '@recordId missing');
        LibraryAssert.AreNotEqual('', Tok.AsValue().AsText(), '@recordId should be non-empty');
    end;

    [Test]
    procedure OmitsBlobFieldsEvenWhenSelected()
    var
        Customer: Record Customer;
        RecRef: RecordRef;
        Fields: List of [Integer];
        Row: JsonObject;
        Tok: JsonToken;
    begin
        Customer.Init();
        Customer."No." := 'P-2';
        Customer.Insert();
        RecRef.GetTable(Customer);
        Fields.Add(Customer.FieldNo("No."));
        Fields.Add(Customer.FieldNo(Image));
        Row := Projector.ProjectRow(RecRef, Fields, false, 9007199254740992L);

        LibraryAssert.IsFalse(Row.Get('Image', Tok), 'Image (Media) must be omitted');
    end;

    [Test]
    procedure IncludesEtagWhenSystemFieldsPresent()
    var
        Customer: Record Customer;
        RecRef: RecordRef;
        Fields: List of [Integer];
        Row: JsonObject;
        Tok: JsonToken;
    begin
        Customer.Init();
        Customer."No." := 'P-3';
        Customer.Insert();
        RecRef.GetTable(Customer);
        Fields.Add(Customer.FieldNo("No."));
        Row := Projector.ProjectRow(RecRef, Fields, false, 9007199254740992L);
        LibraryAssert.IsTrue(Row.Get('@etag', Tok), '@etag missing');
    end;

    [Test]
    procedure StrongEtagFoldsInFieldValues()
    var
        Customer: Record Customer;
        RecRef: RecordRef;
        WeakEtag, StrongBefore, StrongAfter: Text;
    begin
        // The strong ETag differs from the weak one (it appends a value hash) and shifts when a field
        // value changes — which is what closes the same-millisecond window the weak token cannot.
        Customer.Init();
        Customer."No." := 'P-ETAG';
        Customer.Name := 'Before';
        Customer.Insert();
        RecRef.GetTable(Customer);

        WeakEtag := Projector.EtagOf(RecRef, false);
        StrongBefore := Projector.EtagOf(RecRef, true);
        LibraryAssert.AreNotEqual('', StrongBefore, 'strong etag should be non-empty');
        LibraryAssert.AreNotEqual(WeakEtag, StrongBefore, 'strong etag must differ from the weak one');

        Customer.Name := 'After';
        Customer.Modify();
        RecRef.GetTable(Customer);
        StrongAfter := Projector.EtagOf(RecRef, true);
        LibraryAssert.AreNotEqual(StrongBefore, StrongAfter, 'a field change must shift the strong etag');
    end;

    // ---- masking ---------------------------------------------------------------------------------
    // The tests below run in ByClassification mode with the Unmask tier off (ConfigureOpenMode pins
    // it off: the suite runs as SUPER, which would otherwise hold the tier and lift every mask). Each
    // pins Customer fields with explicit field rows rather than relying on their classification.

    [Test]
    procedure MaskedFieldRendersMaskAndRowNamesIt()
    var
        Customer: Record Customer;
        RecRef: RecordRef;
        Fields: List of [Integer];
        Row: JsonObject;
        Tok: JsonToken;
        Masked: JsonArray;
    begin
        // A Masked verdict emits the mask rendering under the field's own name and lists that name in
        // the row's "@masked" array (the per-row contract replay re-authorization relies on). Clear
        // fields in the same row are untouched. 'Acme Holdings' under keep-last-2 / min-hidden-4 /
        // no length preservation renders as four mask chars + 'gs'.
        PinMaskedName('P-MASK1', 'Acme Holdings', Customer);
        RecRef.GetTable(Customer);
        Fields.Add(Customer.FieldNo("No."));
        Fields.Add(Customer.FieldNo(Name));
        Fields.Add(Customer.FieldNo(Address));
        Row := Projector.ProjectRow(RecRef, Fields, false, 9007199254740992L);

        LibraryAssert.AreEqual('****gs', TextOf(Row, 'Name'), 'Name must carry its mask rendering');
        LibraryAssert.AreEqual('P-MASK1', TextOf(Row, 'No.'), 'the PK stays clear');
        LibraryAssert.AreEqual('Königstraße 1', TextOf(Row, 'Address'), 'a Clear field stays clear');
        LibraryAssert.IsTrue(Row.Get('@masked', Tok), '@masked missing on a row with a masked field');
        Masked := Tok.AsArray();
        LibraryAssert.AreEqual(1, Masked.Count(), '@masked lists exactly the masked fields');
        Masked.Get(0, Tok);
        LibraryAssert.AreEqual('Name', Tok.AsValue().AsText(), '@masked names the field by its row key');
        LibraryAssert.IsTrue(Row.Get('@recordId', Tok), '@recordId must still be present');

        UnpinMaskedName();
    end;

    [Test]
    procedure RowWithoutMaskedFieldsHasNoMarker()
    var
        Customer: Record Customer;
        RecRef: RecordRef;
        Fields: List of [Integer];
        Row: JsonObject;
        Tok: JsonToken;
    begin
        // Name is Masked, but this projection does not select it: nothing in the row is masked, so the
        // row carries no "@masked" member at all (not an empty array).
        PinMaskedName('P-MASK2', 'Acme Holdings', Customer);
        RecRef.GetTable(Customer);
        Fields.Add(Customer.FieldNo("No."));
        Fields.Add(Customer.FieldNo(Address));
        Row := Projector.ProjectRow(RecRef, Fields, false, 9007199254740992L);

        LibraryAssert.IsFalse(Row.Get('@masked', Tok), 'a row without masked fields must not carry @masked');
        LibraryAssert.IsFalse(Row.Get('Name', Tok), 'an unselected field is not projected');

        UnpinMaskedName();
    end;

    [Test]
    procedure MaskedNonTextFieldRendersNull()
    var
        Customer: Record Customer;
        RecRef: RecordRef;
        Fields: List of [Integer];
        Row: JsonObject;
        Tok: JsonToken;
    begin
        // A blank profile is the built-in partial mask, which has no partial form for a number: the
        // value renders as JSON null, and the row still says the field is masked (null alone would
        // be indistinguishable from an empty value).
        Helper.ConfigureOpenMode();
        Helper.SetFieldPolicyMode("Bcmag Field Policy Mode"::ByClassification);
        Helper.SetFieldAccess(Database::Customer, Customer.FieldNo("Credit Limit (LCY)"), "Bcmag Read Access"::Masked, '', false);
        Customer.Init();
        Customer."No." := 'P-MASK3';
        Customer."Credit Limit (LCY)" := 1234.5;
        Customer.Insert();
        RecRef.GetTable(Customer);
        Fields.Add(Customer.FieldNo("No."));
        Fields.Add(Customer.FieldNo("Credit Limit (LCY)"));
        Row := Projector.ProjectRow(RecRef, Fields, false, 9007199254740992L);

        LibraryAssert.IsTrue(Row.Get('Credit Limit (LCY)', Tok), 'the masked field is still emitted');
        LibraryAssert.IsTrue(Tok.AsValue().IsNull(), 'a masked number under the partial mask is null');
        LibraryAssert.IsTrue(MaskedContains(Row, 'Credit Limit (LCY)'), '@masked must name the masked number');

        Helper.UnexposeField(Database::Customer, Customer.FieldNo("Credit Limit (LCY)"));
        Helper.SetFieldPolicyMode("Bcmag Field Policy Mode"::AllFields);
    end;

    [Test]
    procedure ReusedProjectorFollowsPolicyChanges()
    var
        Customer: Record Customer;
        RecRef: RecordRef;
        Fields: List of [Integer];
        Row: JsonObject;
        Tok: JsonToken;
    begin
        // The projector caches verdicts (and its masker caches profiles) per table, and this codeunit
        // holds ONE projector across every call — as the query handler does across requests. A policy
        // write must reach the next projection: an edited profile renders anew, and a field switched
        // back to Clear reads clear with no stale @masked.
        PinMaskedName('P-MASK4', 'Acme Holdings', Customer);
        RecRef.GetTable(Customer);
        Fields.Add(Customer.FieldNo("No."));
        Fields.Add(Customer.FieldNo(Name));
        Row := Projector.ProjectRow(RecRef, Fields, false, 9007199254740992L);
        LibraryAssert.AreEqual('****gs', TextOf(Row, 'Name'), 'first rendering');

        Helper.UpsertMaskProfile('T-LAST2', "Bcmag Mask Kind"::KeepLast, 0, 3, 4, false);
        Row := Projector.ProjectRow(RecRef, Fields, false, 9007199254740992L);
        LibraryAssert.AreEqual('****ngs', TextOf(Row, 'Name'), 'an edited profile must render from the next projection on');

        Helper.SetFieldAccess(Database::Customer, Customer.FieldNo(Name), "Bcmag Read Access"::Clear, '', false);
        Row := Projector.ProjectRow(RecRef, Fields, false, 9007199254740992L);
        LibraryAssert.AreEqual('Acme Holdings', TextOf(Row, 'Name'), 'a field switched to Clear must read clear');
        LibraryAssert.IsFalse(Row.Get('@masked', Tok), 'no stale @masked after the field is Clear');

        UnpinMaskedName();
    end;

    // ByClassification, tier off, profile T-LAST2 = keep last 2 / min hidden 4 / fixed-width run, and a
    // field row making Customer.Name Masked with it; inserts one customer with the given name.
    local procedure PinMaskedName(CustomerNo: Code[20]; CustomerName: Text[100]; var Customer: Record Customer)
    begin
        Helper.ConfigureOpenMode();
        Helper.SetFieldPolicyMode("Bcmag Field Policy Mode"::ByClassification);
        Helper.UpsertMaskProfile('T-LAST2', "Bcmag Mask Kind"::KeepLast, 0, 2, 4, false);
        Helper.SetFieldAccess(Database::Customer, Customer.FieldNo(Name), "Bcmag Read Access"::Masked, 'T-LAST2', false);
        // Address is the Clear control: pinned by a row, so its classification cannot change the test.
        Helper.SetFieldAccess(Database::Customer, Customer.FieldNo(Address), "Bcmag Read Access"::Clear, '', false);
        Customer.Init();
        Customer."No." := CustomerNo;
        Customer.Name := CustomerName;
        Customer.Address := 'Königstraße 1';
        Customer.Insert();
    end;

    local procedure UnpinMaskedName()
    var
        Customer: Record Customer;
    begin
        Helper.UnexposeField(Database::Customer, Customer.FieldNo(Name));
        Helper.UnexposeField(Database::Customer, Customer.FieldNo(Address));
        Helper.SetFieldPolicyMode("Bcmag Field Policy Mode"::AllFields);
    end;

    local procedure TextOf(Row: JsonObject; Name: Text): Text
    var
        Tok: JsonToken;
    begin
        LibraryAssert.IsTrue(Row.Get(Name, Tok), StrSubstNo('"%1" missing from the row', Name));
        exit(Tok.AsValue().AsText());
    end;

    local procedure MaskedContains(Row: JsonObject; Name: Text): Boolean
    var
        Tok, Member: JsonToken;
    begin
        if not Row.Get('@masked', Tok) then
            exit(false);
        foreach Member in Tok.AsArray() do
            if Member.AsValue().AsText() = Name then
                exit(true);
        exit(false);
    end;
}
