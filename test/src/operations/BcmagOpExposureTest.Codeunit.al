codeunit 94314 "Bcmag Exposure Test"
{
    Subtype = Test;
    TestPermissions = Disabled;

    var
        Op: Codeunit "Bcmag Op Query";
        Helper: Codeunit "Bcmag Test Helper";
        LibraryAssert: Codeunit "Library Assert";

    local procedure SeedOne()
    var
        Customer: Record Customer;
    begin
        if not Customer.Get('EXP-1') then begin
            Customer.Init();
            Customer."No." := 'EXP-1';
            Customer.Insert();
        end;
    end;

    [Test]
    procedure AllowlistedWithoutRowDeniesQuery()
    var
        Data, Response, Fail: JsonObject;
        Cost: Integer;
    begin
        Helper.ConfigureAllowlistedMode();
        Helper.UnexposeTable(Database::Customer);
        SeedOne();

        Data.Add('tableId', Database::Customer);
        LibraryAssert.IsFalse(Op.Run(Data, Response, Fail, Cost), 'unexposed table must be denied');
        LibraryAssert.AreEqual(403, Helper.StatusOf(Fail), 'expected 403 not-exposed');
    end;

    [Test]
    procedure AllowReadGrantsQuery()
    var
        Data, Response, Fail: JsonObject;
        Tok: JsonToken;
        Cost: Integer;
    begin
        Helper.ConfigureAllowlistedMode();
        Helper.ExposeTable(Database::Customer, true, false, false, false);
        SeedOne();

        Data.Add('tableId', Database::Customer);
        Data.Add('top', 1);
        LibraryAssert.IsTrue(Op.Run(Data, Response, Fail, Cost), 'Allow Read should grant query');
        LibraryAssert.IsTrue(Response.Get('value', Tok), 'value missing on granted query');

        Helper.UnexposeTable(Database::Customer);
    end;

    [Test]
    procedure OpenModeStillDeniesReadOfAuditTables()
    var
        Data, Response, Fail: JsonObject;
        Cost: Integer;
    begin
        // The Idempotency Log stores every idempotent write's full response body, keyed by caller;
        // the Request Queue stores each caller's query and package URL. Neither may be read through
        // the generic data plane in ANY mode — otherwise Open mode (or a careless exposure row) would
        // let one principal read across all the others.
        Helper.ConfigureOpenMode();
        Data.Add('tableId', Database::"Bcmag Idempotency Log");
        LibraryAssert.IsFalse(Op.Run(Data, Response, Fail, Cost), 'the idempotency log must not be readable through query');
        LibraryAssert.AreEqual(403, Helper.StatusOf(Fail), 'expected 403 not-exposed');

        Clear(Data);
        Clear(Fail);
        Data.Add('tableId', Database::"Bcmag Request Queue");
        LibraryAssert.IsFalse(Op.Run(Data, Response, Fail, Cost), 'the request queue must not be readable through query');
        LibraryAssert.AreEqual(403, Helper.StatusOf(Fail), 'expected 403 not-exposed');

        // The Operation Log names every caller; the Idempotency Reservation pairs each caller's
        // security id with their keys, body hashes and in-flight state. Both are cross-principal
        // metadata, so the same hard denial applies — the guard's own (caller-scoped) lookup is the
        // only read path for reservations.
        Clear(Data);
        Clear(Fail);
        Data.Add('tableId', Database::"Bcmag Operation Log");
        LibraryAssert.IsFalse(Op.Run(Data, Response, Fail, Cost), 'the operation log must not be readable through query');
        LibraryAssert.AreEqual(403, Helper.StatusOf(Fail), 'expected 403 not-exposed');

        Clear(Data);
        Clear(Fail);
        Data.Add('tableId', Database::"Bcmag Idempotency Reservation");
        LibraryAssert.IsFalse(Op.Run(Data, Response, Fail, Cost), 'the idempotency reservation must not be readable through query');
        LibraryAssert.AreEqual(403, Helper.StatusOf(Fail), 'expected 403 not-exposed');
        LibraryAssert.IsTrue(StrPos(Helper.TypeOf(Fail), 'not-exposed') > 0, 'the denial is the ordinary not-exposed problem (no table-existence oracle)');
    end;

    [Test]
    procedure OpenModeDeniesReadOfFieldPolicyRowsButNotPublishedPolicy()
    var
        Data, Response, Fail: JsonObject;
        Cost: Integer;
    begin
        // Access Exception rows are per-principal grants (user, field, free-text Reason): another
        // principal's data, denied like the audit tables. Field Exposure rows name every hidden field,
        // which describe deliberately keeps indistinguishable from a nonexistent one. Both stay denied
        // in Open mode.
        Helper.ConfigureOpenMode();
        Data.Add('tableId', Database::"Bcmag Access Exception");
        LibraryAssert.IsFalse(Op.Run(Data, Response, Fail, Cost), 'access exceptions must not be readable through query');
        LibraryAssert.AreEqual(403, Helper.StatusOf(Fail), 'expected 403 not-exposed');
        LibraryAssert.IsTrue(StrPos(Helper.TypeOf(Fail), 'not-exposed') > 0, 'the ordinary not-exposed problem');

        Clear(Data);
        Clear(Fail);
        Data.Add('tableId', Database::"Bcmag Field Exposure");
        LibraryAssert.IsFalse(Op.Run(Data, Response, Fail, Cost), 'field exposure rows must not be readable through query');
        LibraryAssert.AreEqual(403, Helper.StatusOf(Fail), 'expected 403 not-exposed');

        // Rules and profiles are published by capabilities to every caller, so they stay readable.
        Clear(Data);
        Clear(Fail);
        Clear(Response);
        Data.Add('tableId', Database::"Bcmag Mask Profile");
        LibraryAssert.IsTrue(Op.Run(Data, Response, Fail, Cost), 'mask profiles stay readable');

        Clear(Data);
        Clear(Fail);
        Clear(Response);
        Data.Add('tableId', Database::"Bcmag Classification Rule");
        LibraryAssert.IsTrue(Op.Run(Data, Response, Fail, Cost), 'classification rules stay readable');
    end;
}
