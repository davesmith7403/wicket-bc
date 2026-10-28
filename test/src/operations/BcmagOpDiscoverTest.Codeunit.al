codeunit 94310 "Bcmag Op Discover Test"
{
    Subtype = Test;
    TestPermissions = Disabled;

    var
        Op: Codeunit "Bcmag Op Discover";
        Helper: Codeunit "Bcmag Test Helper";
        LibraryAssert: Codeunit "Library Assert";

    [Test]
    procedure DiscoverTablesReturnsCustomer()
    var
        Data, Response, Fail: JsonObject;
        Tok: JsonToken;
        Value: JsonArray;
        Found: Boolean;
        Cost, i: Integer;
        Row: JsonObject;
        IdTok: JsonToken;
    begin
        Helper.ConfigureOpenMode();
        Data.Add('kind', 'tables');
        Data.Add('filter', 'Customer');     // AL filter: exact-match substring
        Data.Add('top', 50);
        LibraryAssert.IsTrue(Op.Run(Data, Response, Fail, Cost), 'discover should succeed');
        LibraryAssert.IsTrue(Response.Get('value', Tok), 'value missing');
        Value := Tok.AsArray();
        for i := 0 to Value.Count() - 1 do begin
            Value.Get(i, Tok);
            Row := Tok.AsObject();
            Row.Get('id', IdTok);
            if IdTok.AsValue().AsInteger() = Database::Customer then
                Found := true;
        end;
        LibraryAssert.IsTrue(Found, 'expected Customer in results');
    end;

    [Test]
    procedure DiscoverRejectsUnknownKind()
    var
        Data, Response, Fail: JsonObject;
        Cost: Integer;
    begin
        Data.Add('kind', 'aliens');
        LibraryAssert.IsFalse(Op.Run(Data, Response, Fail, Cost), 'should reject');
        LibraryAssert.AreEqual(400, Helper.StatusOf(Fail), 'expected 400');
        LibraryAssert.IsTrue(StrPos(Helper.DetailOf(Fail), 'kind') > 0, 'detail should mention kind');
    end;
}
