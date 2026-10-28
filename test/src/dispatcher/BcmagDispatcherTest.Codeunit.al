codeunit 94318 "Bcmag Dispatcher Test"
{
    Subtype = Test;
    TestPermissions = Disabled;

    // End-to-end through "Bcmag Rpc Dispatcher".RunEx: envelope validation, operation routing,
    // the Codeunit.Run isolation boundary, and the always-200-with-status-in-body contract.
    // RunEx surfaces the logical status for in-process assertions.

    var
        Dispatcher: Codeunit "Bcmag Rpc Dispatcher";
        Helper: Codeunit "Bcmag Test Helper";
        LibraryAssert: Codeunit "Library Assert";

    [Test]
    procedure MalformedEnvelopeReturns400ProblemDocument()
    var
        Body, Result: JsonObject;
        Tok: JsonToken;
        Status: Integer;
    begin
        // Missing required "data" field => invalid envelope.
        Body.Add('id', DelChr(LowerCase(Format(CreateGuid())), '<>', '{}'));
        Body.Add('issuedAt', Format(CurrentDateTime(), 0, 9));
        Body.Add('origin', 'wicket.test');

        Helper.CommitFixtures();
        Result := Dispatcher.RunEx('query', Body, '', Status);
        LibraryAssert.AreEqual(400, Status, 'malformed envelope must be 400');
        LibraryAssert.IsTrue(Result.Get('type', Tok), 'problem body must carry a type');
        LibraryAssert.IsTrue(Result.Get('status', Tok), 'problem body must carry a status');
        LibraryAssert.AreEqual(400, Tok.AsValue().AsInteger(), 'status in body should be 400');
    end;

    // The wire entry point: the API page's bound actions take and return Text (a JsonObject signature is
    // silently left out of $metadata). A serialised envelope round-trips; text that is not a JSON object
    // is a 400 problem, never an AL error the platform would turn into a raw OData failure.
    [Test]
    procedure RunTextRoundTripsASerialisedEnvelope()
    var
        Data, Body, Result: JsonObject;
        Tok: JsonToken;
        EnvelopeText, ResultText: Text;
    begin
        Body := Helper.Envelope(Data);
        Body.WriteTo(EnvelopeText);
        Helper.CommitFixtures();
        ResultText := Dispatcher.RunText('whoAmI', EnvelopeText);
        LibraryAssert.IsTrue(Result.ReadFrom(ResultText), 'the result must be one serialised JSON object');
        LibraryAssert.IsTrue(Helper.ValueObject(Result).Get('userSecurityId', Tok), 'whoAmI answered through the text entry point');
        LibraryAssert.IsTrue(Result.Contains('@requestId'), 'the result carries @requestId');
    end;

    [Test]
    procedure RunTextAnswersNonJsonWithAnInvalidEnvelopeProblem()
    var
        Result: JsonObject;
        Tok: JsonToken;
        ResultText: Text;
    begin
        Helper.CommitFixtures();
        foreach ResultText in NonEnvelopeTexts() do begin
            ResultText := Dispatcher.RunText('whoAmI', ResultText);
            LibraryAssert.IsTrue(Result.ReadFrom(ResultText), 'the refusal is still one JSON object');
            LibraryAssert.IsTrue(StrPos(Helper.TypeOf(Result), 'invalid-envelope') > 0, 'expected invalid-envelope, got ' + ResultText);
            Result.Get('status', Tok);
            LibraryAssert.AreEqual(400, Tok.AsValue().AsInteger(), 'status in body should be 400');
        end;
    end;

    local procedure NonEnvelopeTexts() Texts: List of [Text]
    begin
        Texts.Add('');
        Texts.Add('not json');
        Texts.Add('[1,2]');
        Texts.Add('{"id":');
    end;

    [Test]
    procedure UnknownOperationReturns404()
    var
        Data, Body, Result: JsonObject;
        Tok: JsonToken;
        Status: Integer;
    begin
        Body := Helper.Envelope(Data);
        Helper.CommitFixtures();
        Result := Dispatcher.RunEx('bogus', Body, '', Status);
        LibraryAssert.AreEqual(404, Status, 'unknown operation must be 404');
        LibraryAssert.IsTrue(Result.Get('type', Tok), 'problem body must carry a type');
        Result.Get('status', Tok);
        LibraryAssert.AreEqual(404, Tok.AsValue().AsInteger(), 'status in body should be 404');
    end;

    [Test]
    procedure ValidQueryReturns200()
    var
        Customer: Record Customer;
        Data, Body, Result: JsonObject;
        Tok: JsonToken;
        Status: Integer;
    begin
        Helper.ConfigureOpenMode();
        if not Customer.Get('D-1') then begin
            Customer.Init();
            Customer."No." := 'D-1';
            Customer.Insert();
        end;

        Data.Add('tableId', Database::Customer);
        Data.Add('top', 1);
        Body := Helper.Envelope(Data);

        Helper.CommitFixtures();
        Result := Dispatcher.RunEx('query', Body, '', Status);
        LibraryAssert.AreEqual(200, Status, 'a valid query must be 200');
        LibraryAssert.IsTrue(Result.Get('value', Tok), 'success body must carry a value');
        LibraryAssert.IsTrue(Result.Get('@requestId', Tok), 'success body must echo @requestId');
    end;

    // ---- Idempotency replay ----------------------------------------------------------------
    // Activity Log has an AutoIncrement integer PK, so two executed inserts always create two
    // rows — which makes "the second call did not execute" directly observable via Count().

    local procedure InsertEnvelopeData(Marker: Text) Data: JsonObject
    var
        Values: JsonObject;
    begin
        Values.Add('Description', Marker);
        Data.Add('tableId', Database::"Activity Log");
        Data.Add('values', Values);
        Data.Add('init', false);
    end;

    local procedure NewMarker(): Text
    begin
        exit('BCMAG-IDEM-' + DelChr(LowerCase(Format(CreateGuid())), '<>', '{}'));
    end;

    [Test]
    procedure SameKeySameBodyReplaysWithoutSecondInsert()
    var
        ActivityLog: Record "Activity Log";
        Body, First, Second: JsonObject;
        Tok: JsonToken;
        Status: Integer;
        Marker: Text;
    begin
        Helper.ConfigureOpenMode();
        Marker := NewMarker();
        Body := Helper.EnvelopeWithKey(InsertEnvelopeData(Marker), Helper.NewIdemKey());

        Helper.CommitFixtures();
        First := Dispatcher.RunEx('insert', Body, '', Status);
        LibraryAssert.AreEqual(200, Status, 'first insert must succeed');
        LibraryAssert.IsFalse(First.Get('@replayed', Tok), 'first call must not be marked replayed');

        // Identical body (same JsonObject) + same key = replay, not a second execution.
        Helper.CommitFixtures();
        Second := Dispatcher.RunEx('insert', Body, '', Status);
        LibraryAssert.AreEqual(200, Status, 'replay must surface the stored status');
        LibraryAssert.IsTrue(Second.Get('@replayed', Tok), 'second call must be marked @replayed');
        LibraryAssert.IsTrue(Tok.AsValue().AsBoolean(), '@replayed must be true');

        ActivityLog.SetRange(Description, Marker);
        LibraryAssert.AreEqual(1, ActivityLog.Count(), 'replay must not create a second record');

        // The replayed payload is the stored one verbatim: same recordId, same original @requestId.
        LibraryAssert.AreEqual(
            Helper.TextField(Helper.ValueObject(First), 'recordId'),
            Helper.TextField(Helper.ValueObject(Second), 'recordId'),
            'replayed recordId must match the original');
        LibraryAssert.AreEqual(
            Helper.TextField(First, '@requestId'),
            Helper.TextField(Second, '@requestId'),
            'replay must echo the ORIGINAL @requestId');
    end;

    [Test]
    procedure SameKeyDifferentBodyReturns409Conflict()
    var
        Body, Result: JsonObject;
        Tok: JsonToken;
        Status: Integer;
        IdemKey: Text;
    begin
        Helper.ConfigureOpenMode();
        IdemKey := Helper.NewIdemKey();

        Body := Helper.EnvelopeWithKey(InsertEnvelopeData(NewMarker()), IdemKey);
        Helper.CommitFixtures();
        Dispatcher.RunEx('insert', Body, '', Status);
        LibraryAssert.AreEqual(200, Status, 'first insert must succeed');

        // Different data (and a fresh envelope id) under the SAME key breaks the contract.
        Body := Helper.EnvelopeWithKey(InsertEnvelopeData(NewMarker()), IdemKey);
        Helper.CommitFixtures();
        Result := Dispatcher.RunEx('insert', Body, '', Status);
        LibraryAssert.AreEqual(409, Status, 'reused key with a different body must be 409');
        LibraryAssert.IsTrue(Result.Get('type', Tok), 'problem body must carry a type');
        LibraryAssert.IsTrue(StrPos(Tok.AsValue().AsText(), 'idempotency-conflict') > 0,
            'problem type must be idempotency-conflict');
        LibraryAssert.IsFalse(Result.Get('@replayed', Tok), 'a conflict is not a replay');
    end;

    [Test]
    procedure NoKeyIdenticalInsertsExecuteTwice()
    var
        ActivityLog: Record "Activity Log";
        Body, Result: JsonObject;
        Tok: JsonToken;
        Status: Integer;
        Marker: Text;
    begin
        Helper.ConfigureOpenMode();
        Marker := NewMarker();
        Body := Helper.Envelope(InsertEnvelopeData(Marker));

        Helper.CommitFixtures();
        Dispatcher.RunEx('insert', Body, '', Status);
        LibraryAssert.AreEqual(200, Status, 'first insert must succeed');
        Helper.CommitFixtures();
        Result := Dispatcher.RunEx('insert', Body, '', Status);
        LibraryAssert.AreEqual(200, Status, 'second insert must succeed');
        LibraryAssert.IsFalse(Result.Get('@replayed', Tok), 'no key means no replay');

        ActivityLog.SetRange(Description, Marker);
        LibraryAssert.AreEqual(2, ActivityLog.Count(), 'without a key, both identical inserts must execute');
    end;

    [Test]
    procedure FailedOperationIsCachedAndReplays()
    var
        Data, Body, First, Second: JsonObject;
        Tok: JsonToken;
        Status: Integer;
        FirstType: Text;
    begin
        // Unknown operation => 404 problem. A 4xx is a FINAL outcome, so it must be cached
        // and replayed — only 5xx stays retryable.
        Body := Helper.EnvelopeWithKey(Data, Helper.NewIdemKey());

        Helper.CommitFixtures();
        First := Dispatcher.RunEx('bogus', Body, '', Status);
        LibraryAssert.AreEqual(404, Status, 'unknown operation must be 404');
        First.Get('type', Tok);
        FirstType := Tok.AsValue().AsText();

        Helper.CommitFixtures();
        Second := Dispatcher.RunEx('bogus', Body, '', Status);
        LibraryAssert.AreEqual(404, Status, 'replayed problem must surface the stored status');
        LibraryAssert.IsTrue(Second.Get('@replayed', Tok), 'cached problem must be marked @replayed');
        LibraryAssert.IsTrue(Tok.AsValue().AsBoolean(), '@replayed must be true');
        Second.Get('type', Tok);
        LibraryAssert.AreEqual(FirstType, Tok.AsValue().AsText(), 'replayed problem type must match');
    end;

    [Test]
    procedure MalformedIdempotencyKeyReturnsInvalidEnvelope()
    var
        Data, Body, Result: JsonObject;
        Tok: JsonToken;
        Status: Integer;
    begin
        Body := Helper.Envelope(Data);
        Body.Add('idempotencyKey', PadStr('', 129, 'k')); // over the 128-char limit

        Helper.CommitFixtures();
        Result := Dispatcher.RunEx('query', Body, '', Status);
        LibraryAssert.AreEqual(400, Status, 'malformed idempotencyKey must be 400');
        LibraryAssert.IsTrue(Result.Get('type', Tok), 'problem body must carry a type');
        LibraryAssert.IsTrue(StrPos(Tok.AsValue().AsText(), 'invalid-envelope') > 0,
            'problem type must be invalid-envelope');
        LibraryAssert.IsTrue(Result.Get('detail', Tok), 'problem body must carry a detail');
        LibraryAssert.IsTrue(StrPos(Tok.AsValue().AsText(), 'idempotencyKey') > 0,
            'detail should name the offending field');
    end;

    [Test]
    procedure SameKeySameDataFreshRequestIdReplays()
    var
        ActivityLog: Record "Activity Log";
        FirstBody, SecondBody, First, Second: JsonObject;
        Tok: JsonToken;
        Status: Integer;
        Marker, IdemKey: Text;
    begin
        // Fix 3: the replay hash covers only the business payload (operation + data), NOT the
        // volatile envelope id/issuedAt. A faithful client that retries with the SAME key + data
        // but a FRESH request id must REPLAY, not hit a 409. Each EnvelopeWithKey call mints a
        // distinct envelope id for identical data, so the two bodies differ ONLY in id/issuedAt.
        Helper.ConfigureOpenMode();
        Marker := NewMarker();
        IdemKey := Helper.NewIdemKey();

        FirstBody := Helper.EnvelopeWithKey(InsertEnvelopeData(Marker), IdemKey);
        Helper.CommitFixtures();
        First := Dispatcher.RunEx('insert', FirstBody, '', Status);
        LibraryAssert.AreEqual(200, Status, 'first insert must succeed');
        LibraryAssert.IsFalse(First.Get('@replayed', Tok), 'first call must not be replayed');

        SecondBody := Helper.EnvelopeWithKey(InsertEnvelopeData(Marker), IdemKey);
        LibraryAssert.AreNotEqual(
            Helper.TextField(FirstBody, 'id'), Helper.TextField(SecondBody, 'id'),
            'the two envelopes must carry different request ids');

        Helper.CommitFixtures();
        Second := Dispatcher.RunEx('insert', SecondBody, '', Status);
        LibraryAssert.AreEqual(200, Status, 'a retry with a fresh id must replay the stored status');
        LibraryAssert.IsTrue(Second.Get('@replayed', Tok), 'a retry with a fresh id must be @replayed');
        LibraryAssert.IsTrue(Tok.AsValue().AsBoolean(), '@replayed must be true');

        ActivityLog.SetRange(Description, Marker);
        LibraryAssert.AreEqual(1, ActivityLog.Count(), 'a replayed retry must not execute a second insert');

        // Replay echoes the ORIGINAL request id even though the retry carried a fresh one.
        LibraryAssert.AreEqual(
            Helper.TextField(First, '@requestId'),
            Helper.TextField(Second, '@requestId'),
            'replay must echo the original @requestId, not the retry id');
    end;

    [Test]
    procedure SameKeyDifferentOperationDoesNotReplayForeignPayload()
    var
        FirstBody, SecondBody, First, Second: JsonObject;
        Tok: JsonToken;
        Status: Integer;
        Marker, IdemKey: Text;
    begin
        // Fix 2/3: operation is folded into the replay hash, so the replay identity is
        // (Caller, key, operation + data). Reusing a key for a DIFFERENT operation but the SAME
        // data must NOT return the first operation's cached payload. Under the operation-in-hash
        // scheme this surfaces as a 409 conflict (a key promises a single logical request); either
        // way the caller can never receive the wrong operation's response.
        Helper.ConfigureOpenMode();
        Marker := NewMarker();
        IdemKey := Helper.NewIdemKey();

        FirstBody := Helper.EnvelopeWithKey(InsertEnvelopeData(Marker), IdemKey);
        Helper.CommitFixtures();
        First := Dispatcher.RunEx('insert', FirstBody, '', Status);
        LibraryAssert.AreEqual(200, Status, 'first insert must succeed');
        LibraryAssert.IsTrue(First.Get('value', Tok), 'first insert must return a value payload');

        // SAME key + SAME data, but a different operation.
        SecondBody := Helper.EnvelopeWithKey(InsertEnvelopeData(Marker), IdemKey);
        Helper.CommitFixtures();
        Second := Dispatcher.RunEx('query', SecondBody, '', Status);
        LibraryAssert.AreEqual(409, Status, 'a key reused for a different operation must conflict, not replay');
        LibraryAssert.IsTrue(Second.Get('type', Tok), 'conflict body must carry a type');
        LibraryAssert.IsTrue(StrPos(Tok.AsValue().AsText(), 'idempotency-conflict') > 0,
            'a cross-operation key reuse must be an idempotency-conflict');
        LibraryAssert.IsFalse(Second.Get('@replayed', Tok), 'a conflict is not a replay');
        LibraryAssert.IsFalse(Second.Get('value', Tok),
            'the foreign operation must never receive the first operation''s value payload');
    end;

    [Test]
    procedure StoredSnapshotCarriesCallerSecurityId()
    var
        IdemLog: Record "Bcmag Idempotency Log";
        Body: JsonObject;
        Status: Integer;
        IdemKey: Text;
    begin
        // Cross-principal isolation (one caller never replays another's row) is enforced by
        // scoping FindReplay to Caller = UserSecurityId(). UserSecurityId() is fixed for the whole
        // test session, so TRUE cross-user isolation can only be proven in a multi-user sandbox
        // run. What this test DOES prove: the snapshot row is stamped with a non-null Caller equal
        // to the current principal's UserSecurityId — the exact value FindReplay filters on.
        Helper.ConfigureOpenMode();
        IdemKey := Helper.NewIdemKey();
        Body := Helper.EnvelopeWithKey(InsertEnvelopeData(NewMarker()), IdemKey);
        Helper.CommitFixtures();
        Dispatcher.RunEx('insert', Body, '', Status);
        LibraryAssert.AreEqual(200, Status, 'first insert must succeed');

        IdemLog.SetRange("Idempotency Key", IdemKey);
        LibraryAssert.IsTrue(IdemLog.FindLast(), 'a snapshot row must exist for the key');
        LibraryAssert.IsFalse(IsNullGuid(IdemLog.Caller), 'snapshot Caller must be a non-null security id');
        LibraryAssert.AreEqual(UserSecurityId(), IdemLog.Caller,
            'snapshot Caller must equal the current principal''s UserSecurityId');
    end;

    // -- A replay is re-authorized against the policy in force NOW ------------------------------

    local procedure SeedCustomer(No: Code[20]; Name: Text[100])
    var
        Customer: Record Customer;
    begin
        if Customer.Get(No) then
            Customer.Delete();
        Customer.Init();
        Customer."No." := No;
        Customer.Name := Name;
        Customer.Insert();
    end;

    local procedure CustomerQueryData(SelectAll: Boolean) Data: JsonObject
    var
        Select: JsonArray;
    begin
        if SelectAll then
            Select.Add('*')
        else begin
            Select.Add('No.');
            Select.Add('Name');
        end;
        Data.Add('tableId', Database::Customer);
        Data.Add('select', Select);
    end;

    // A refused replay of a COMPLETED request is 403 replay-withheld, never the plain refusal a fresh call
    // would get: that would tell the client the request never happened, and it would repeat the write
    // under a new key. The reason the content is withheld is carried as `reason` (the problem slug the
    // operation would answer now) and the original outcome as `originalStatus`.
    local procedure AssertRefusedNotReplayed(Response: JsonObject; Status: Integer; ExpectedStatus: Integer; ExpectedReason: Text; Context: Text)
    var
        Tok: JsonToken;
    begin
        LibraryAssert.AreEqual(ExpectedStatus, Status, Context + ': status');
        LibraryAssert.IsTrue(StrPos(Helper.TypeOf(Response), 'replay-withheld') > 0, Context + ': expected replay-withheld, got ' + Helper.TypeOf(Response));
        LibraryAssert.AreEqual(ExpectedReason, Helper.TextField(Response, 'reason'), Context + ': reason');
        LibraryAssert.IsTrue(Response.Get('originalStatus', Tok), Context + ': originalStatus must be present');
        LibraryAssert.AreEqual(200, Tok.AsValue().AsInteger(), Context + ': the original request completed with 200');
        LibraryAssert.IsTrue(StrPos(Helper.DetailOf(Response), 'COMPLETED') > 0, Context + ': the detail must say the request completed');
        LibraryAssert.IsFalse(Response.Get('@replayed', Tok), Context + ': a refusal is not a replay');
        LibraryAssert.IsFalse(Response.Contains('value'), Context + ': a refusal discloses nothing');
    end;

    local procedure AssertReplayed(Response: JsonObject; Status: Integer; Context: Text)
    var
        Tok: JsonToken;
    begin
        LibraryAssert.AreEqual(200, Status, Context + ': status');
        LibraryAssert.IsTrue(Response.Get('@replayed', Tok), Context + ': must be a replay');
        LibraryAssert.IsTrue(Tok.AsValue().AsBoolean(), Context + ': @replayed must be true');
    end;

    [Test]
    procedure ReplayIsRefusedOnceTableExposureIsRevokedAndResumesWhenRestored()
    var
        Body, Response: JsonObject;
        Status: Integer;
    begin
        // Caller scoping stops OTHER principals; this is the SAME principal, same key, same body,
        // after the administrator removed the table from the allowlist. The cached rows must not
        // come back through the replay cache — and must come back once the exposure is restored,
        // because the refusal is evaluated per disclosure, not stored as the new answer.
        Helper.ConfigureAllowlistedMode();
        Helper.ExposeTable(Database::Customer, true, false, false, false);
        SeedCustomer('RPL-1', 'Replay One');
        Body := Helper.EnvelopeWithKey(CustomerQueryData(false), Helper.NewIdemKey());
        Helper.CommitFixtures();

        Response := Dispatcher.RunEx('query', Body, '', Status);
        LibraryAssert.AreEqual(200, Status, 'the first query must succeed');
        LibraryAssert.IsTrue(Helper.ValueArray(Response).Count() > 0, 'the snapshot carries rows');

        Helper.UnexposeTable(Database::Customer);
        Helper.CommitFixtures();
        Response := Dispatcher.RunEx('query', Body, '', Status);
        AssertRefusedNotReplayed(Response, Status, 403, 'not-exposed', 'after revocation');

        Helper.ExposeTable(Database::Customer, true, false, false, false);
        Helper.CommitFixtures();
        Response := Dispatcher.RunEx('query', Body, '', Status);
        AssertReplayed(Response, Status, 'after restoration');
        LibraryAssert.IsTrue(Helper.ValueArray(Response).Count() > 0, 'the original rows replay again');
    end;

    [Test]
    procedure ReplayIsRefusedOnceAFieldInTheStoredRowsBecomesRestricted()
    var
        Body, Response, Row: JsonObject;
        Tok: JsonToken;
        Status: Integer;
    begin
        // select ["*"] narrows to the readable set WITHOUT naming fields, so nothing in the request
        // says which fields the snapshot holds. The stored rows themselves must be judged: once any
        // field they carry is restricted, the snapshot is withheld — and the refusal must not name the
        // field (the name is what the policy hides).
        Helper.ConfigureOpenMode(); // pins Field Policy Mode = AllFields
        SeedCustomer('RPL-2', 'Replay Two');
        Body := Helper.EnvelopeWithKey(CustomerQueryData(true), Helper.NewIdemKey());
        Helper.CommitFixtures();

        Response := Dispatcher.RunEx('query', Body, '', Status);
        LibraryAssert.AreEqual(200, Status, 'the first query must succeed');
        Helper.ValueArray(Response).Get(0, Tok);
        Row := Tok.AsObject();
        LibraryAssert.IsTrue(Row.Contains('Name'), 'the snapshot holds Name (readable at the time)');

        // Explicit mode: only fields with an override row are readable; Name has none.
        Helper.SetFieldPolicyMode(Enum::"Bcmag Field Policy Mode"::Explicit);
        Helper.CommitFixtures();
        Response := Dispatcher.RunEx('query', Body, '', Status);
        AssertRefusedNotReplayed(Response, Status, 403, 'field-restricted', 'after restriction');
        LibraryAssert.IsTrue(StrPos(Helper.DetailOf(Response), 'Name') = 0, 'the refusal must not name the restricted field');

        Helper.SetFieldPolicyMode(Enum::"Bcmag Field Policy Mode"::AllFields);
        Helper.CommitFixtures();
        Response := Dispatcher.RunEx('query', Body, '', Status);
        AssertReplayed(Response, Status, 'after the policy is relaxed again');
    end;

    [Test]
    procedure ReplayIsRefusedOnceAFieldTheQueryFilteredByBecomesRestricted()
    var
        Data, Body, Response, Row: JsonObject;
        Select: JsonArray;
        Tok: JsonToken;
        Status: Integer;
    begin
        // The stored rows carry only the primary key, which is always readable — so a body scan alone
        // would pass. But WHICH rows came back was decided by a filter on Name: once Name is restricted,
        // replaying that membership is the same inference oracle a live filter on Name is refused for.
        Helper.ConfigureOpenMode(); // pins Field Policy Mode = AllFields
        SeedCustomer('RPL-3', 'Replay Three Filtered');
        Select.Add('No.');
        Data.Add('tableId', Database::Customer);
        Data.Add('select', Select);
        Data.Add('filter', 'startswith(Name, ''Replay Three'')');
        Body := Helper.EnvelopeWithKey(Data, Helper.NewIdemKey());
        Helper.CommitFixtures();

        Response := Dispatcher.RunEx('query', Body, '', Status);
        LibraryAssert.AreEqual(200, Status, 'the first query must succeed');
        Helper.ValueArray(Response).Get(0, Tok);
        Row := Tok.AsObject();
        LibraryAssert.IsFalse(Row.Contains('Name'), 'the snapshot does not project Name');

        // Explicit mode: Name has no override row, so it is restricted; No. (the key) stays readable.
        Helper.SetFieldPolicyMode(Enum::"Bcmag Field Policy Mode"::Explicit);
        Helper.CommitFixtures();
        Response := Dispatcher.RunEx('query', Body, '', Status);
        AssertRefusedNotReplayed(Response, Status, 403, 'field-restricted', 'after the filtered field is restricted');

        Helper.SetFieldPolicyMode(Enum::"Bcmag Field Policy Mode"::AllFields);
        Helper.CommitFixtures();
        Response := Dispatcher.RunEx('query', Body, '', Status);
        AssertReplayed(Response, Status, 'after the policy is relaxed again');
    end;

    [Test]
    procedure ReplayOfAWriteIsRefusedWhileTheEndpointIsReadOnly()
    var
        ActivityLog: Record "Activity Log";
        Body, Response: JsonObject;
        Status: Integer;
        Marker: Text;
    begin
        // The gates the runner applies before routing apply to a replay too: the stored record of an
        // insert is not handed out while writes are switched off — and the insert is not re-run.
        Helper.ConfigureOpenMode();
        Marker := NewMarker();
        Body := Helper.EnvelopeWithKey(InsertEnvelopeData(Marker), Helper.NewIdemKey());
        Helper.CommitFixtures();
        Response := Dispatcher.RunEx('insert', Body, '', Status);
        LibraryAssert.AreEqual(200, Status, 'the insert must succeed');

        Helper.SetReadOnlyMode(true);
        Helper.CommitFixtures();
        Response := Dispatcher.RunEx('insert', Body, '', Status);
        AssertRefusedNotReplayed(Response, Status, 403, 'read-only', 'in read-only mode');
        ActivityLog.SetRange(Description, Marker);
        LibraryAssert.AreEqual(1, ActivityLog.Count(), 'the refusal must not execute the insert again');

        Helper.SetReadOnlyMode(false);
        Helper.CommitFixtures();
        Response := Dispatcher.RunEx('insert', Body, '', Status);
        AssertReplayed(Response, Status, 'once writes are back on');
        LibraryAssert.AreEqual(1, ActivityLog.Count(), 'a replay never executes');
    end;

    [Test]
    procedure ReplayOfAWriteIsRefusedOnceWriteExposureIsRevoked()
    var
        Body, Response: JsonObject;
        Status: Integer;
    begin
        // The write's stored response is the inserted record; losing insert exposure on the table
        // withholds it (403 not-exposed, the same problem a fresh insert would get now).
        Helper.ConfigureAllowlistedMode();
        Helper.ExposeTable(Database::"Activity Log", true, true, false, false);
        Body := Helper.EnvelopeWithKey(InsertEnvelopeData(NewMarker()), Helper.NewIdemKey());
        Helper.CommitFixtures();
        Response := Dispatcher.RunEx('insert', Body, '', Status);
        LibraryAssert.AreEqual(200, Status, 'the insert must succeed');

        Helper.ExposeTable(Database::"Activity Log", true, false, false, false);
        Helper.CommitFixtures();
        Response := Dispatcher.RunEx('insert', Body, '', Status);
        AssertRefusedNotReplayed(Response, Status, 403, 'not-exposed', 'after insert exposure is revoked');
    end;

    [Test]
    procedure ReplayOfDescribeIsRefusedOnceListedFieldsBecomeRestricted()
    var
        Body, Data, Response: JsonObject;
        Status: Integer;
    begin
        // describe omits restricted fields; a stored describe that listed a field which is restricted
        // now would advertise it. Unless the administrator opts into advertising restricted fields
        // (Describe Restricted Fields), in which case the stored list discloses nothing more.
        Helper.ConfigureOpenMode();
        Helper.SetDescribeRestrictedFields(false);
        Data.Add('kind', 'table');
        Data.Add('tableId', Database::Customer);
        Body := Helper.EnvelopeWithKey(Data, Helper.NewIdemKey());
        Helper.CommitFixtures();
        Response := Dispatcher.RunEx('describe', Body, '', Status);
        LibraryAssert.AreEqual(200, Status, 'the describe must succeed');

        Helper.SetFieldPolicyMode(Enum::"Bcmag Field Policy Mode"::Explicit);
        Helper.CommitFixtures();
        Response := Dispatcher.RunEx('describe', Body, '', Status);
        AssertRefusedNotReplayed(Response, Status, 403, 'field-restricted', 'after restriction');

        Helper.SetDescribeRestrictedFields(true);
        Helper.CommitFixtures();
        Response := Dispatcher.RunEx('describe', Body, '', Status);
        AssertReplayed(Response, Status, 'when restricted fields may be advertised');
    end;

    [Test]
    procedure ReplayOfReadBlobIsRefusedOnceTheFieldIsRestricted()
    var
        Catalog: Record "Bcmag Procedure Catalog";
        Codec: Codeunit "Bcmag Record Id Codec";
        Body, Data, Response: JsonObject;
        Status: Integer;
    begin
        // readBlob's stored bytes ARE the field; the request names it by number, so the current
        // policy for that field decides.
        Helper.ConfigureOpenMode();
        if Catalog.Get(94318, 'ReplayProbe') then
            Catalog.Delete();
        Catalog.Init();
        Catalog."Logical Codeunit Id" := 94318;
        Catalog."Procedure Name" := 'ReplayProbe';
        Catalog."Wrapper Codeunit Id" := 94190;
        Catalog.SetArgsSchema('{"type":"object"}');
        Catalog.Insert();
        Data.Add('tableId', Database::"Bcmag Procedure Catalog");
        Data.Add('recordId', Codec.Encode(Catalog.RecordId));
        Data.Add('fieldNo', Catalog.FieldNo("Args Schema"));
        Body := Helper.EnvelopeWithKey(Data, Helper.NewIdemKey());
        Helper.CommitFixtures();
        Response := Dispatcher.RunEx('readBlob', Body, '', Status);
        LibraryAssert.AreEqual(200, Status, 'the readBlob must succeed');

        Helper.SetFieldPolicyMode(Enum::"Bcmag Field Policy Mode"::ByClassification);
        Helper.ExposeField(Database::"Bcmag Procedure Catalog", Catalog.FieldNo("Args Schema"), false, false);
        Helper.CommitFixtures();
        Response := Dispatcher.RunEx('readBlob', Body, '', Status);
        AssertRefusedNotReplayed(Response, Status, 403, 'field-restricted', 'after the field is restricted');

        Helper.UnexposeField(Database::"Bcmag Procedure Catalog", Catalog.FieldNo("Args Schema"));
        Helper.SetFieldPolicyMode(Enum::"Bcmag Field Policy Mode"::AllFields);
        Helper.CommitFixtures();
        Response := Dispatcher.RunEx('readBlob', Body, '', Status);
        AssertReplayed(Response, Status, 'after the field is readable again');
    end;

    [Test]
    procedure ReadOnlyModeBlocksEveryMutatingOperation()
    var
        Data, Body, Result: JsonObject;
        Status: Integer;
    begin
        // The read-only master switch refuses insert/modify/delete/invoke/action ahead of Mode,
        // exposure, and BC permissions — here Open mode would otherwise allow the writes. Reads are
        // untouched. A mutating `action` is refused; previews and non-mutating verbs run inside the forced
        // rollback and are covered by Bcmag Action Rollback Test.
        Helper.ConfigureOpenMode();
        Helper.SetReadOnlyMode(true);

        AssertReadOnlyRefusal('insert');
        AssertReadOnlyRefusal('modify');
        AssertReadOnlyRefusal('delete');
        AssertReadOnlyRefusal('invoke');
        AssertReadOnlyRefusal('action');

        // A read still succeeds while read-only is on.
        Data.Add('tableId', Database::Customer);
        Data.Add('top', 1);
        Body := Helper.Envelope(Data);
        Helper.CommitFixtures();
        Result := Dispatcher.RunEx('query', Body, '', Status);
        LibraryAssert.AreEqual(200, Status, 'query must still succeed in read-only mode');

        Helper.SetReadOnlyMode(false);
    end;

    local procedure AssertReadOnlyRefusal(Operation: Text)
    var
        Data, Body, Result: JsonObject;
        Tok: JsonToken;
        Status: Integer;
    begin
        // The guard fires before the handler, so the data payload need not be valid for the op.
        Data.Add('tableId', Database::Customer);
        Body := Helper.Envelope(Data);
        Helper.CommitFixtures();
        Result := Dispatcher.RunEx(Operation, Body, '', Status);
        LibraryAssert.AreEqual(403, Status, StrSubstNo('%1 must be refused with 403 in read-only mode', Operation));
        LibraryAssert.IsTrue(Result.Get('type', Tok), 'problem body must carry a type');
        LibraryAssert.IsTrue(StrPos(Tok.AsValue().AsText(), 'read-only') > 0,
            StrSubstNo('%1 must be refused with the read-only problem type', Operation));
    end;

    [Test]
    procedure ReplayOfAnAggregateIsRefusedOnceItsFieldBecomesMasked()
    var
        Data, Agg, Body, Response: JsonObject;
        Arr: JsonArray;
        FieldRec: Record Field;
        Status: Integer;
    begin
        // Replay does not rerun the aggregate's field resolution, so the authorizer itself must
        // refuse a stored min over a field that is now Masked (it would replay the clear value).
        Helper.ConfigureOpenMode(); // AllFields: Name is Clear for the first run; Unmask tier off
        SeedCustomer('RPL-AG', 'Replay Aggregate');
        Arr.Add('Name');
        Agg.Add('min', Arr);
        Data.Add('tableId', Database::Customer);
        Data.Add('aggregate', Agg);
        Body := Helper.EnvelopeWithKey(Data, Helper.NewIdemKey());
        Helper.CommitFixtures();

        Response := Dispatcher.RunEx('query', Body, '', Status);
        LibraryAssert.AreEqual(200, Status, 'the first aggregate must succeed');

        FieldRec.SetRange(TableNo, Database::Customer);
        FieldRec.SetRange(FieldName, 'Name');
        FieldRec.FindFirst();
        Helper.SetFieldPolicyMode(Enum::"Bcmag Field Policy Mode"::ByClassification);
        Helper.SetFieldAccess(Database::Customer, FieldRec."No.", "Bcmag Read Access"::Masked, 'PARTIAL', false);
        Helper.CommitFixtures();
        Response := Dispatcher.RunEx('query', Body, '', Status);
        AssertRefusedNotReplayed(Response, Status, 403, 'field-masked', 'after the aggregated field is masked');

        Helper.UnexposeField(Database::Customer, FieldRec."No.");
        Helper.SetFieldPolicyMode(Enum::"Bcmag Field Policy Mode"::AllFields);
        Helper.CommitFixtures();
    end;

    // -- Masking: replay, request scope and the audit log -----------------------------------------

    local procedure MaskedNameQueryData(CustomerNo: Code[20]) Data: JsonObject
    var
        Select: JsonArray;
    begin
        Select.Add('No.');
        Select.Add('Name');
        Data.Add('tableId', Database::Customer);
        Data.Add('select', Select);
        Data.Add('filter', StrSubstNo('"No." eq ''%1''', CustomerNo));
    end;

    local procedure MaskCustomerName()
    var
        Customer: Record Customer;
    begin
        Helper.SetFieldPolicyMode(Enum::"Bcmag Field Policy Mode"::ByClassification);
        Helper.UpsertMaskProfile('PARTIAL', "Bcmag Mask Kind"::KeepLast, 0, 2, 4, false);
        Helper.SetFieldAccess(Database::Customer, Customer.FieldNo(Name), "Bcmag Read Access"::Masked, 'PARTIAL', false);
    end;

    local procedure RestoreClearPolicy()
    var
        Customer: Record Customer;
    begin
        Helper.ClearUserExceptions();
        Helper.UnexposeField(Database::Customer, Customer.FieldNo(Name));
        Helper.SetFieldPolicyMode(Enum::"Bcmag Field Policy Mode"::AllFields);
    end;

    local procedure FirstRow(Response: JsonObject) Row: JsonObject
    var
        Tok: JsonToken;
    begin
        LibraryAssert.IsTrue(Helper.ValueArray(Response).Count() > 0, 'the response must carry a row');
        Helper.ValueArray(Response).Get(0, Tok);
        Row := Tok.AsObject();
    end;

    local procedure ListsMasked(Row: JsonObject; MemberName: Text): Boolean
    var
        Tok, Item: JsonToken;
    begin
        if not Row.Get('@masked', Tok) then
            exit(false);
        foreach Item in Tok.AsArray() do
            if Item.AsValue().AsText() = MemberName then
                exit(true);
        exit(false);
    end;

    [Test]
    procedure ReplayOfRowsStoredInClearIsRefusedOnceAFieldIsMasked()
    var
        Body, Response: JsonObject;
        Status: Integer;
    begin
        // The stored rows carry Name in clear. Once Name is Masked for this caller, replaying them would
        // hand out the value the mask now hides: refused 403 field-masked (withheld — the query completed).
        Helper.ConfigureOpenMode(); // AllFields: Name is Clear for the first run; Unmask tier off
        Helper.ClearUserExceptions();
        SeedCustomer('RPL-M1', 'Replay Masked One');
        Body := Helper.EnvelopeWithKey(MaskedNameQueryData('RPL-M1'), Helper.NewIdemKey());
        Helper.CommitFixtures();

        Response := Dispatcher.RunEx('query', Body, '', Status);
        LibraryAssert.AreEqual(200, Status, 'the first query must succeed');
        LibraryAssert.AreEqual('Replay Masked One', Helper.TextField(FirstRow(Response), 'Name'), 'stored in clear');

        MaskCustomerName();
        Helper.CommitFixtures();
        Response := Dispatcher.RunEx('query', Body, '', Status);
        AssertRefusedNotReplayed(Response, Status, 403, 'field-masked', 'after Name is masked');
        LibraryAssert.IsTrue(StrPos(Helper.DetailOf(Response), 'Name') = 0, 'the refusal must not name the field');

        RestoreClearPolicy();
        Helper.CommitFixtures();
        Response := Dispatcher.RunEx('query', Body, '', Status);
        AssertReplayed(Response, Status, 'once Name is clear again');
    end;

    [Test]
    procedure ReplayOfRowsStoredMaskedReplaysTheMaskedValue()
    var
        Body, Response, Row: JsonObject;
        Status: Integer;
        Rendered: Text;
    begin
        // Stored while Masked, replayed while Masked: the row already carries the mask rendering and
        // names Name in @masked, so it discloses nothing the policy hides now — it replays (200).
        Helper.ConfigureOpenMode();
        Helper.ClearUserExceptions();
        MaskCustomerName();
        SeedCustomer('RPL-M2', 'Replay Masked Two');
        Body := Helper.EnvelopeWithKey(MaskedNameQueryData('RPL-M2'), Helper.NewIdemKey());
        Helper.CommitFixtures();

        Response := Dispatcher.RunEx('query', Body, '', Status);
        LibraryAssert.AreEqual(200, Status, 'the first query must succeed');
        Row := FirstRow(Response);
        Rendered := Helper.TextField(Row, 'Name');
        LibraryAssert.AreNotEqual('Replay Masked Two', Rendered, 'Name is emitted masked');
        LibraryAssert.IsTrue(ListsMasked(Row, 'Name'), 'the stored row names Name in @masked');

        Response := Dispatcher.RunEx('query', Body, '', Status);
        AssertReplayed(Response, Status, 'masked then, masked now');
        Row := FirstRow(Response);
        LibraryAssert.AreEqual(Rendered, Helper.TextField(Row, 'Name'), 'the replay carries the stored mask rendering');
        LibraryAssert.IsTrue(ListsMasked(Row, 'Name'), 'the replayed row still names Name in @masked');

        RestoreClearPolicy();
        Helper.CommitFixtures();
    end;

    [Test]
    procedure ReplayIsJudgedUnderTheReplayingRequestsUnmaskOptOut()
    var
        Customer: Record Customer;
        Data, Body, Other, Response: JsonObject;
        Scope: Option Classification,Field;
        Status: Integer;
    begin
        // The replay must be authorized under THIS request's "unmask" flag, not the one left behind by
        // the previous request. Request A opts out ("unmask": false) and is stored while Name is Clear.
        // Then Name becomes Masked, with a user exception lifting it back to Clear for this caller — Clear
        // only while the caller accepts lifts. A request WITHOUT the opt-out runs in between; replaying A
        // must still see A's opt-out (Masked → refused), not the in-between request's default.
        Helper.ConfigureOpenMode();
        Helper.ClearUserExceptions();
        SeedCustomer('RPL-M3', 'Replay Masked Three');
        Data := MaskedNameQueryData('RPL-M3');
        Data.Add('unmask', false);
        Body := Helper.EnvelopeWithKey(Data, Helper.NewIdemKey());
        Helper.CommitFixtures();
        Response := Dispatcher.RunEx('query', Body, '', Status);
        LibraryAssert.AreEqual(200, Status, 'the first query must succeed');

        MaskCustomerName();
        Helper.AddUserException(Scope::Field, "Bcmag Data Class"::CustomerContent, Database::Customer, Customer.FieldNo(Name), "Bcmag Read Access"::Clear, '', 0DT);
        Helper.CommitFixtures();

        // An unrelated request without the opt-out (no key, so it executes) — it reads Name in clear.
        Other := Helper.Envelope(MaskedNameQueryData('RPL-M3'));
        Response := Dispatcher.RunEx('query', Other, '', Status);
        LibraryAssert.AreEqual(200, Status, 'the in-between query must succeed');
        LibraryAssert.AreEqual('Replay Masked Three', Helper.TextField(FirstRow(Response), 'Name'), 'the exception lifts Name for a request that accepts lifts');

        Response := Dispatcher.RunEx('query', Body, '', Status);
        AssertRefusedNotReplayed(Response, Status, 403, 'field-masked', 'replayed with "unmask": false');

        RestoreClearPolicy();
        Helper.CommitFixtures();
    end;

    [Test]
    procedure ReplayOfDescribeIsRefusedOnceAFieldListedAsClearIsMasked()
    var
        Body, Data, Response: JsonObject;
        Status: Integer;
    begin
        // A stored describe that says access "clear" for a field that is Masked now would tell the client
        // the field reads, filters and sorts in clear. Refused — even when restricted fields may be
        // advertised (that switch is about readability, not about the access a field reads with).
        Helper.ConfigureOpenMode();
        Helper.ClearUserExceptions();
        Helper.SetDescribeRestrictedFields(true);
        Data.Add('kind', 'table');
        Data.Add('tableId', Database::Customer);
        Body := Helper.EnvelopeWithKey(Data, Helper.NewIdemKey());
        Helper.CommitFixtures();
        Response := Dispatcher.RunEx('describe', Body, '', Status);
        LibraryAssert.AreEqual(200, Status, 'the describe must succeed');

        MaskCustomerName();
        Helper.CommitFixtures();
        Response := Dispatcher.RunEx('describe', Body, '', Status);
        AssertRefusedNotReplayed(Response, Status, 403, 'field-masked', 'after Name is masked');

        RestoreClearPolicy();
        Helper.CommitFixtures();
        Response := Dispatcher.RunEx('describe', Body, '', Status);
        AssertReplayed(Response, Status, 'once every field is clear again');
        Helper.SetDescribeRestrictedFields(false);
        Helper.CommitFixtures();
    end;

    [Test]
    procedure ReplayOfApiDescribeIsRefusedOnceAFieldListedAsClearIsMasked()
    var
        Customer: Record Customer;
        Body, Data, Response: JsonObject;
        Scope: Option Classification,Field;
        Ordinal: Integer;
        Status: Integer;
    begin
        // describe kind "api" answers access "clear" (readable) for a mapped field a client may read
        // through the tenant API. Once that field is Masked, replaying the answer would send the client
        // to the API for a value Wicket now masks. Every other field is pinned Clear through classification
        // exceptions, so the masked displayName (Name) is the only reason to refuse.
        Helper.ConfigureOpenMode(); // AllFields: every mapped field reads clear
        Helper.ClearUserExceptions();
        Data.Add('kind', 'api');
        Data.Add('pageId', CustomersApiPageId());
        Body := Helper.EnvelopeWithKey(Data, Helper.NewIdemKey());
        Helper.CommitFixtures();
        Response := Dispatcher.RunEx('describe', Body, '', Status);
        LibraryAssert.AreEqual(200, Status, 'the api describe must succeed');

        Helper.SetFieldPolicyMode(Enum::"Bcmag Field Policy Mode"::ByClassification);
        foreach Ordinal in Enum::"Bcmag Data Class".Ordinals() do
            Helper.AddUserException(Scope::Classification, Enum::"Bcmag Data Class".FromInteger(Ordinal), 0, 0, "Bcmag Read Access"::Clear, '', 0DT);
        Helper.AddUserException(Scope::Field, "Bcmag Data Class"::CustomerContent, Database::Customer, Customer.FieldNo(Name), "Bcmag Read Access"::Masked, 'PARTIAL', 0DT);
        Helper.CommitFixtures();
        Response := Dispatcher.RunEx('describe', Body, '', Status);
        AssertRefusedNotReplayed(Response, Status, 403, 'field-masked', 'after displayName (Name) is masked');

        RestoreClearPolicy();
        Helper.CommitFixtures();
        Response := Dispatcher.RunEx('describe', Body, '', Status);
        AssertReplayed(Response, Status, 'once every field is clear again');
    end;

    local procedure CustomersApiPageId(): Integer
    var
        Discover: Codeunit "Bcmag Op Discover";
        Data, Response, Fail, Row: JsonObject;
        Tok: JsonToken;
        Cost: Integer;
    begin
        Data.Add('kind', 'apis');
        Data.Add('tableId', Database::Customer);
        Data.Add('top', 1000);
        LibraryAssert.IsTrue(Discover.Run(Data, Response, Fail, Cost), 'discover apis should succeed');
        foreach Tok in Helper.ValueArray(Response) do begin
            Row := Tok.AsObject();
            if Helper.TextField(Row, 'route') = 'v2.0/customers' then begin
                Row.Get('id', Tok);
                exit(Tok.AsValue().AsInteger());
            end;
        end;
        LibraryAssert.Fail('the v2.0/customers API page must exist');
    end;

    [Test]
    procedure ReplayOfReadBlobIsRefusedOnceTheFieldIsMasked()
    var
        Catalog: Record "Bcmag Procedure Catalog";
        Codec: Codeunit "Bcmag Record Id Codec";
        Body, Data, Response: JsonObject;
        Status: Integer;
    begin
        // The stored bytes ARE the field's clear value, and a binary has no masked form (readBlob refuses
        // a masked binary). Once the field is Masked, the stored bytes must not replay either.
        Helper.ConfigureOpenMode();
        Helper.ClearUserExceptions();
        if Catalog.Get(94318, 'ReplayProbeMasked') then
            Catalog.Delete();
        Catalog.Init();
        Catalog."Logical Codeunit Id" := 94318;
        Catalog."Procedure Name" := 'ReplayProbeMasked';
        Catalog."Wrapper Codeunit Id" := 94190;
        Catalog.SetArgsSchema('{"type":"object"}');
        Catalog.Insert();
        Data.Add('tableId', Database::"Bcmag Procedure Catalog");
        Data.Add('recordId', Codec.Encode(Catalog.RecordId));
        Data.Add('fieldNo', Catalog.FieldNo("Args Schema"));
        Body := Helper.EnvelopeWithKey(Data, Helper.NewIdemKey());
        Helper.CommitFixtures();
        Response := Dispatcher.RunEx('readBlob', Body, '', Status);
        LibraryAssert.AreEqual(200, Status, 'the readBlob must succeed');

        Helper.SetFieldPolicyMode(Enum::"Bcmag Field Policy Mode"::ByClassification);
        Helper.SetFieldAccess(Database::"Bcmag Procedure Catalog", Catalog.FieldNo("Args Schema"), "Bcmag Read Access"::Masked, '', false);
        Helper.CommitFixtures();
        Response := Dispatcher.RunEx('readBlob', Body, '', Status);
        AssertRefusedNotReplayed(Response, Status, 403, 'field-masked', 'after the field is masked');

        Helper.UnexposeField(Database::"Bcmag Procedure Catalog", Catalog.FieldNo("Args Schema"));
        Helper.SetFieldPolicyMode(Enum::"Bcmag Field Policy Mode"::AllFields);
        Catalog.Delete();
        Helper.CommitFixtures();
    end;

    [Test]
    procedure OperationLogRecordsLiftedFieldsForQueriesOnly()
    var
        Customer: Record Customer;
        Data, Body, Response: JsonObject;
        Scope: Option Classification,Field;
        Status: Integer;
        Pair: Text;
    begin
        // Name is Masked for this caller's baseline, and a user exception lifts it to Clear. A query that
        // reads it records the lift ("18:<Name>") on its Operation Log row; a describe consults the same
        // verdict but returns no field values, so its row records nothing.
        Helper.ConfigureOpenMode();
        Helper.ClearUserExceptions();
        MaskCustomerName();
        Helper.AddUserException(Scope::Field, "Bcmag Data Class"::CustomerContent, Database::Customer, Customer.FieldNo(Name), "Bcmag Read Access"::Clear, '', 0DT);
        SeedCustomer('RPL-M4', 'Lifted Name');
        Pair := Format(Database::Customer, 0, 9) + ':' + Format(Customer.FieldNo(Name), 0, 9);
        Body := Helper.Envelope(MaskedNameQueryData('RPL-M4'));
        Helper.CommitFixtures();

        Response := Dispatcher.RunEx('query', Body, '', Status);
        LibraryAssert.AreEqual(200, Status, 'the query must succeed');
        LibraryAssert.AreEqual('Lifted Name', Helper.TextField(FirstRow(Response), 'Name'), 'the exception lifts Name to clear');
        LibraryAssert.IsTrue(StrPos(UnmaskedFieldsLogged(Body), Pair) > 0,
            StrSubstNo('the query''s log row must record the lift %1, got "%2"', Pair, UnmaskedFieldsLogged(Body)));
        // The query's log writes are still uncommitted; the dispatcher's Codeunit.Run boundary refuses
        // to start inside a write transaction (on SaaS as a bare "transaction is stopped").
        Helper.CommitFixtures();

        Data.Add('kind', 'table');
        Data.Add('tableId', Database::Customer);
        Body := Helper.Envelope(Data);
        Response := Dispatcher.RunEx('describe', Body, '', Status);
        LibraryAssert.AreEqual(200, Status, 'the describe must succeed');
        LibraryAssert.AreEqual('', UnmaskedFieldsLogged(Body), 'describe returns no field values, so it logs no lifts');

        RestoreClearPolicy();
        Helper.CommitFixtures();
    end;

    local procedure UnmaskedFieldsLogged(Body: JsonObject): Text
    var
        Log: Record "Bcmag Operation Log";
        Tok: JsonToken;
    begin
        Body.Get('id', Tok);
        Log.SetRange("Request Id", Tok.AsValue().AsText());
        LibraryAssert.IsTrue(Log.FindLast(), 'the request must have an Operation Log row');
        exit(Log."Unmasked Fields");
    end;
}
