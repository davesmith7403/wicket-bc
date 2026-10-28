codeunit 94309 "Bcmag Op PageUrl WhoAmI Test"
{
    Subtype = Test;
    TestPermissions = Disabled;

    var
        OpPageUrl: Codeunit "Bcmag Op Page Url";
        OpWhoAmI: Codeunit "Bcmag Op Who Am I";
        Helper: Codeunit "Bcmag Test Helper";
        LibraryAssert: Codeunit "Library Assert";

    [Test]
    procedure PageUrlDeniedWhenTableNotExposed()
    var
        Data, Response, Fail: JsonObject;
        Cost: Integer;
    begin
        // Deterministic exposure gate: in Allowlisted mode with no enrolment row, Customer is
        // not readable, and pageUrl must fail exactly like query does (a page URL leaks record
        // existence) — before any record resolution, so a bogus systemId never matters.
        Helper.ConfigureAllowlistedMode();
        // The company may carry a real exposure row for Customer; remove it for this test (rolled back).
        Helper.UnexposeTable(Database::Customer);
        Data.Add('tableId', Database::Customer);
        Data.Add('systemId', 'ffffffff-ffff-ffff-ffff-ffffffffffff');
        LibraryAssert.IsFalse(OpPageUrl.Run(Data, Response, Fail, Cost), 'pageUrl on an unexposed table should reject');
        LibraryAssert.AreEqual(403, Helper.StatusOf(Fail), 'expected 403');
        LibraryAssert.IsTrue(StrPos(Helper.TypeOf(Fail), 'not-exposed') > 0, 'expected not-exposed');
    end;

    [Test]
    procedure PageUrlReturnsUrlAndPageId()
    var
        Customer: Record Customer;
        Data, Response, Fail: JsonObject;
        Tok: JsonToken;
        Value: JsonObject;
        Cost: Integer;
    begin
        Helper.ConfigureOpenMode();
        if not Customer.IsEmpty() then Customer.DeleteAll();
        Customer.Init();
        Customer."No." := 'PU-1';
        Customer.Name := 'Page Url Target';
        Customer.Insert();

        Data.Add('tableId', Database::Customer);
        Data.Add('systemId', LowerCase(DelChr(Format(Customer.SystemId), '<>', '{}')));
        LibraryAssert.IsTrue(OpPageUrl.Run(Data, Response, Fail, Cost), 'pageUrl should succeed: ' + Helper.DetailOf(Fail));
        LibraryAssert.IsTrue(Response.Get('value', Tok), 'value missing');
        Value := Tok.AsObject();
        LibraryAssert.IsTrue(Value.Get('pageUrl', Tok), 'pageUrl missing');
        LibraryAssert.AreNotEqual('', Tok.AsValue().AsText(), 'pageUrl should be non-empty');
        LibraryAssert.IsTrue(Value.Get('pageId', Tok), 'pageId missing');
        LibraryAssert.IsTrue(Tok.AsValue().AsInteger() > 0, 'pageId should be positive');
    end;

    [Test]
    procedure PageUrlUnknownSystemIdIs404()
    var
        Data, Response, Fail: JsonObject;
        Cost: Integer;
    begin
        Helper.ConfigureOpenMode();
        Data.Add('tableId', Database::Customer);
        Data.Add('systemId', 'ffffffff-ffff-ffff-ffff-ffffffffffff');
        LibraryAssert.IsFalse(OpPageUrl.Run(Data, Response, Fail, Cost), 'unknown systemId should reject');
        LibraryAssert.AreEqual(404, Helper.StatusOf(Fail), 'expected 404');
    end;

    [Test]
    procedure WhoAmIReturnsAllMembers()
    var
        Data, Response, Fail: JsonObject;
        Tok: JsonToken;
        Value: JsonObject;
        Cost: Integer;
    begin
        Helper.ConfigureOpenMode(); // Unmask tier off
        Helper.SetReadOnlyMode(false);
        Helper.ClearUserExceptions();
        LibraryAssert.IsTrue(OpWhoAmI.Run(Data, Response, Fail, Cost), 'whoAmI should succeed');
        LibraryAssert.IsTrue(Response.Get('value', Tok), 'value missing');
        Value := Tok.AsObject();
        LibraryAssert.IsTrue(Value.Get('userSecurityId', Tok), 'userSecurityId missing');
        LibraryAssert.AreNotEqual('', Tok.AsValue().AsText(), 'userSecurityId should be non-empty');
        LibraryAssert.IsTrue(Value.Get('userId', Tok), 'userId missing');
        LibraryAssert.IsTrue(Value.Get('company', Tok), 'company missing');
        LibraryAssert.AreEqual(CompanyName(), Tok.AsValue().AsText(), 'company should match');
        LibraryAssert.IsTrue(Value.Get('readOnly', Tok), 'readOnly missing');
        LibraryAssert.IsFalse(Tok.AsValue().AsBoolean(), 'readOnly should be false in open mode');
        LibraryAssert.IsTrue(Value.Get('fieldPolicy', Tok), 'fieldPolicy missing');
        LibraryAssert.AreEqual('AllFields', Tok.AsValue().AsText(), 'fieldPolicy should be the invariant mode name');
        LibraryAssert.IsTrue(Value.Get('unmaskGranted', Tok), 'unmaskGranted missing');
        LibraryAssert.IsFalse(Tok.AsValue().AsBoolean(), 'a disabled Unmask tier is never granted');
        LibraryAssert.IsTrue(Value.Get('activeExceptions', Tok), 'activeExceptions missing');
        LibraryAssert.AreEqual(0, Tok.AsValue().AsInteger(), 'no active exceptions for the caller');
        LibraryAssert.IsTrue(Value.Get('strongEtag', Tok), 'strongEtag missing');
        LibraryAssert.IsTrue(Value.Get('serverTime', Tok), 'serverTime missing');
        LibraryAssert.AreNotEqual('', Tok.AsValue().AsText(), 'serverTime should be non-empty');
    end;
}
