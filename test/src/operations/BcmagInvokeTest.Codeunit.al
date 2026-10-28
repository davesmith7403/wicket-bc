codeunit 94317 "Bcmag Invoke Test"
{
    Subtype = Test;
    TestPermissions = Disabled;

    // invoke is deny-by-default: a procedure runs only when enrolled in the Procedure Catalog
    // AND its codeunit is exposed for invoke. We enrol the reference wrapper "Bcmag Wrap Ping"
    // (94190) and assert its result echoes through the Invoke Context channel.

    var
        OpInvoke: Codeunit "Bcmag Op Invoke";
        Helper: Codeunit "Bcmag Test Helper";
        LibraryAssert: Codeunit "Library Assert";

    [Test]
    procedure InvokePingReturnsPongAndEcho()
    var
        Data, Args, Response, Value, Fail: JsonObject;
        Tok: JsonToken;
        Cost: Integer;
    begin
        Helper.ConfigureAllowlistedMode();
        Helper.ExposeCodeunitInvoke(94190);
        Helper.EnrolProcedure(94190, 'Ping', 94190, "Bcmag Return Shape"::json);

        Args.Add('message', 'hi');
        Data.Add('codeunitId', 94190);
        Data.Add('procedure', 'Ping');
        Data.Add('args', Args);

        Helper.CommitFixtures();
        LibraryAssert.IsTrue(OpInvoke.Run(Data, Response, Fail, Cost), 'invoke should succeed');
        Value := Helper.ValueObject(Response);
        LibraryAssert.IsTrue(Value.Get('pong', Tok), 'pong missing');
        LibraryAssert.IsTrue(Tok.AsValue().AsBoolean(), 'pong should be true');
        LibraryAssert.IsTrue(Value.Get('echo', Tok), 'echo missing');
        LibraryAssert.AreEqual('hi', Tok.AsValue().AsText(), 'echo should mirror the message arg');

        Helper.RemoveProcedure(94190, 'Ping');
        Helper.UnexposeCodeunit(94190);
    end;

    [Test]
    procedure InvokeUnexposedCodeunitDenied()
    var
        Data, Args, Response, Fail: JsonObject;
        Cost: Integer;
    begin
        Helper.ConfigureAllowlistedMode();
        Helper.UnexposeCodeunit(94190);
        Helper.RemoveProcedure(94190, 'Ping');

        Args.Add('message', 'hi');
        Data.Add('codeunitId', 94190);
        Data.Add('procedure', 'Ping');
        Data.Add('args', Args);

        LibraryAssert.IsFalse(OpInvoke.Run(Data, Response, Fail, Cost), 'unexposed invoke must be denied');
        LibraryAssert.AreEqual(403, Helper.StatusOf(Fail), 'expected 403 not-exposed');
    end;

    [Test]
    procedure InvokeUnknownProcedureReturns404()
    var
        Data, Response, Fail: JsonObject;
        Cost: Integer;
    begin
        Helper.ConfigureAllowlistedMode();
        Helper.ExposeCodeunitInvoke(94190);
        Helper.RemoveProcedure(94190, 'Nope');

        Data.Add('codeunitId', 94190);
        Data.Add('procedure', 'Nope');
        LibraryAssert.IsFalse(OpInvoke.Run(Data, Response, Fail, Cost), 'unknown procedure must be rejected');
        LibraryAssert.AreEqual(404, Helper.StatusOf(Fail), 'expected 404 unknown-procedure');

        Helper.UnexposeCodeunit(94190);
    end;
}
