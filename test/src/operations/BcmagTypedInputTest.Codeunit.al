codeunit 94324 "Bcmag Typed Input Test"
{
    // Wrong-typed `data` members must come back as a typed 400 'invalid-field', never as the
    // synthesised 500 the Codeunit.Run boundary produces when AsValue() raises. These tests pin
    // that contract on the shapes an LLM agent actually gets wrong: a string where a number goes,
    // an object where a scalar goes, and a null standing in for "omit".
    // Also covers the inverted modified-window, which used to select nothing silently.

    Subtype = Test;
    TestPermissions = Disabled;

    var
        OpQuery: Codeunit "Bcmag Op Query";
        OpPageUrl: Codeunit "Bcmag Op Page Url";
        Helper: Codeunit "Bcmag Test Helper";
        LibraryAssert: Codeunit "Library Assert";

    [Test]
    procedure StringTableIdIsTypedBadRequest()
    var
        Data, Response, Fail: JsonObject;
        Cost: Integer;
    begin
        Helper.ConfigureOpenMode();
        Data.Add('tableId', 'eighteen');
        LibraryAssert.IsFalse(OpQuery.Run(Data, Response, Fail, Cost), 'a non-numeric tableId should reject');
        LibraryAssert.AreEqual(400, Helper.StatusOf(Fail), 'expected 400, not a synthesised 500');
        LibraryAssert.IsTrue(StrPos(Helper.TypeOf(Fail), 'invalid-field') > 0, 'expected invalid-field');
    end;

    [Test]
    procedure ObjectTopIsTypedBadRequest()
    var
        Data, Response, Fail: JsonObject;
        Nested: JsonObject;
        Cost: Integer;
    begin
        Helper.ConfigureOpenMode();
        Nested.Add('value', 10);
        Data.Add('tableId', Database::Customer);
        Data.Add('top', Nested);
        LibraryAssert.IsFalse(OpQuery.Run(Data, Response, Fail, Cost), 'an object-valued top should reject');
        LibraryAssert.AreEqual(400, Helper.StatusOf(Fail), 'expected 400');
        LibraryAssert.IsTrue(StrPos(Helper.TypeOf(Fail), 'invalid-field') > 0, 'expected invalid-field');
    end;

    [Test]
    procedure NullCountIsTypedBadRequest()
    var
        Data, Response, Fail: JsonObject;
        NullValue: JsonValue;
        Cost: Integer;
    begin
        // A caller that means "omit" should omit; a null reaching AsBoolean() used to raise.
        Helper.ConfigureOpenMode();
        NullValue.SetValueToNull();
        Data.Add('tableId', Database::Customer);
        Data.Add('count', NullValue);
        LibraryAssert.IsFalse(OpQuery.Run(Data, Response, Fail, Cost), 'a null count should reject');
        LibraryAssert.AreEqual(400, Helper.StatusOf(Fail), 'expected 400');
    end;

    [Test]
    procedure StringPageIdIsTypedBadRequest()
    var
        Customer: Record Customer;
        Data, Response, Fail: JsonObject;
        Cost: Integer;
    begin
        // A real record: pageUrl locates the record before it parses pageId, so a bogus
        // systemId would 404 before the coercion this test is about is ever reached.
        Helper.ConfigureOpenMode();
        if not Customer.IsEmpty() then Customer.DeleteAll();
        Customer.Init();
        Customer."No." := 'PU-2';
        Customer.Insert();
        Data.Add('tableId', Database::Customer);
        Data.Add('systemId', LowerCase(DelChr(Format(Customer.SystemId), '<>', '{}')));
        Data.Add('pageId', 'twenty-one');
        LibraryAssert.IsFalse(OpPageUrl.Run(Data, Response, Fail, Cost), 'a non-numeric pageId should reject');
        LibraryAssert.AreEqual(400, Helper.StatusOf(Fail), 'expected 400');
        LibraryAssert.IsTrue(StrPos(Helper.TypeOf(Fail), 'invalid-field') > 0, 'expected invalid-field');
    end;

    [Test]
    procedure InvertedModifiedWindowIsRejected()
    var
        Data, Response, Fail: JsonObject;
        Cost: Integer;
    begin
        // Silently returning zero rows here makes a sync client advance its watermark past
        // records it never saw.
        Helper.ConfigureOpenMode();
        Data.Add('tableId', Database::Customer);
        Data.Add('modifiedAfter', '2026-06-01T00:00:00Z');
        Data.Add('modifiedBefore', '2026-01-01T00:00:00Z');
        LibraryAssert.IsFalse(OpQuery.Run(Data, Response, Fail, Cost), 'an inverted window should reject');
        LibraryAssert.AreEqual(400, Helper.StatusOf(Fail), 'expected 400');
        LibraryAssert.IsTrue(StrPos(Helper.TypeOf(Fail), 'invalid-field') > 0, 'expected invalid-field');
    end;

    [Test]
    procedure OrderedModifiedWindowIsAccepted()
    var
        Data, Response, Fail: JsonObject;
        Cost: Integer;
    begin
        // The guard must not reject the legitimate window it sits next to.
        Helper.ConfigureOpenMode();
        Data.Add('tableId', Database::Customer);
        Data.Add('modifiedAfter', '2026-01-01T00:00:00Z');
        Data.Add('modifiedBefore', '2026-06-01T00:00:00Z');
        LibraryAssert.IsTrue(OpQuery.Run(Data, Response, Fail, Cost), 'an ordered window should succeed: ' + Helper.DetailOf(Fail));
    end;
}
