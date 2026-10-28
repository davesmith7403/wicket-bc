codeunit 94312 "Bcmag Op Query Test"
{
    Subtype = Test;
    TestPermissions = Disabled;

    var
        Op: Codeunit "Bcmag Op Query";
        Helper: Codeunit "Bcmag Test Helper";
        LibraryAssert: Codeunit "Library Assert";

    local procedure SeedCustomers()
    var
        Customer: Record Customer;
    begin
        if not Customer.IsEmpty() then Customer.DeleteAll();
        Customer.Init(); Customer."No." := 'Q-1'; Customer.Name := 'Acme';     Customer.Insert();
        Customer.Init(); Customer."No." := 'Q-2'; Customer.Name := 'Beta Ltd'; Customer.Insert();
        Customer.Init(); Customer."No." := 'Q-3'; Customer.Name := 'Acme Two'; Customer.Insert();
    end;

    [Test]
    procedure QueryReturnsSelectedFields()
    var
        Data, Response, Fail: JsonObject;
        Select: JsonArray;
        Tok: JsonToken;
        Value: JsonArray;
        Cost: Integer;
    begin
        Helper.ConfigureOpenMode();
        SeedCustomers();
        Select.Add('No.'); Select.Add('Name');
        Data.Add('tableId', Database::Customer);
        Data.Add('select', Select);
        Data.Add('filter', 'startswith(Name, ''Ac'')');
        Data.Add('top', 10);
        LibraryAssert.IsTrue(Op.Run(Data, Response, Fail, Cost), StrSubstNo('query should succeed: %1', Helper.DetailOf(Fail)));
        LibraryAssert.IsTrue(Response.Get('value', Tok), 'value missing');
        Value := Tok.AsArray();
        LibraryAssert.AreEqual(2, Value.Count(), 'expected 2 Acme rows');
    end;

    [Test]
    procedure QueryRowsCarryRecordId()
    var
        Data, Response, Fail: JsonObject;
        Tok: JsonToken;
        Value: JsonArray;
        Row: JsonObject;
        Cost, i: Integer;
    begin
        Helper.ConfigureOpenMode();
        SeedCustomers();
        Data.Add('tableId', Database::Customer);
        Data.Add('top', 10);
        LibraryAssert.IsTrue(Op.Run(Data, Response, Fail, Cost), 'query should succeed');
        Value := Helper.ValueArray(Response);
        LibraryAssert.IsTrue(Value.Count() >= 3, 'expected at least 3 rows');
        for i := 0 to Value.Count() - 1 do begin
            Value.Get(i, Tok);
            Row := Tok.AsObject();
            LibraryAssert.IsTrue(Row.Get('@recordId', Tok), '@recordId missing on row');
            LibraryAssert.AreNotEqual('', Tok.AsValue().AsText(), '@recordId should be non-empty');
        end;
    end;

    [Test]
    procedure QueryRejectsBothSelectAndSelectFieldNo()
    var
        Data, Response, Fail: JsonObject;
        Sel, SelNo: JsonArray;
        Cost: Integer;
    begin
        Helper.ConfigureOpenMode();
        Sel.Add('No.');
        SelNo.Add(1);
        Data.Add('tableId', Database::Customer);
        Data.Add('select', Sel);
        Data.Add('selectFieldNo', SelNo);
        LibraryAssert.IsFalse(Op.Run(Data, Response, Fail, Cost), 'should reject');
        LibraryAssert.AreEqual(400, Helper.StatusOf(Fail), 'expected 400');
        LibraryAssert.IsTrue(StrPos(Helper.DetailOf(Fail), 'select') > 0, 'detail mentions select');
    end;

    [Test]
    procedure QueryReturnsOnlyPkWhenSelectOmitted()
    var
        Data, Response, Fail: JsonObject;
        Tok: JsonToken;
        Value: JsonArray;
        First: JsonObject;
        FirstTok: JsonToken;
        Cost: Integer;
    begin
        Helper.ConfigureOpenMode();
        SeedCustomers();
        Data.Add('tableId', Database::Customer);
        Data.Add('top', 1);
        LibraryAssert.IsTrue(Op.Run(Data, Response, Fail, Cost), 'query should succeed');
        Value := Helper.ValueArray(Response);
        Value.Get(0, FirstTok);
        First := FirstTok.AsObject();
        LibraryAssert.IsTrue(First.Get('No.', Tok), 'No. (PK) expected');
        LibraryAssert.IsFalse(First.Get('Name', Tok), 'Name should not be present');
    end;

    [Test]
    procedure QueryStarSelectReturnsAllScalarFields()
    var
        Data, Response, Fail: JsonObject;
        Select: JsonArray;
        Tok: JsonToken;
        Value: JsonArray;
        First: JsonObject;
        FirstTok: JsonToken;
        Cost: Integer;
    begin
        // ["*"] expands to every scalar field, so a non-PK field like Name must come back
        // while binary fields (Customer.Image is Media) stay excluded from the expansion.
        Helper.ConfigureOpenMode();
        SeedCustomers();
        Select.Add('*');
        Data.Add('tableId', Database::Customer);
        Data.Add('select', Select);
        Data.Add('top', 1);
        LibraryAssert.IsTrue(Op.Run(Data, Response, Fail, Cost), 'star select should succeed');
        Value := Helper.ValueArray(Response);
        LibraryAssert.IsTrue(Value.Count() >= 1, 'expected at least 1 row');
        Value.Get(0, FirstTok);
        First := FirstTok.AsObject();
        LibraryAssert.IsTrue(First.Get('Name', Tok), 'Name (non-PK) expected under "*"');
        LibraryAssert.IsFalse(First.Get('Image', Tok), 'Image (Media) must be excluded from "*"');
    end;

    [Test]
    procedure QueryStarSelectMustBeAlone()
    var
        Data, Response, Fail: JsonObject;
        Select: JsonArray;
        Cost: Integer;
    begin
        Helper.ConfigureOpenMode();
        SeedCustomers();
        Select.Add('*'); Select.Add('Name');
        Data.Add('tableId', Database::Customer);
        Data.Add('select', Select);
        LibraryAssert.IsFalse(Op.Run(Data, Response, Fail, Cost), 'should reject "*" mixed with fields');
        LibraryAssert.AreEqual(400, Helper.StatusOf(Fail), 'expected 400');
        LibraryAssert.IsTrue(StrPos(Helper.DetailOf(Fail), '*') > 0, 'detail mentions "*"');
    end;

    [Test]
    procedure QueryStarSelectRespectsMaxSelectFields()
    var
        Data, Response, Fail: JsonObject;
        Select: JsonArray;
        Cost: Integer;
    begin
        // CapArray sees a 1-entry literal array, so only the post-expansion count can trip
        // the limit; with Max Select Fields = 1 the Customer expansion must return 413.
        Helper.ConfigureOpenMode();
        SeedCustomers();
        Helper.SetMaxSelectFields(1);
        Select.Add('*');
        Data.Add('tableId', Database::Customer);
        Data.Add('select', Select);
        LibraryAssert.IsFalse(Op.Run(Data, Response, Fail, Cost), 'expansion beyond the limit should reject');
        LibraryAssert.AreEqual(413, Helper.StatusOf(Fail), 'expected 413');
        Helper.SetMaxSelectFields(256);
    end;

    [Test]
    procedure QueryModifiedWindowFiltersRows()
    var
        Data, Response, Fail: JsonObject;
        Cost: Integer;
    begin
        // Deterministic without racing the platform clock: SystemModifiedAt is stamped "now"
        // on insert, so a window entirely in the past excludes everything and a modifiedAfter
        // entirely in the past includes everything.
        Helper.ConfigureOpenMode();
        SeedCustomers();
        Data.Add('tableId', Database::Customer);
        Data.Add('modifiedAfter', '2000-01-01T00:00:00Z');
        Data.Add('top', 10);
        LibraryAssert.IsTrue(Op.Run(Data, Response, Fail, Cost), 'query with past modifiedAfter should succeed');
        LibraryAssert.AreEqual(3, Helper.ValueArray(Response).Count(), 'past modifiedAfter should include all rows');

        Clear(Data); Clear(Response); Clear(Fail);
        Data.Add('tableId', Database::Customer);
        Data.Add('modifiedBefore', '2000-01-01T00:00:00Z');
        Data.Add('top', 10);
        LibraryAssert.IsTrue(Op.Run(Data, Response, Fail, Cost), 'query with past modifiedBefore should succeed');
        LibraryAssert.AreEqual(0, Helper.ValueArray(Response).Count(), 'past modifiedBefore should exclude all rows');
    end;

    [Test]
    procedure QueryModifiedWindowRejectsFilterConflict()
    var
        Data, Response, Fail: JsonObject;
        Cost: Integer;
    begin
        // A caller filter already constraining SystemModifiedAt (here via #2000000003) must be a
        // hard 400: SetRange on the same FieldRef would REPLACE the filter and silently widen.
        Helper.ConfigureOpenMode();
        SeedCustomers();
        Data.Add('tableId', Database::Customer);
        Data.Add('filter', '#2000000003 ge 2000-01-01T00:00:00Z');
        Data.Add('modifiedAfter', '2001-01-01T00:00:00Z');
        LibraryAssert.IsFalse(Op.Run(Data, Response, Fail, Cost), 'conflicting SystemModifiedAt constraints should reject');
        LibraryAssert.AreEqual(400, Helper.StatusOf(Fail), 'expected 400');
        LibraryAssert.IsTrue(StrPos(Helper.DetailOf(Fail), 'SystemModifiedAt') > 0, 'detail names SystemModifiedAt');
    end;

    [Test]
    procedure QueryModifiedWindowRejectsBadDatetime()
    var
        Data, Response, Fail: JsonObject;
        Cost: Integer;
    begin
        Helper.ConfigureOpenMode();
        SeedCustomers();
        Data.Add('tableId', Database::Customer);
        Data.Add('modifiedAfter', 'not-a-datetime');
        LibraryAssert.IsFalse(Op.Run(Data, Response, Fail, Cost), 'unparseable modifiedAfter should reject');
        LibraryAssert.AreEqual(400, Helper.StatusOf(Fail), 'expected 400');
        LibraryAssert.IsTrue(StrPos(Helper.DetailOf(Fail), 'modifiedAfter') > 0, 'detail names the member');
    end;

    // ---- masked fields ---------------------------------------------------------------------------

    [Test]
    procedure QueryEmitsMaskedValueWithRowMarker()
    var
        Data, Response, Fail, Row: JsonObject;
        Select, Masked: JsonArray;
        Tok: JsonToken;
        Value: JsonArray;
        Cost: Integer;
    begin
        // End to end through the query handler: a field row making Name Masked (keep last 2) returns
        // the mask rendering, not the value, and the row names the field in "@masked".
        // 'Beta Ltd' = 8 chars, keep 2, 6 hidden (>= min 4) → four mask chars + 'td'.
        PinMaskedName();
        Select.Add('No.');
        Select.Add('Name');
        Data.Add('tableId', Database::Customer);
        Data.Add('select', Select);
        Data.Add('filter', '"No." eq ''Q-2''');
        LibraryAssert.IsTrue(Op.Run(Data, Response, Fail, Cost), StrSubstNo('query should succeed: %1', Helper.DetailOf(Fail)));
        Value := Helper.ValueArray(Response);
        LibraryAssert.AreEqual(1, Value.Count(), 'expected the Q-2 row');
        Value.Get(0, Tok);
        Row := Tok.AsObject();
        LibraryAssert.AreEqual('****td', Helper.TextField(Row, 'Name'), 'Name must be its mask rendering');
        LibraryAssert.AreEqual('Q-2', Helper.TextField(Row, 'No.'), 'the PK stays clear');
        LibraryAssert.IsTrue(Row.Get('@masked', Tok), '@masked missing');
        Masked := Tok.AsArray();
        LibraryAssert.AreEqual(1, Masked.Count(), '@masked lists exactly the masked fields');
        Masked.Get(0, Tok);
        LibraryAssert.AreEqual('Name', Tok.AsValue().AsText(), '@masked names Name');

        // The same table without the masked field selected: no marker on any row.
        Clear(Data);
        Clear(Select);
        Clear(Response);
        Select.Add('No.');
        Data.Add('tableId', Database::Customer);
        Data.Add('select', Select);
        Data.Add('top', 10);
        LibraryAssert.IsTrue(Op.Run(Data, Response, Fail, Cost), 'PK-only query should succeed');
        Value := Helper.ValueArray(Response);
        LibraryAssert.AreEqual(3, Value.Count(), 'expected the three seeded rows');
        foreach Tok in Value do
            LibraryAssert.IsFalse(Tok.AsObject().Contains('@masked'), 'a row without masked fields must not carry @masked');

        UnpinMaskedName();
    end;

    [Test]
    procedure StarSelectIncludesMaskedFieldMasked()
    var
        Data, Response, Fail, Row: JsonObject;
        Select: JsonArray;
        Tok, Member: JsonToken;
        Value: JsonArray;
        Cost: Integer;
        Listed: Boolean;
    begin
        // "*" means every field the caller may read, and a Masked field IS readable: it is expanded,
        // emitted masked and listed in @masked (other fields may be masked too by their classification,
        // so only membership is asserted).
        PinMaskedName();
        Select.Add('*');
        Data.Add('tableId', Database::Customer);
        Data.Add('select', Select);
        Data.Add('filter', '"No." eq ''Q-2''');
        LibraryAssert.IsTrue(Op.Run(Data, Response, Fail, Cost), StrSubstNo('"*" query should succeed: %1', Helper.DetailOf(Fail)));
        Value := Helper.ValueArray(Response);
        LibraryAssert.AreEqual(1, Value.Count(), 'expected the Q-2 row');
        Value.Get(0, Tok);
        Row := Tok.AsObject();
        LibraryAssert.AreEqual('****td', Helper.TextField(Row, 'Name'), '"*" must emit the masked field masked');
        LibraryAssert.IsTrue(Row.Get('@masked', Tok), '@masked missing');
        foreach Member in Tok.AsArray() do
            if Member.AsValue().AsText() = 'Name' then
                Listed := true;
        LibraryAssert.IsTrue(Listed, '@masked must list Name');

        UnpinMaskedName();
    end;

    // ByClassification with the Unmask tier off (ConfigureOpenMode; the suite runs as SUPER, which
    // would otherwise lift the mask), profile T-LAST2 = keep last 2 / min hidden 4 / fixed-width run,
    // and a field row making Customer.Name Masked with it.
    local procedure PinMaskedName()
    var
        Customer: Record Customer;
    begin
        Helper.ConfigureOpenMode();
        SeedCustomers();
        Helper.SetFieldPolicyMode("Bcmag Field Policy Mode"::ByClassification);
        Helper.UpsertMaskProfile('T-LAST2', "Bcmag Mask Kind"::KeepLast, 0, 2, 4, false);
        Helper.SetFieldAccess(Database::Customer, Customer.FieldNo(Name), "Bcmag Read Access"::Masked, 'T-LAST2', false);
    end;

    local procedure UnpinMaskedName()
    var
        Customer: Record Customer;
    begin
        Helper.UnexposeField(Database::Customer, Customer.FieldNo(Name));
        Helper.SetFieldPolicyMode("Bcmag Field Policy Mode"::AllFields);
    end;
}
