codeunit 94335 "Bcmag Async Hardening Test"
{
    Subtype = Test;
    TestPermissions = Disabled;

    // Async delivery hardening (2026-09-23 review): retention anchored on completion, UTC SAS times with
    // spr=https and a backdated start, status re-minting a SAS capped at the package's expiry, cleanup
    // only for rows that actually attempted an upload, TryEnqueue answering malformed input with typed
    // problems instead of raising, Ready SAS token vetting, and the queue retention purge. All offline:
    // Azure calls go to a dead local port (http://127.0.0.1:9) and fail deterministically.

    var
        Helper: Codeunit "Bcmag Test Helper";
        Enqueuer: Codeunit "Bcmag Async Enqueuer";
        LibraryAssert: Codeunit "Library Assert";

    // -- Retention anchored on completion (P1-1) ------------------------------------------------------

    [Test]
    procedure EnqueueLeavesExpiryBlankUntilTheRequestEnds()
    var
        Row: Record "Bcmag Request Queue";
        Dispatcher: Codeunit "Bcmag Rpc Dispatcher";
        Data, Deliver, Body, Response : JsonObject;
        Tok: JsonToken;
        Status: Integer;
    begin
        Helper.ConfigureOpenMode();
        Helper.ConfigureAsync();
        SetPackageTtlHours(5);
        Deliver.Add('mode', 'azureBlob');
        Deliver.Add('scheduleAt', Format(CurrentDateTime() + 3600000, 0, 9));
        Data.Add('tableId', Database::Customer);
        Data.Add('deliver', Deliver);
        Body := Helper.Envelope(Data);
        Helper.CommitFixtures();

        Response := Dispatcher.RunEx('query', Body, '', Status);

        Body.Get('id', Tok);
        Row.SetRange("Request Id", Tok.AsValue().AsText());
        LibraryAssert.IsTrue(Row.FindFirst(), 'the queue row for this request must exist');
        if Row.Status = Row.Status::Scheduled then begin
            // Accepted (a task scheduler exists): nothing has been produced, so there is no expiry yet.
            LibraryAssert.AreEqual(0DT, Row."Expires At", 'a non-terminal row has no expiry');
            LibraryAssert.IsTrue(Response.Get('expiresAt', Tok), 'expiresAt is part of the accepted shape');
            LibraryAssert.IsTrue(Tok.AsValue().IsNull(), 'expiresAt is null until the request completes');
        end else begin
            // CI container (no task scheduler): the request failed to start and is terminal — its
            // retention runs from that moment.
            LibraryAssert.AreEqual(Row.Status::Failed, Row.Status, 'a request that could not start is Failed');
            AssertExpiresTtlAfterCompletion(Row, 5);
        end;
    end;

    [Test]
    procedure CancelStampsExpiryFromCompletion()
    var
        Row: Record "Bcmag Request Queue";
        AsyncCancel: Codeunit "Bcmag Async Cancel";
    begin
        Helper.ConfigureOpenMode();
        Helper.ConfigureAsync();
        SetPackageTtlHours(7);
        SeedRow(Row.Status::Scheduled, 'pkg-h-cancel.ndjson', 0DT, Row."Blob Cleanup"::"Not Needed", 0);
        Row.FindLast();

        AsyncCancel.CancelRow(Row);

        Row.Get(Row."Entry No.");
        LibraryAssert.AreEqual(Row.Status::Cancelled, Row.Status, 'scheduled row is cancelled outright');
        AssertExpiresTtlAfterCompletion(Row, 7);
    end;

    [Test]
    procedure ReaperNeverExpiresOrCleansARowWithoutExpiry()
    var
        Row: Record "Bcmag Request Queue";
        Reaper: Codeunit "Bcmag Async Reaper";
        EntryNo: BigInteger;
    begin
        // A Succeeded row is Blob Cleanup = Pending while its package is live (the worker set it before
        // uploading). Neither the expiry scan (no Expires At) nor the retry scan (not Expired/Cancelled)
        // may touch it: that would delete a package its owner is still entitled to download.
        Helper.ConfigureOpenMode();
        Helper.ConfigureAsync();
        PointAzureAtDeadEndpoint();
        EntryNo := SeedRow(Row.Status::Succeeded, 'pkg-h-live.ndjson', 0DT, Row."Blob Cleanup"::Pending, 0);
        Helper.CommitFixtures();

        Reaper.RunOnce();

        Row.Get(EntryNo);
        LibraryAssert.AreEqual(Row.Status::Succeeded, Row.Status, 'a row without an expiry is never expired');
        LibraryAssert.AreEqual(0, Row."Cleanup Attempts", 'a live package is never deleted');
    end;

    // -- Cleanup only after an upload was attempted (P2-6) --------------------------------------------

    [Test]
    procedure NeverUploadedRowNeedsNoCleanupAndSendsNoDelete()
    var
        Row: Record "Bcmag Request Queue";
        Reaper: Codeunit "Bcmag Async Reaper";
        Probe: Codeunit "Bcmag Blob Request Probe";
        EntryNo: BigInteger;
        Verb, Account, Container, Endpoint : Text;
    begin
        // The enqueuer always assigns a blob name, but a request that failed in its query never uploaded.
        // Cleanup must not depend on Azure answering BlobNotFound for it: no delete is sent at all.
        Helper.ConfigureOpenMode();
        Helper.ConfigureAsync();
        PointAzureAtDeadEndpoint();
        EntryNo := SeedRow(Row.Status::Failed, 'pkg-h-never.ndjson', CurrentDateTime() - 3600000, Row."Blob Cleanup"::"Not Needed", 0);
        Helper.CommitFixtures();

        BindSubscription(Probe);
        Reaper.RunOnce();
        UnbindSubscription(Probe);

        Row.Get(EntryNo);
        LibraryAssert.AreEqual(Row.Status::Expired, Row.Status, 'retention elapsed: the request expires');
        LibraryAssert.AreEqual(Row."Blob Cleanup"::"Not Needed", Row."Blob Cleanup", 'never uploaded: nothing to clean');
        LibraryAssert.AreEqual(0, Row."Cleanup Attempts", 'no attempt counted');
        LibraryAssert.IsFalse(Probe.Seen('pkg-h-never.ndjson', Verb, Account, Container, Endpoint), 'no delete request may be sent for a never-uploaded blob');
    end;

    // -- SAS minting (P1-2, P2-4) ---------------------------------------------------------------------

    [Test]
    procedure SasTimeIsUtcIsoWithoutFraction()
    var
        Signer: Codeunit "Bcmag Sas Signer";
        Dt: DateTime;
        Formatted: Text;
    begin
        // An instant given in UTC must come back as the same UTC wall time, whatever the session's time
        // zone — a picture-string Format would render it in local time and still label it Z.
        Evaluate(Dt, '2026-01-02T03:04:05.678Z', 9);
        LibraryAssert.AreEqual('2026-01-02T03:04:05Z', Signer.FormatSasTime(Dt), 'UTC, seconds precision, Z suffix');

        Dt := CurrentDateTime();
        Formatted := Signer.FormatSasTime(Dt);
        LibraryAssert.AreEqual(20, StrLen(Formatted), 'yyyy-MM-ddTHH:mm:ssZ');
        LibraryAssert.IsTrue(Formatted.EndsWith('Z'), 'ends in Z');
        LibraryAssert.AreEqual(CopyStr(Format(Dt, 0, 9), 1, 19) + 'Z', Formatted, 'equals the ISO UTC rendering truncated to seconds');
    end;

    [Test]
    procedure MintedTokenIsHttpsOnlyAndBackdated()
    var
        Signer: Codeunit "Bcmag Sas Signer";
        UriHelper: Codeunit Uri;
        Expiry, Start : DateTime;
        Token, StText : Text;
        Ms: BigInteger;
    begin
        Helper.ConfigureOpenMode();
        Helper.ConfigureAsync(); // stores a dummy base64 account key: signing is local HMAC, no network
        Expiry := CurrentDateTime() + 3600000;
        Token := Signer.MintReadSasUntil('bcmagtest', 'packages', 'pkg-h-mint.ndjson', Expiry);

        LibraryAssert.IsTrue(StrPos(Token, '&spr=https&') > 0, 'the token must be https-only: ' + Token);
        LibraryAssert.IsTrue(StrPos(Token, '&se=' + UriHelper.EscapeDataString(Signer.FormatSasTime(Expiry)) + '&') > 0, 'se is the requested expiry in UTC');
        StText := UriHelper.UnescapeDataString(SasParam(Token, 'st'));
        LibraryAssert.IsTrue(StText.EndsWith('Z'), 'st is UTC');
        Evaluate(Start, StText, 9);
        Ms := CurrentDateTime() - Start;
        LibraryAssert.IsTrue(Ms >= 14 * 60000, 'st is backdated ~15 minutes for clock skew');

        // TTL minutes beyond Integer*60000 range (35791+) must not overflow.
        Ms := Signer.SasTtl(40000);
        LibraryAssert.AreEqual(2400000000L, Ms, 'SAS TTL is computed in BigInteger');
    end;

    [Test]
    procedure StatusRemintsTheUrlCappedAtThePackageExpiry()
    var
        Row: Record "Bcmag Request Queue";
        OpStatus: Codeunit "Bcmag Op Status";
        Signer: Codeunit "Bcmag Sas Signer";
        UriHelper: Codeunit Uri;
        Data, Response, Fail, Value : JsonObject;
        Tok: JsonToken;
        Url: Text;
        EntryNo: BigInteger;
        Cost: Integer;
    begin
        // The package lives 10 more minutes; SAS TTL is 60. The minted token must stop at the package's
        // expiry — and it is minted at status time, never read back from the row, whose stored URL (here
        // a legacy one carrying a token) must neither be returned nor shown on the queue list.
        Helper.ConfigureOpenMode();
        Helper.ConfigureAsync();
        EntryNo := SeedRow(Row.Status::Succeeded, 'pkg-h-status.ndjson', CurrentDateTime() + 600000, Row."Blob Cleanup"::Pending, 0);
        Row.Get(EntryNo);
        Row."Package Url" := 'https://bcmagtest.blob.core.windows.net/packages/pkg-h-status.ndjson?sig=legacysecret';
        Row.Modify();
        Row.Get(EntryNo); // the persisted (SQL-rounded) expiry is what status reads

        Data.Add('requestId', Row.PublicId());
        LibraryAssert.IsTrue(OpStatus.Run(Data, Response, Fail, Cost), 'own request should resolve');
        Value := Helper.ValueObject(Response);
        LibraryAssert.IsTrue(Value.Get('packageUrl', Tok), 'a succeeded request reports its URL');
        Url := Tok.AsValue().AsText();
        LibraryAssert.IsTrue(StrPos(Url, 'se=' + UriHelper.EscapeDataString(Signer.FormatSasTime(Row."Expires At"))) > 0,
            'the token must expire with the package, not SAS TTL after now: ' + Url);
        LibraryAssert.IsTrue(StrPos(Url, 'spr=https') > 0, 'https-only token');
        LibraryAssert.IsTrue(StrPos(Url, 'legacysecret') = 0, 'the stored token is never returned');
        LibraryAssert.AreEqual('https://bcmagtest.blob.core.windows.net/packages/pkg-h-status.ndjson', Row.DisplayPackageUrl(),
            'the list page shows the URL without its query string');
    end;

    // -- TryEnqueue never raises (P2-5) and validates its target (P3) --------------------------------

    [Test]
    procedure PackageAsObjectIsATyped400()
    var
        Deliver, Empty : JsonObject;
    begin
        Deliver.Add('mode', 'azureBlob');
        Deliver.Add('package', Empty);
        AssertRefused(Deliver, Database::Customer, 400, 'invalid-field');
    end;

    [Test]
    procedure NullScheduleAtIsATyped400()
    var
        Deliver: JsonObject;
        NullTok: JsonToken;
    begin
        NullTok.ReadFrom('null');
        Deliver.Add('mode', 'azureBlob');
        Deliver.Add('scheduleAt', NullTok);
        AssertRefused(Deliver, Database::Customer, 400, 'invalid-field');
    end;

    [Test]
    procedure NumericModeIsATyped400()
    var
        Deliver: JsonObject;
    begin
        Deliver.Add('mode', 5);
        AssertRefused(Deliver, Database::Customer, 400, 'invalid-deliver');
    end;

    [Test]
    procedure MissingTableIdIsRefusedAtEnqueue()
    var
        Deliver: JsonObject;
    begin
        Deliver.Add('mode', 'azureBlob');
        AssertRefused(Deliver, 0, 400, 'missing-field');
    end;

    [Test]
    procedure UnexposedTableIsRefusedAtEnqueue()
    var
        Deliver: JsonObject;
    begin
        // The queue table is hard-denied for data-plane reads in every mode: accepting the request would
        // only fail it later in the worker.
        Deliver.Add('mode', 'azureBlob');
        AssertRefused(Deliver, Database::"Bcmag Request Queue", 403, 'not-exposed');
    end;

    // -- Ready SAS token vetting (P2-9) ---------------------------------------------------------------

    [Test]
    procedure ReadySasTokenWithListPermissionIsRefused()
    var
        Deliver: JsonObject;
    begin
        UseReadySas('sv=2022-11-02&sr=c&sp=rl&se=2099-01-01T00%3A00%3A00Z&sig=x');
        Deliver.Add('mode', 'azureBlob');
        AssertRefusedWithDetail(Deliver, 403, 'async-not-configured', 'list');
    end;

    [Test]
    procedure ReadySasTokenExpiringWithinThePackageTtlIsRefused()
    var
        Signer: Codeunit "Bcmag Sas Signer";
        UriHelper: Codeunit Uri;
        Deliver: JsonObject;
    begin
        // Package TTL defaults to 24 hours; this token dies in one.
        UseReadySas('sv=2022-11-02&sr=c&sp=r&se=' + UriHelper.EscapeDataString(Signer.FormatSasTime(CurrentDateTime() + 3600000)) + '&sig=x');
        Deliver.Add('mode', 'azureBlob');
        AssertRefusedWithDetail(Deliver, 403, 'async-not-configured', 'expires');
    end;

    [Test]
    procedure LongLivedReadOnlyReadySasTokenPasses()
    var
        AzureClient: Codeunit "Bcmag Azure Client";
        Detail: Text;
    begin
        LibraryAssert.IsTrue(AzureClient.CheckReadySasToken('sv=2022-11-02&sr=c&sp=r&se=2099-01-01T00%3A00%3A00Z&sig=x', 24, Detail),
            'a read-only token valid beyond the package TTL is accepted: ' + Detail);
        LibraryAssert.IsFalse(AzureClient.CheckReadySasToken('sv=2022-11-02&sr=c&sp=w&se=2099-01-01T00%3A00%3A00Z&sig=x', 24, Detail),
            'a token without read is refused');
        LibraryAssert.IsFalse(AzureClient.CheckReadySasToken('sv=2022-11-02&sr=c&sp=rd&se=2099-01-01T00%3A00%3A00Z&sig=x', 24, Detail),
            'a token that also grants delete is refused: every package holder receives it');
        LibraryAssert.IsTrue(AzureClient.CheckReadySasToken('sv=2022-11-02&sr=c&sp=r&se=2099-01-01&sig=x', 24, Detail),
            'a date-only expiry (valid in Azure) is accepted: ' + Detail);
    end;

    // -- Queue retention purge (P3) -------------------------------------------------------------------

    [Test]
    procedure PurgeRemovesOldTerminalRowsButNeverAPendingCleanup()
    var
        Row: Record "Bcmag Request Queue";
        Setup: Record "Bcmag Setup";
        Purge: Codeunit "Bcmag Async Queue Purge";
        Reaper: Codeunit "Bcmag Async Reaper";
        OldPending, OldDone, RecentDone, OldSucceeded : BigInteger;
        FortyDaysAgo: DateTime;
    begin
        Helper.ConfigureOpenMode();
        Helper.ConfigureAsync();
        Setup.GetSingleton();
        Setup."Operation Log Retention Days" := 30;
        Setup.Modify(true);
        FortyDaysAgo := CurrentDateTime() - DaysMs(40);
        OldPending := SeedRow(Row.Status::Expired, 'pkg-h-p1.ndjson', FortyDaysAgo, Row."Blob Cleanup"::Pending, Reaper.MaxCleanupAttempts());
        OldDone := SeedRow(Row.Status::Expired, 'pkg-h-p2.ndjson', FortyDaysAgo, Row."Blob Cleanup"::Done, 1);
        RecentDone := SeedRow(Row.Status::Expired, 'pkg-h-p3.ndjson', CurrentDateTime() - DaysMs(1), Row."Blob Cleanup"::Done, 1);
        OldSucceeded := SeedRow(Row.Status::Succeeded, 'pkg-h-p4.ndjson', 0DT, Row."Blob Cleanup"::Pending, 0);
        BackdateCompletion(OldPending, FortyDaysAgo);
        BackdateCompletion(OldDone, FortyDaysAgo);
        BackdateCompletion(OldSucceeded, FortyDaysAgo);
        Helper.CommitFixtures();

        Purge.PurgeTerminal();

        LibraryAssert.IsTrue(Row.Get(OldPending), 'a row whose blob deletion is still owed is never purged');
        LibraryAssert.IsFalse(Row.Get(OldDone), 'an old terminal row with nothing owed is purged');
        LibraryAssert.IsTrue(Row.Get(RecentDone), 'a row inside the retention period is kept');
        LibraryAssert.IsTrue(Row.Get(OldSucceeded), 'a Succeeded row is never purged (it expires first)');
    end;

    // -- helpers --------------------------------------------------------------------------------------

    local procedure AssertRefused(Deliver: JsonObject; TableId: Integer; ExpectedStatus: Integer; ExpectedType: Text)
    var
        Data, Result, Fail : JsonObject;
    begin
        Helper.ConfigureOpenMode();
        Helper.ConfigureAsync();
        if TableId <> 0 then
            Data.Add('tableId', TableId);
        Data.Add('deliver', Deliver);
        LibraryAssert.IsFalse(Enqueuer.TryEnqueue('query', Data, 'req-h', 'test', '', Result, Fail), 'malformed request must be refused');
        LibraryAssert.AreEqual(ExpectedStatus, Helper.StatusOf(Fail), 'status: ' + Helper.DetailOf(Fail));
        LibraryAssert.IsTrue(StrPos(Helper.TypeOf(Fail), ExpectedType) > 0, 'expected ' + ExpectedType + ', got ' + Helper.TypeOf(Fail));
    end;

    local procedure AssertRefusedWithDetail(Deliver: JsonObject; ExpectedStatus: Integer; ExpectedType: Text; DetailFragment: Text)
    var
        Data, Result, Fail : JsonObject;
    begin
        Data.Add('tableId', Database::Customer);
        Data.Add('deliver', Deliver);
        LibraryAssert.IsFalse(Enqueuer.TryEnqueue('query', Data, 'req-h', 'test', '', Result, Fail), 'must be refused');
        LibraryAssert.AreEqual(ExpectedStatus, Helper.StatusOf(Fail), 'status');
        LibraryAssert.IsTrue(StrPos(Helper.TypeOf(Fail), ExpectedType) > 0, 'expected ' + ExpectedType);
        LibraryAssert.IsTrue(StrPos(Helper.DetailOf(Fail), DetailFragment) > 0, 'the detail must say why: ' + Helper.DetailOf(Fail));
    end;

    local procedure UseReadySas(Token: Text)
    var
        Setup: Record "Bcmag Setup";
        AzureClient: Codeunit "Bcmag Azure Client";
    begin
        Helper.ConfigureOpenMode();
        Helper.ConfigureAsync();
        Setup.GetSingleton();
        Setup."Download Mode" := Setup."Download Mode"::ReadySAS;
        Setup.Modify(true);
        AzureClient.SetReadySas(Token);
    end;

    local procedure AssertExpiresTtlAfterCompletion(Row: Record "Bcmag Request Queue"; TtlHours: Integer)
    var
        Expected, Actual, Drift : BigInteger;
    begin
        LibraryAssert.AreNotEqual(0DT, Row."Completed At", 'a terminal row records its completion');
        LibraryAssert.AreNotEqual(0DT, Row."Expires At", 'a terminal row gets its retention deadline');
        Expected := TtlHours;
        Expected := Expected * 3600000;
        Actual := Row."Expires At" - Row."Completed At";
        Drift := Actual - Expected;
        // SQL rounds each DateTime on write (to ~3 ms), independently.
        LibraryAssert.IsTrue((Drift >= -10) and (Drift <= 10), StrSubstNo('Expires At must be Completed At + %1 h (drift %2 ms)', TtlHours, Drift));
    end;

    local procedure SetPackageTtlHours(Hours: Integer)
    var
        Setup: Record "Bcmag Setup";
    begin
        Setup.GetSingleton();
        Setup."Package TTL Hours" := Hours;
        Setup.Modify(true);
    end;

    local procedure PointAzureAtDeadEndpoint()
    var
        Setup: Record "Bcmag Setup";
    begin
        Setup.GetSingleton();
        Setup."Azure Blob Endpoint" := 'http://127.0.0.1:9'; // discard port: connection refused at once
        Setup.Modify(true);
    end;

    local procedure SeedRow(Status: Enum "Bcmag Request Status"; BlobName: Text; ExpiresAt: DateTime; Cleanup: Option; Attempts: Integer): BigInteger
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
        if Row.IsTerminal() then
            Row."Completed At" := CurrentDateTime();
        Row."Expires At" := ExpiresAt;
        Row."Blob Name" := CopyStr(BlobName, 1, MaxStrLen(Row."Blob Name"));
        Row."Blob Cleanup" := Cleanup;
        Row."Cleanup Attempts" := Attempts;
        Row.Insert(true);
        exit(Row."Entry No.");
    end;

    local procedure BackdateCompletion(EntryNo: BigInteger; At: DateTime)
    var
        Row: Record "Bcmag Request Queue";
    begin
        Row.Get(EntryNo);
        Row."Created At" := At;
        Row."Completed At" := At;
        Row.Modify();
    end;

    local procedure SasParam(Token: Text; Name: Text): Text
    var
        Part: Text;
    begin
        foreach Part in Token.Split('&') do
            if Part.StartsWith(Name + '=') then
                exit(CopyStr(Part, StrLen(Name) + 2));
        exit('');
    end;

    local procedure DaysMs(Days: Integer): BigInteger
    var
        Ms: BigInteger;
    begin
        Ms := Days;
        exit(Ms * 86400000);
    end;
}
