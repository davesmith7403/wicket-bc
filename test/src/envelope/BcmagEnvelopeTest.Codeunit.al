codeunit 94301 "Bcmag Envelope Test"
{
    Subtype = Test;
    TestPermissions = Disabled;

    var
        Envelope: Codeunit "Bcmag Envelope";
        LibraryAssert: Codeunit "Library Assert";

    [Test]
    procedure ParseAcceptsValidEnvelope()
    var
        Body, Data: JsonObject;
        Id, Origin, ErrorMsg: Text;
        IssuedAt: DateTime;
    begin
        Body.Add('id',       '8e2f3c7e-5b41-4f3a-8e99-5b9e9b8f2a11');
        Body.Add('issuedAt', '2026-05-08T12:34:56.789Z');
        Body.Add('origin',   'contoso.web/checkout@v3.2.1');
        Body.Add('data',     Data);

        LibraryAssert.IsTrue(
            Envelope.Parse(Body, Id, IssuedAt, Origin, Data, ErrorMsg),
            StrSubstNo('Parse returned false: %1', ErrorMsg));
        LibraryAssert.AreEqual('8e2f3c7e-5b41-4f3a-8e99-5b9e9b8f2a11', Id, 'id wrong');
        LibraryAssert.AreEqual('contoso.web/checkout@v3.2.1', Origin, 'origin wrong');
    end;

    [Test]
    procedure ParseRejectsMissingId()
    var
        Body, Data: JsonObject;
        Id, Origin, ErrorMsg: Text;
        IssuedAt: DateTime;
    begin
        Body.Add('issuedAt', '2026-05-08T00:00:00Z');
        Body.Add('origin',   'contoso');
        Body.Add('data',     Data);

        LibraryAssert.IsFalse(Envelope.Parse(Body, Id, IssuedAt, Origin, Data, ErrorMsg), 'should fail');
        LibraryAssert.IsTrue(StrPos(ErrorMsg, 'id') > 0, 'error message should mention id');
    end;

    [Test]
    procedure ParseRejectsOriginWithControlChars()
    var
        Body, Data: JsonObject;
        Id, Origin, ErrorMsg: Text;
        IssuedAt: DateTime;
        Lf: Char;
    begin
        // Format(10) yields the string "10", not a control char — so the origin must carry an
        // actual LF. A Char holds the code point and Format(Char) emits the character itself.
        Lf := 10;
        Body.Add('id',       'r-1');
        Body.Add('issuedAt', '2026-05-08T00:00:00Z');
        Body.Add('origin',   'evil' + Format(Lf) + 'newline');
        Body.Add('data',     Data);

        LibraryAssert.IsFalse(Envelope.Parse(Body, Id, IssuedAt, Origin, Data, ErrorMsg), 'should fail');
        LibraryAssert.IsTrue(StrPos(ErrorMsg, 'origin') > 0, 'error should mention origin');
    end;

    [Test]
    procedure ParseAcceptsIdempotencyKey()
    var
        Body, Data: JsonObject;
        Id, Origin, IdemKey, ErrorMsg: Text;
        IssuedAt: DateTime;
    begin
        Body.Add('id',             'r-10');
        Body.Add('issuedAt',       '2026-05-08T00:00:00Z');
        Body.Add('origin',         'contoso');
        Body.Add('data',           Data);
        Body.Add('idempotencyKey', 'order-2026-000042');

        LibraryAssert.IsTrue(
            Envelope.Parse(Body, Id, IssuedAt, Origin, Data, IdemKey, ErrorMsg),
            StrSubstNo('Parse returned false: %1', ErrorMsg));
        LibraryAssert.AreEqual('order-2026-000042', IdemKey, 'idempotencyKey wrong');
    end;

    [Test]
    procedure ParseDefaultsAbsentIdempotencyKeyToEmpty()
    var
        Body, Data: JsonObject;
        Id, Origin, IdemKey, ErrorMsg: Text;
        IssuedAt: DateTime;
    begin
        IdemKey := 'stale-value-from-previous-parse';
        Body.Add('id',       'r-11');
        Body.Add('issuedAt', '2026-05-08T00:00:00Z');
        Body.Add('origin',   'contoso');
        Body.Add('data',     Data);

        LibraryAssert.IsTrue(
            Envelope.Parse(Body, Id, IssuedAt, Origin, Data, IdemKey, ErrorMsg),
            StrSubstNo('Parse returned false: %1', ErrorMsg));
        LibraryAssert.AreEqual('', IdemKey, 'absent idempotencyKey must yield empty');
    end;

    [Test]
    procedure ParseRejectsIdempotencyKeyWithControlChars()
    var
        Body, Data: JsonObject;
        Id, Origin, IdemKey, ErrorMsg: Text;
        IssuedAt: DateTime;
        Lf: Char;
    begin
        Lf := 10;
        Body.Add('id',             'r-12');
        Body.Add('issuedAt',       '2026-05-08T00:00:00Z');
        Body.Add('origin',         'contoso');
        Body.Add('data',           Data);
        Body.Add('idempotencyKey', 'evil' + Format(Lf) + 'key');

        LibraryAssert.IsFalse(Envelope.Parse(Body, Id, IssuedAt, Origin, Data, IdemKey, ErrorMsg), 'should fail');
        LibraryAssert.IsTrue(StrPos(ErrorMsg, 'idempotencyKey') > 0, 'error should mention idempotencyKey');
    end;

    [Test]
    procedure ParseRejectsIdempotencyKeyTooLong()
    var
        Body, Data: JsonObject;
        Id, Origin, IdemKey, ErrorMsg: Text;
        IssuedAt: DateTime;
    begin
        Body.Add('id',             'r-13');
        Body.Add('issuedAt',       '2026-05-08T00:00:00Z');
        Body.Add('origin',         'contoso');
        Body.Add('data',           Data);
        Body.Add('idempotencyKey', PadStr('', 129, 'k'));

        LibraryAssert.IsFalse(Envelope.Parse(Body, Id, IssuedAt, Origin, Data, IdemKey, ErrorMsg), 'should fail');
        LibraryAssert.IsTrue(StrPos(ErrorMsg, 'idempotencyKey') > 0, 'error should mention idempotencyKey');
    end;

    [Test]
    procedure ParseRejectsNonStringIdempotencyKey()
    var
        Body, Data, NotAString: JsonObject;
        Id, Origin, IdemKey, ErrorMsg: Text;
        IssuedAt: DateTime;
    begin
        // An object is not a JSON value at all — same rejection the other members get.
        Body.Add('id',             'r-14');
        Body.Add('issuedAt',       '2026-05-08T00:00:00Z');
        Body.Add('origin',         'contoso');
        Body.Add('data',           Data);
        Body.Add('idempotencyKey', NotAString);

        LibraryAssert.IsFalse(Envelope.Parse(Body, Id, IssuedAt, Origin, Data, IdemKey, ErrorMsg), 'should fail');
        LibraryAssert.IsTrue(StrPos(ErrorMsg, 'idempotencyKey') > 0, 'error should mention idempotencyKey');
    end;

    [Test]
    procedure ParseRejectsOriginTooLong()
    var
        Body, Data: JsonObject;
        Id, Origin, ErrorMsg: Text;
        IssuedAt: DateTime;
    begin
        Body.Add('id',       'r-2');
        Body.Add('issuedAt', '2026-05-08T00:00:00Z');
        Body.Add('origin',   PadStr('', 257, 'a'));
        Body.Add('data',     Data);

        LibraryAssert.IsFalse(Envelope.Parse(Body, Id, IssuedAt, Origin, Data, ErrorMsg), 'should fail');
    end;
}
