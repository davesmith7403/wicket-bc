codeunit 94323 "Bcmag Async Test"
{
    Subtype = Test;
    TestPermissions = Disabled;

    // Layer 3 (async engine) tests. What these PROVE locally: the synchronous halves — enqueue
    // validation ordering, the dispatcher's @async accepted-response fork, the worker's query→package
    // seam (BuildPackage, without Azure), and status/cancel caller-scoping. What still needs a LIVE
    // SANDBOX (not exercised here): real background execution (StartSession / TaskScheduler), the
    // reaper re-arming as a recurring task, and the actual Azure blob upload/download round-trip.

    var
        Helper: Codeunit "Bcmag Test Helper";
        Enqueuer: Codeunit "Bcmag Async Enqueuer";
        Worker: Codeunit "Bcmag Async Worker";
        Dispatcher: Codeunit "Bcmag Rpc Dispatcher";
        LibraryAssert: Codeunit "Library Assert";

    local procedure SeedCustomers()
    var
        Customer: Record Customer;
    begin
        if not Customer.IsEmpty() then Customer.DeleteAll();
        Customer.Init(); Customer."No." := 'A-1'; Customer.Name := 'Acme';     Customer.Insert();
        Customer.Init(); Customer."No." := 'A-2'; Customer.Name := 'Beta Ltd'; Customer.Insert();
        Customer.Init(); Customer."No." := 'A-3'; Customer.Name := 'Acme Two'; Customer.Insert();
    end;

    local procedure DeliverData(Package: Text) Data: JsonObject
    var
        Deliver: JsonObject;
    begin
        Deliver.Add('mode', 'azureBlob');
        if Package <> '' then
            Deliver.Add('package', Package);
        Data.Add('tableId', Database::Customer);
        Data.Add('deliver', Deliver);
    end;

    // -- Enqueue validation -------------------------------------------------------------------

    [Test]
    procedure DeliverOnNonQueryOpIsUnsupported()
    var
        Data, Result, Fail: JsonObject;
    begin
        Helper.ConfigureOpenMode();
        Helper.ConfigureAsync();
        Data := DeliverData('ndjson');
        LibraryAssert.IsFalse(Enqueuer.TryEnqueue('insert', Data, 'req-1', 'test', '', Result, Fail), 'should reject deliver on insert');
        LibraryAssert.AreEqual(400, Helper.StatusOf(Fail), 'expected 400');
        LibraryAssert.IsTrue(StrPos(Helper.TypeOf(Fail), 'async-unsupported-op') > 0, 'expected async-unsupported-op');
    end;

    [Test]
    procedure DeliverWhenNotConfiguredIsRejected()
    var
        Data, Result, Fail: JsonObject;
    begin
        Helper.ConfigureOpenMode();
        Helper.DisableAsync();
        Data := DeliverData('ndjson');
        LibraryAssert.IsFalse(Enqueuer.TryEnqueue('query', Data, 'req-2', 'test', '', Result, Fail), 'should reject when async off');
        LibraryAssert.AreEqual(403, Helper.StatusOf(Fail), 'expected 403');
        LibraryAssert.IsTrue(StrPos(Helper.TypeOf(Fail), 'async-not-configured') > 0, 'expected async-not-configured');
    end;

    [Test]
    procedure ScheduleAtInThePastIsInvalid()
    var
        Data, Deliver, Result, Fail: JsonObject;
    begin
        Helper.ConfigureOpenMode();
        Helper.ConfigureAsync();
        Deliver.Add('mode', 'azureBlob');
        Deliver.Add('scheduleAt', '2000-01-01T00:00:00Z');
        Data.Add('tableId', Database::Customer);
        Data.Add('deliver', Deliver);
        LibraryAssert.IsFalse(Enqueuer.TryEnqueue('query', Data, 'req-3', 'test', '', Result, Fail), 'past scheduleAt should reject');
        LibraryAssert.AreEqual(400, Helper.StatusOf(Fail), 'expected 400');
        LibraryAssert.IsTrue(StrPos(Helper.TypeOf(Fail), 'invalid-deliver') > 0, 'expected invalid-deliver');
    end;

    [Test]
    procedure ScheduleAtTooFarAheadIsInvalid()
    var
        Data, Deliver, Result, Fail: JsonObject;
        FarMs: BigInteger;
        FarDt: DateTime;
    begin
        Helper.ConfigureOpenMode();
        Helper.ConfigureAsync();
        FarMs := 100;
        FarMs := FarMs * 86400000; // 100 days, beyond the 30-day cap
        FarDt := CurrentDateTime() + FarMs;
        Deliver.Add('mode', 'azureBlob');
        Deliver.Add('scheduleAt', Format(FarDt, 0, 9));
        Data.Add('tableId', Database::Customer);
        Data.Add('deliver', Deliver);
        LibraryAssert.IsFalse(Enqueuer.TryEnqueue('query', Data, 'req-4', 'test', '', Result, Fail), 'too-far scheduleAt should reject');
        LibraryAssert.AreEqual(400, Helper.StatusOf(Fail), 'expected 400');
        LibraryAssert.IsTrue(StrPos(Helper.TypeOf(Fail), 'invalid-deliver') > 0, 'expected invalid-deliver');
    end;

    [Test]
    procedure BackpressureRejectsBeyondMaxActive()
    var
        Setup: Record "Bcmag Setup";
        Data, Result, Fail: JsonObject;
    begin
        Helper.ConfigureOpenMode();
        Helper.ConfigureAsync();
        Setup.GetSingleton();
        Setup."Max Active Requests" := 1;
        Setup.Modify(true);
        // Seed one in-flight row for this caller so the next enqueue trips the cap.
        SeedRow(UserSecurityId(), "Bcmag Request Status"::Running);
        Data := DeliverData('ndjson');
        LibraryAssert.IsFalse(Enqueuer.TryEnqueue('query', Data, 'req-5', 'test', '', Result, Fail), 'should reject over the active cap');
        LibraryAssert.AreEqual(429, Helper.StatusOf(Fail), 'expected 429');
        LibraryAssert.IsTrue(StrPos(Helper.TypeOf(Fail), 'too-many-requests') > 0, 'expected too-many-requests');
    end;

    // -- Dispatcher fork (accepted @async response) -------------------------------------------

    [Test]
    procedure DispatcherForkReturnsAsyncAcceptedResponse()
    var
        Row: Record "Bcmag Request Queue";
        Problem: Codeunit "Bcmag Problem";
        Data, Deliver, Body, Response: JsonObject;
        Tok: JsonToken;
        Status: Integer;
        FutureMs: BigInteger;
        FutureDt: DateTime;
    begin
        Helper.ConfigureOpenMode();
        Helper.ConfigureAsync();
        SeedCustomers();
        // Use a SCHEDULED deliver so the enqueue path takes the TaskScheduler branch (guarded by
        // CanCreateTask) rather than spawning a StartSession worker inside the test.
        FutureMs := 3600000; // +1h
        FutureDt := CurrentDateTime() + FutureMs;
        Deliver.Add('mode', 'azureBlob');
        Deliver.Add('package', 'ndjson');
        Deliver.Add('scheduleAt', Format(FutureDt, 0, 9));
        Data.Add('tableId', Database::Customer);
        Data.Add('deliver', Deliver);
        Body := Helper.Envelope(Data);

        Helper.CommitFixtures();
        Response := Dispatcher.RunEx('query', Body, '', Status);

        if not TaskScheduler.CanCreateTask() then begin
            // The CI container runs with EnableTaskScheduler=False, so the platform cannot create the
            // scheduled task. The contract for that case is a retryable 503 async-start-failed, with the
            // queue row marked Failed so it can neither hang "scheduled" forever nor leak the caller's
            // Max Active Requests quota. Assert that path rather than skipping.
            LibraryAssert.AreEqual(503, Status, 'without a task scheduler the enqueue must fail to start');
            LibraryAssert.IsTrue(Response.Get('type', Tok), 'problem type missing');
            LibraryAssert.IsTrue(StrPos(Tok.AsValue().AsText(), 'async-start-failed') > 0, 'expected async-start-failed');
            // Check THIS request's row (the queue stores the envelope id as Request Id): sibling tests
            // in this codeunit seed queue rows of their own, and under codeunit isolation those are
            // still present here, so a caller-wide "no non-terminal rows" check is the wrong test.
            Body.Get('id', Tok);
            Row.SetRange("Request Id", Tok.AsValue().AsText());
            LibraryAssert.IsTrue(Row.FindFirst(), 'the queue row for this request must exist');
            LibraryAssert.IsTrue(Row.Status = Row.Status::Failed, 'a request that could not start must be marked Failed, not left scheduled');
            LibraryAssert.IsTrue(StrPos(Row."Problem Type", 'async-start-failed') > 0, 'the row must carry the start failure');
            LibraryAssert.AreEqual(Problem.TypeUri('async-start-failed'), Row."Problem Type", 'the row stores the problem type URI, like every other failure path');
            exit;
        end;

        LibraryAssert.AreEqual(200, Status, 'enqueue is a success (always-200 transport, logical 200)');
        LibraryAssert.IsTrue(Response.Get('@async', Tok), '@async missing');
        LibraryAssert.IsTrue(Tok.AsValue().AsBoolean(), '@async should be true');
        LibraryAssert.IsTrue(Response.Get('requestId', Tok), 'requestId missing');
        LibraryAssert.AreNotEqual('', Tok.AsValue().AsText(), 'requestId should be non-empty');
        LibraryAssert.IsTrue(Response.Get('status', Tok), 'status missing');
        LibraryAssert.AreEqual('scheduled', Tok.AsValue().AsText(), 'expected scheduled status');
        LibraryAssert.IsTrue(Response.Get('statusVia', Tok), 'statusVia missing');
    end;

    // -- Worker package seam (no Azure) -------------------------------------------------------

    [Test]
    procedure BuildPackageNdjsonHasOneLinePerRow()
    var
        InnerData: JsonObject;
        TempBlob: Codeunit "Temp Blob";
        Fail: JsonObject;
        Select: JsonArray;
        ContentType, Content: Text;
        RowCount: Integer;
        Cancelled: Boolean;
    begin
        Helper.ConfigureOpenMode();
        SeedCustomers();
        Select.Add('No.'); Select.Add('Name');
        InnerData.Add('tableId', Database::Customer);
        InnerData.Add('select', Select);
        InnerData.Add('filter', 'startswith(Name, ''Ac'')');

        LibraryAssert.IsTrue(
            Worker.BuildPackage(0, InnerData, "Bcmag Package Format"::Ndjson, TempBlob, ContentType, RowCount, Cancelled, Fail),
            StrSubstNo('BuildPackage should succeed: %1', Helper.DetailOf(Fail)));
        LibraryAssert.IsFalse(Cancelled, 'not cancelled');
        LibraryAssert.AreEqual(2, RowCount, 'expected 2 Acme rows');
        LibraryAssert.AreEqual('application/x-ndjson', ContentType, 'ndjson content type');
        Content := Helper.TempBlobToText(TempBlob);
        LibraryAssert.IsTrue(StrPos(Content, 'Acme') > 0, 'package should contain Acme');
    end;

    [Test]
    procedure BuildPackageJsonIsAnArray()
    var
        InnerData, Fail, Parsed: JsonObject;
        TempBlob: Codeunit "Temp Blob";
        Content, ContentType: Text;
        RowCount: Integer;
        Cancelled: Boolean;
        Arr: JsonArray;
        RootTok: JsonToken;
    begin
        Helper.ConfigureOpenMode();
        SeedCustomers();
        InnerData.Add('tableId', Database::Customer);

        LibraryAssert.IsTrue(
            Worker.BuildPackage(0, InnerData, "Bcmag Package Format"::Json, TempBlob, ContentType, RowCount, Cancelled, Fail),
            'BuildPackage (json) should succeed');
        LibraryAssert.AreEqual('application/json', ContentType, 'json content type');
        Content := Helper.TempBlobToText(TempBlob);
        // The payload must parse as a JSON array of the produced rows.
        LibraryAssert.IsTrue(RootTok.ReadFrom(Content), 'json package should parse');
        LibraryAssert.IsTrue(RootTok.IsArray(), 'json package should be an array');
        Arr := RootTok.AsArray();
        LibraryAssert.AreEqual(RowCount, Arr.Count(), 'array length should match row count');
    end;

    [Test]
    procedure BuildPackageZipHasZipContentType()
    var
        InnerData, Fail: JsonObject;
        TempBlob: Codeunit "Temp Blob";
        ContentType: Text;
        RowCount: Integer;
        Cancelled: Boolean;
    begin
        Helper.ConfigureOpenMode();
        SeedCustomers();
        InnerData.Add('tableId', Database::Customer);
        LibraryAssert.IsTrue(
            Worker.BuildPackage(0, InnerData, "Bcmag Package Format"::Zip, TempBlob, ContentType, RowCount, Cancelled, Fail),
            'BuildPackage (zip) should succeed');
        LibraryAssert.AreEqual('application/zip', ContentType, 'zip content type');
        LibraryAssert.IsTrue(TempBlob.Length() > 0, 'zip package should have bytes');
    end;

    [Test]
    procedure BuildPackagePropagatesQueryProblem()
    var
        InnerData, Fail: JsonObject;
        TempBlob: Codeunit "Temp Blob";
        ContentType: Text;
        RowCount: Integer;
        Cancelled: Boolean;
    begin
        Helper.ConfigureOpenMode();
        // No tableId → the query op returns a 400 problem, which BuildPackage must surface as false.
        LibraryAssert.IsFalse(
            Worker.BuildPackage(0, InnerData, "Bcmag Package Format"::Ndjson, TempBlob, ContentType, RowCount, Cancelled, Fail),
            'BuildPackage should fail when the query op fails');
        LibraryAssert.AreEqual(400, Helper.StatusOf(Fail), 'expected the query op 400');
    end;

    // -- Status / cancel caller-scoping -------------------------------------------------------

    [Test]
    procedure StatusOfForeignRequestIsUnknown()
    var
        OpStatus: Codeunit "Bcmag Op Status";
        Row: Record "Bcmag Request Queue";
        Data, Response, Fail: JsonObject;
        Cost: Integer;
    begin
        Helper.ConfigureOpenMode();
        SeedRow(CreateGuid(), "Bcmag Request Status"::Queued); // owned by a DIFFERENT principal
        Row.FindLast();
        Data.Add('requestId', Row.PublicId());
        LibraryAssert.IsFalse(OpStatus.Run(Data, Response, Fail, Cost), 'a foreign request must not be visible');
        LibraryAssert.AreEqual(404, Helper.StatusOf(Fail), 'expected 404');
        LibraryAssert.IsTrue(StrPos(Helper.TypeOf(Fail), 'unknown-request') > 0, 'expected unknown-request');
    end;

    [Test]
    procedure StatusOfOwnRequestProjects()
    var
        OpStatus: Codeunit "Bcmag Op Status";
        Row: Record "Bcmag Request Queue";
        Data, Response, Fail, Value: JsonObject;
        Tok: JsonToken;
        Cost: Integer;
    begin
        Helper.ConfigureOpenMode();
        SeedRow(UserSecurityId(), "Bcmag Request Status"::Queued);
        Row.FindLast();
        Data.Add('requestId', Row.PublicId());
        LibraryAssert.IsTrue(OpStatus.Run(Data, Response, Fail, Cost), 'own request should resolve');
        Value := Helper.ValueObject(Response);
        LibraryAssert.IsTrue(Value.Get('status', Tok), 'status projected');
        LibraryAssert.AreEqual('queued', Tok.AsValue().AsText(), 'invariant status name expected');
    end;

    [Test]
    procedure CancelQueuedFinalisesCancelled()
    var
        OpCancel: Codeunit "Bcmag Async Cancel";
        Row: Record "Bcmag Request Queue";
        Data, Response, Fail: JsonObject;
        Cost: Integer;
    begin
        Helper.ConfigureOpenMode();
        SeedRow(UserSecurityId(), "Bcmag Request Status"::Queued);
        Row.FindLast();
        Data.Add('requestId', Row.PublicId());
        LibraryAssert.IsTrue(OpCancel.Run(Data, Response, Fail, Cost), 'cancel should succeed');
        Row.Get(Row."Entry No.");
        LibraryAssert.IsTrue(Row."Cancel Requested", 'a queued row should get the cooperative flag');
        // Queued means the worker has not started (it promotes the row to Running under the same lock
        // before doing anything), so the cancel finalises at once — a never-started request must not
        // wait for a worker that may never come.
        LibraryAssert.AreEqual("Bcmag Request Status"::Cancelled, Row.Status, 'a queued (never started) row is cancelled outright');
        LibraryAssert.AreNotEqual(0DT, Row."Expires At", 'a terminal row gets its retention deadline');
    end;

    [Test]
    procedure CancelScheduledSetsCancelled()
    var
        OpCancel: Codeunit "Bcmag Async Cancel";
        Row: Record "Bcmag Request Queue";
        Data, Response, Fail: JsonObject;
        Cost: Integer;
    begin
        Helper.ConfigureOpenMode();
        SeedRow(UserSecurityId(), "Bcmag Request Status"::Scheduled); // no real task attached
        Row.FindLast();
        Data.Add('requestId', Row.PublicId());
        LibraryAssert.IsTrue(OpCancel.Run(Data, Response, Fail, Cost), 'cancel should succeed');
        Row.Get(Row."Entry No.");
        LibraryAssert.AreEqual("Bcmag Request Status"::Cancelled, Row.Status, 'a scheduled row is cancelled outright');
    end;

    // -- Download configuration (R4) ------------------------------------------------------------
    // IsConfigured() used to check only the UPLOAD credential. Under Download Mode = Ready SAS the
    // download token is a separate secret; without it BuildDownloadUrl silently returned an unsigned
    // URL to a private blob and the worker would still mark the request Succeeded. The enqueuer must
    // refuse such a configuration up front, exactly as it already refuses Stream Proxy.

    [Test]
    procedure DeliverWithReadySasDownloadButNoTokenIsRejected()
    var
        Setup: Record "Bcmag Setup";
        AzureClient: Codeunit "Bcmag Azure Client";
        Data, Result, Fail: JsonObject;
    begin
        Helper.ConfigureOpenMode();
        Helper.ConfigureAsync();
        Setup.GetSingleton();
        Setup."Download Mode" := Setup."Download Mode"::ReadySAS;
        Setup.Modify(true);
        AzureClient.ClearReadySas();
        Data := DeliverData('ndjson');
        LibraryAssert.IsFalse(Enqueuer.TryEnqueue('query', Data, 'req-rs1', 'test', '', Result, Fail),
            'Ready SAS download without a stored token must be refused');
        LibraryAssert.AreEqual(403, Helper.StatusOf(Fail), 'expected 403');
        LibraryAssert.IsTrue(StrPos(Helper.TypeOf(Fail), 'async-not-configured') > 0, 'expected async-not-configured');
        LibraryAssert.IsTrue(StrPos(Helper.DetailOf(Fail), 'Ready SAS') > 0, 'the detail must name the missing Ready SAS token');
    end;

    [Test]
    procedure DeliverWithReadySasDownloadAndTokenPassesConfigurationCheck()
    var
        Setup: Record "Bcmag Setup";
        AzureClient: Codeunit "Bcmag Azure Client";
        Data, Deliver, Result, Fail: JsonObject;
        Accepted: Boolean;
    begin
        Helper.ConfigureOpenMode();
        Helper.ConfigureAsync();
        Setup.GetSingleton();
        Setup."Download Mode" := Setup."Download Mode"::ReadySAS;
        Setup.Modify(true);
        AzureClient.SetReadySas('sv=2022-11-02&sr=c&sp=r&sig=dummy');
        // Scheduled, so the enqueue takes the TaskScheduler branch rather than spawning a session.
        Deliver.Add('mode', 'azureBlob');
        Deliver.Add('package', 'ndjson');
        Deliver.Add('scheduleAt', Format(CurrentDateTime() + 3600000, 0, 9));
        Data.Add('tableId', Database::Customer);
        Data.Add('deliver', Deliver);
        Helper.CommitFixtures();
        Accepted := Enqueuer.TryEnqueue('query', Data, 'req-rs2', 'test', '', Result, Fail);
        // Without a task scheduler (CI container) the enqueue fails to START — a different, later
        // gate. Either way the configuration check itself must have passed.
        if not Accepted then
            LibraryAssert.IsTrue(StrPos(Helper.TypeOf(Fail), 'async-not-configured') = 0,
                'a complete Ready SAS configuration must not be refused as not configured: ' + Helper.DetailOf(Fail));
    end;

    [Test]
    procedure DeliverWithServiceSasSigningUnderReadySasUploadIsRejected()
    var
        Setup: Record "Bcmag Setup";
        Data, Result, Fail: JsonObject;
    begin
        // Service SAS signing needs the ACCOUNT KEY; with Ready SAS upload auth the stored upload
        // credential is a SAS token, so the signer would sign with the wrong secret and the download
        // URL could never work. Unsupported combination: refuse up front.
        Helper.ConfigureOpenMode();
        Helper.ConfigureAsync();
        Setup.GetSingleton();
        Setup."Azure Auth Mode" := Setup."Azure Auth Mode"::ReadySAS;
        Setup."Download Mode" := Setup."Download Mode"::ServiceSas;
        Setup.Modify(true);
        Data := DeliverData('ndjson');
        LibraryAssert.IsFalse(Enqueuer.TryEnqueue('query', Data, 'req-rs3', 'test', '', Result, Fail),
            'Service SAS download over Ready SAS upload auth must be refused');
        LibraryAssert.AreEqual(403, Helper.StatusOf(Fail), 'expected 403');
        LibraryAssert.IsTrue(StrPos(Helper.TypeOf(Fail), 'async-not-configured') > 0, 'expected async-not-configured');
        LibraryAssert.IsTrue(StrPos(Helper.DetailOf(Fail), 'Service SAS') > 0, 'the detail must name the unsupported combination');
    end;

    // -- Blob cleanup (R3) ------------------------------------------------------------------------
    // Expiry used to call DeleteBlobIfExists, ignore its result and mark the row Expired — and the
    // expiry scan only ever looked at Succeeded/Failed rows, so a failed deletion silently dropped out
    // of the retry population while the blob stayed in the container. Cleanup is now tracked on the
    // row independently of request status and retried by the reaper up to a cap. These tests point
    // the client at a dead endpoint so every delete attempt fails deterministically and offline.

    local procedure PointAzureAtDeadEndpoint()
    var
        Setup: Record "Bcmag Setup";
    begin
        Setup.GetSingleton();
        Setup."Azure Blob Endpoint" := 'http://127.0.0.1:9'; // discard port: connection refused at once
        Setup.Modify(true);
    end;

    local procedure SeedCleanupRow(Status: Enum "Bcmag Request Status"; BlobName: Text; ExpiresAt: DateTime; Cleanup: Option; Attempts: Integer) EntryNo: BigInteger
    var
        Row: Record "Bcmag Request Queue";
    begin
        Row.Init();
        Row.Status := Status;
        Row.Caller := UserSecurityId();
        Row.Operation := 'query';
        Row.Origin := 'test';
        Row."Package Format" := Row."Package Format"::Ndjson;
        Row."Created At" := CurrentDateTime();
        Row."Completed At" := CurrentDateTime();
        Row."Expires At" := ExpiresAt;
        Row."Blob Name" := CopyStr(BlobName, 1, MaxStrLen(Row."Blob Name"));
        Row."Blob Cleanup" := Cleanup;
        Row."Cleanup Attempts" := Attempts;
        Row.Insert(true);
        exit(Row."Entry No.");
    end;

    [Test]
    procedure ExpiredPackageWhoseBlobCannotBeDeletedStaysPendingCleanup()
    var
        Row: Record "Bcmag Request Queue";
        Reaper: Codeunit "Bcmag Async Reaper";
        EntryNo: BigInteger;
    begin
        Helper.ConfigureOpenMode();
        Helper.ConfigureAsync();
        PointAzureAtDeadEndpoint();
        EntryNo := SeedCleanupRow("Bcmag Request Status"::Succeeded, 'pkg-cleanup-1.ndjson', CurrentDateTime() - 3600000, Row."Blob Cleanup"::"Not Needed", 0);
        Helper.CommitFixtures();

        Reaper.RunOnce();

        Row.Get(EntryNo);
        LibraryAssert.AreEqual("Bcmag Request Status"::Expired, Row.Status, 'retention elapsed: the request must expire');
        LibraryAssert.AreEqual(Row."Blob Cleanup"::Pending, Row."Blob Cleanup", 'a failed delete must leave cleanup PENDING, not silently done');
        LibraryAssert.AreEqual(1, Row."Cleanup Attempts", 'the first attempt must be counted');
    end;

    [Test]
    procedure PendingCleanupIsRetriedOnNextReaperRun()
    var
        Row: Record "Bcmag Request Queue";
        Reaper: Codeunit "Bcmag Async Reaper";
        EntryNo: BigInteger;
    begin
        Helper.ConfigureOpenMode();
        Helper.ConfigureAsync();
        PointAzureAtDeadEndpoint();
        // Already Expired (outside the Succeeded/Failed expiry scan) with cleanup still owed.
        EntryNo := SeedCleanupRow("Bcmag Request Status"::Expired, 'pkg-cleanup-2.ndjson', CurrentDateTime() - 3600000, Row."Blob Cleanup"::Pending, 1);
        Helper.CommitFixtures();

        Reaper.RunOnce();

        Row.Get(EntryNo);
        LibraryAssert.AreEqual(Row."Blob Cleanup"::Pending, Row."Blob Cleanup", 'still undeletable: stays pending');
        LibraryAssert.AreEqual(2, Row."Cleanup Attempts", 'the reaper must retry a pending cleanup');
    end;

    [Test]
    procedure CancelledRequestWithPendingCleanupIsRetriedToo()
    var
        Row: Record "Bcmag Request Queue";
        Reaper: Codeunit "Bcmag Async Reaper";
        EntryNo: BigInteger;
    begin
        Helper.ConfigureOpenMode();
        Helper.ConfigureAsync();
        PointAzureAtDeadEndpoint();
        EntryNo := SeedCleanupRow("Bcmag Request Status"::Cancelled, 'pkg-cleanup-3.ndjson', 0DT, Row."Blob Cleanup"::Pending, 0);
        Helper.CommitFixtures();

        Reaper.RunOnce();

        Row.Get(EntryNo);
        LibraryAssert.AreEqual("Bcmag Request Status"::Cancelled, Row.Status, 'cleanup must not change the request status');
        LibraryAssert.AreEqual(1, Row."Cleanup Attempts", 'cancelled rows are part of the cleanup population');
    end;

    [Test]
    procedure PendingCleanupStopsRetryingAtTheAttemptCap()
    var
        Row: Record "Bcmag Request Queue";
        Reaper: Codeunit "Bcmag Async Reaper";
        EntryNo: BigInteger;
    begin
        Helper.ConfigureOpenMode();
        Helper.ConfigureAsync();
        PointAzureAtDeadEndpoint();
        EntryNo := SeedCleanupRow("Bcmag Request Status"::Expired, 'pkg-cleanup-4.ndjson', CurrentDateTime() - 3600000, Row."Blob Cleanup"::Pending, Reaper.MaxCleanupAttempts());
        Helper.CommitFixtures();

        Reaper.RunOnce();

        Row.Get(EntryNo);
        LibraryAssert.AreEqual(Row."Blob Cleanup"::Pending, Row."Blob Cleanup", 'a capped row stays visibly pending (overdue), never marked done');
        LibraryAssert.AreEqual(Reaper.MaxCleanupAttempts(), Row."Cleanup Attempts", 'no attempt beyond the cap');
    end;

    // -- Cleanup targets the RECORDED destination, not the current Setup ------------------------

    local procedure SeedRowAt(BlobName: Text; Account: Text; Container: Text; Endpoint: Text) EntryNo: BigInteger
    var
        Row: Record "Bcmag Request Queue";
    begin
        EntryNo := SeedCleanupRow("Bcmag Request Status"::Expired, BlobName, CurrentDateTime() - 3600000, Row."Blob Cleanup"::Pending, 0);
        Row.Get(EntryNo);
        Row."Blob Account" := CopyStr(Account, 1, MaxStrLen(Row."Blob Account"));
        Row."Blob Container" := CopyStr(Container, 1, MaxStrLen(Row."Blob Container"));
        Row."Blob Endpoint" := CopyStr(Endpoint, 1, MaxStrLen(Row."Blob Endpoint"));
        Row.Modify();
    end;

    local procedure RepointSetup(Account: Text; Container: Text; Endpoint: Text)
    var
        Setup: Record "Bcmag Setup";
    begin
        Setup.GetSingleton();
        Setup."Azure Storage Account" := CopyStr(Account, 1, MaxStrLen(Setup."Azure Storage Account"));
        Setup."Azure Blob Container" := CopyStr(Container, 1, MaxStrLen(Setup."Azure Blob Container"));
        Setup."Azure Blob Endpoint" := CopyStr(Endpoint, 1, MaxStrLen(Setup."Azure Blob Endpoint"));
        Setup.Modify(true);
    end;

    [Test]
    procedure CleanupDeletesWhereThePackageWasUploadedNotWhereSetupPointsNow()
    var
        Row: Record "Bcmag Request Queue";
        Reaper: Codeunit "Bcmag Async Reaper";
        Probe: Codeunit "Bcmag Blob Request Probe";
        EntryNo: BigInteger;
        Verb, Account, Container, Endpoint: Text;
    begin
        // The package was uploaded to account A / container A (recorded on the row). The administrator
        // then repoints Setup at account B / container B. Cleanup must still address A: a BlobNotFound
        // from B would otherwise mark cleanup Done while the package sits in A forever. Both endpoints
        // are dead ports, so the delete fails either way — the probe shows where it was AIMED.
        Helper.ConfigureOpenMode();
        Helper.ConfigureAsync();
        EntryNo := SeedRowAt('pkg-moved-1.ndjson', 'accounta', 'container-a', 'http://127.0.0.1:9');
        RepointSetup('accountb', 'container-b', 'http://127.0.0.1:10');
        Helper.CommitFixtures();

        BindSubscription(Probe);
        Reaper.RunOnce();
        UnbindSubscription(Probe);

        LibraryAssert.IsTrue(Probe.Seen('pkg-moved-1.ndjson', Verb, Account, Container, Endpoint), 'a delete must have been attempted for the row''s blob');
        LibraryAssert.AreEqual('delete', Verb, 'the attempt is a delete');
        LibraryAssert.AreEqual('accounta', Account, 'delete must address the RECORDED account');
        LibraryAssert.AreEqual('container-a', Container, 'delete must address the RECORDED container');
        LibraryAssert.AreEqual('http://127.0.0.1:9', Endpoint, 'delete must address the RECORDED endpoint');

        Row.Get(EntryNo);
        LibraryAssert.AreEqual(Row."Blob Cleanup"::Pending, Row."Blob Cleanup", 'unreachable old destination: cleanup stays pending, never done');
        LibraryAssert.AreEqual(1, Row."Cleanup Attempts", 'the attempt is counted');
    end;

    [Test]
    procedure LegacyRowWithoutRecordedAccountFallsBackToSetupForTheMissingParts()
    var
        Reaper: Codeunit "Bcmag Async Reaper";
        Probe: Codeunit "Bcmag Blob Request Probe";
        Verb, Account, Container, Endpoint: Text;
    begin
        // A row stamped before Blob Account / Blob Endpoint existed carries only its container. The
        // container it recorded wins; account and endpoint come from Setup (the only knowledge left).
        Helper.ConfigureOpenMode();
        Helper.ConfigureAsync();
        SeedRowAt('pkg-legacy-1.ndjson', '', 'container-old', '');
        RepointSetup('accountnow', 'container-now', 'http://127.0.0.1:9');
        Helper.CommitFixtures();

        BindSubscription(Probe);
        Reaper.RunOnce();
        UnbindSubscription(Probe);

        LibraryAssert.IsTrue(Probe.Seen('pkg-legacy-1.ndjson', Verb, Account, Container, Endpoint), 'a delete must have been attempted for the row''s blob');
        LibraryAssert.AreEqual('container-old', Container, 'the recorded container must win over Setup');
        LibraryAssert.AreEqual('accountnow', Account, 'a blank recorded account falls back to Setup');
        LibraryAssert.AreEqual('http://127.0.0.1:9', Endpoint, 'the endpoint follows the account it belongs to');
    end;

    [Test]
    procedure RecordedAccountWithoutEndpointMeansTheDefaultEndpointNotSetups()
    var
        Row: Record "Bcmag Request Queue";
        AzureClient: Codeunit "Bcmag Azure Client";
        EntryNo: BigInteger;
    begin
        // An endpoint belongs to its account: a row stamped with account A and no endpoint lives at A's
        // default public endpoint, even if Setup now names a custom endpoint for account B.
        Helper.ConfigureOpenMode();
        Helper.ConfigureAsync();
        EntryNo := SeedRowAt('pkg-default-ep.ndjson', 'accounta', 'container-a', '');
        RepointSetup('accountb', 'container-b', 'http://127.0.0.1:10');
        Row.Get(EntryNo);

        LibraryAssert.AreEqual('https://accounta.blob.core.windows.net/container-a/pkg-default-ep.ndjson',
            AzureClient.ComposeBlobUrl(Row), 'the URL is composed from the recorded destination');
    end;

    [Test]
    procedure EnqueueRecordsTheDestinationOnTheRow()
    var
        Row: Record "Bcmag Request Queue";
        Data, Deliver, Body, Response: JsonObject;
        Tok: JsonToken;
        Status: Integer;
    begin
        // Whatever the enqueue outcome (accepted, or 503 when the container has no task scheduler), the
        // row exists and carries the destination Setup held at that moment.
        Helper.ConfigureOpenMode();
        Helper.ConfigureAsync();
        RepointSetup('stampacct', 'stamp-container', 'http://127.0.0.1:9');
        SeedCustomers();
        Deliver.Add('mode', 'azureBlob');
        Deliver.Add('package', 'ndjson');
        Deliver.Add('scheduleAt', Format(CurrentDateTime() + 3600000, 0, 9));
        Data.Add('tableId', Database::Customer);
        Data.Add('deliver', Deliver);
        Body := Helper.Envelope(Data);
        Helper.CommitFixtures();

        Response := Dispatcher.RunEx('query', Body, '', Status);

        Body.Get('id', Tok);
        Row.SetRange("Request Id", Tok.AsValue().AsText());
        LibraryAssert.IsTrue(Row.FindFirst(), 'the queue row for this request must exist');
        LibraryAssert.AreEqual('stampacct', Row."Blob Account", 'account recorded at enqueue');
        LibraryAssert.AreEqual('stamp-container', Row."Blob Container", 'container recorded at enqueue');
        LibraryAssert.AreEqual('http://127.0.0.1:9', Row."Blob Endpoint", 'endpoint recorded at enqueue');
    end;

    [Test]
    procedure ExpiredPackageWithoutBlobNeedsNoCleanup()
    var
        Row: Record "Bcmag Request Queue";
        Reaper: Codeunit "Bcmag Async Reaper";
        EntryNo: BigInteger;
    begin
        Helper.ConfigureOpenMode();
        Helper.ConfigureAsync();
        PointAzureAtDeadEndpoint();
        EntryNo := SeedCleanupRow("Bcmag Request Status"::Failed, '', CurrentDateTime() - 3600000, Row."Blob Cleanup"::"Not Needed", 0);
        Helper.CommitFixtures();

        Reaper.RunOnce();

        Row.Get(EntryNo);
        LibraryAssert.AreEqual("Bcmag Request Status"::Expired, Row.Status, 'retention elapsed: the request must expire');
        LibraryAssert.AreEqual(Row."Blob Cleanup"::"Not Needed", Row."Blob Cleanup", 'no blob, nothing to clean');
        LibraryAssert.AreEqual(0, Row."Cleanup Attempts", 'no attempt without a blob');
    end;

    local procedure SeedRow(Caller: Guid; Status: Enum "Bcmag Request Status")
    var
        Row: Record "Bcmag Request Queue";
    begin
        Row.Init();
        Row.Status := Status;
        Row.Caller := Caller;
        Row.Operation := 'query';
        Row.Origin := 'test';
        Row."Package Format" := Row."Package Format"::Ndjson;
        Row."Created At" := CurrentDateTime();
        Row.Insert(true);
    end;
}
