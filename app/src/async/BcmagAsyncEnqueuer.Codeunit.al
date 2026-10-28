codeunit 94134 "Bcmag Async Enqueuer"
{
    // Accepts a query request that carries a "deliver" block and turns it into a durable queue row,
    // then hands execution to a background worker (StartSession for immediate jobs, TaskScheduler for
    // scheduled ones). Validation runs synchronously in the caller's request and returns a typed
    // problem on failure; the actual query + Azure upload happen later in the worker. The commit
    // BEFORE starting the worker is mandatory — a background session sees only committed data.
    //
    // This codeunit NEVER calls Azure (only IsConfigured / BuildDownloadUrl, both local): enqueue is
    // therefore testable without a live storage account. Only the worker touches the network.
    //
    // TryEnqueue NEVER raises. The dispatcher calls it outside its Op Runner boundary, so an escaping
    // error would skip the reservation release and the audit row. Caller input is read through the typed
    // Json Read helpers (wrong kinds are 400s, not AsValue() raises), durations are BigInteger, and the
    // body runs behind its own Codeunit.Run boundary (Bcmag Async Enqueue Run): an unexpected error comes
    // back as a 500 problem — or, once the row is committed, as a 503 start failure with the row Failed.

    Access = Public;

    var
        Problem: Codeunit "Bcmag Problem";
        JsonRead: Codeunit "Bcmag Json Read";

    procedure HasDeliver(Data: JsonObject): Boolean
    var
        Tok: JsonToken;
    begin
        exit(Data.Get('deliver', Tok) and Tok.IsObject());
    end;

    procedure TryEnqueue(Operation: Text; Data: JsonObject; RequestId: Text; Origin: Text; IdempotencyKey: Text; var Result: JsonObject; var Fail: JsonObject): Boolean
    var
        EnqueueRun: Codeunit "Bcmag Async Enqueue Run";
        ErrorText: Text;
    begin
        Clear(Result);
        Clear(Fail);
        // Codeunit.Run with a return value needs no open write transaction. Whatever the dispatcher wrote
        // before this point (the idempotency reservation) is already committed by design.
        Commit();

        // Keep the maintenance chain alive (idempotent, cheap when a reaper task is live). Behind its own
        // boundary: failing to arm the reaper must never fail the caller's request.
        ClearLastError();
        if not Codeunit.Run(Codeunit::"Bcmag Async Reaper Guard") then
            ClearLastError();

        EnqueueRun.SetRequest(Operation, Data, RequestId, Origin, IdempotencyKey);
        ClearLastError();
        if EnqueueRun.Run() or EnqueueRun.GetHasResult() then begin
            Result := EnqueueRun.GetResult();
            Fail := EnqueueRun.GetFail();
            exit(EnqueueRun.GetAccepted());
        end;

        // An AL error escaped the body. Once the row is committed the only remaining work was starting
        // the worker, so it is a start failure: mark the row Failed (it must not hold the caller's quota
        // with no worker) and answer the retryable 503. Before that nothing durable happened: 500.
        ErrorText := GetLastErrorText();
        Clear(Result);
        if EnqueueRun.GetCommittedEntryNo() <> 0 then
            exit(FailToStart(EnqueueRun.GetCommittedEntryNo(), ErrorText, Fail));
        Fail := Problem.NewFailure(500, 'internal', 'Internal error', ErrorText);
        exit(false);
    end;

    // The enqueue body; runs inside Bcmag Async Enqueue Run's Codeunit.Run boundary (see TryEnqueue).
    internal procedure EnqueueCore(Operation: Text; Data: JsonObject; RequestId: Text; Origin: Text; IdempotencyKey: Text; var Result: JsonObject; var Fail: JsonObject): Boolean
    var
        Setup: Record "Bcmag Setup";
        Row: Record "Bcmag Request Queue";
        AzureClient: Codeunit "Bcmag Azure Client";
        EnqueueRun: Codeunit "Bcmag Async Enqueue Run";
        Deliver, InnerData, Canonical: JsonObject;
        Tok: JsonToken;
        PackageFormat: Enum "Bcmag Package Format";
        ScheduledFor: DateTime;
        BlobName, PayloadText, Detail: Text;
        IsScheduled: Boolean;
        SessionId, ActiveCount: Integer;
        TaskId: Guid;
    begin
        Setup.GetSingleton();

        // 1. Async must be configured (Async Enabled + account + container + a stored credential).
        if not AzureClient.IsConfigured() then begin
            Fail := Problem.NewFailure(403, 'async-not-configured', 'Async delivery not configured',
                'async delivery is not configured');
            exit(false);
        end;

        // 1b. The DOWNLOAD half must be complete too: Stream Proxy is unbuilt, Service SAS needs the
        // account key (Shared Key upload auth), Ready SAS needs its stored read token. Otherwise the job
        // would be accepted — and later marked Succeeded — with a URL that can never be fetched.
        if not AzureClient.ValidateDownloadConfiguration(Detail) then begin
            Fail := Problem.NewFailure(403, 'async-not-configured', 'Async delivery not configured', Detail);
            exit(false);
        end;

        // 2. v1 supports async delivery for the query operation only.
        if Operation <> 'query' then begin
            Fail := Problem.NewFailure(400, 'async-unsupported-op', 'Async unsupported for operation',
                StrSubstNo('async delivery ("deliver") is supported only for operation "query", not "%1"', Operation));
            exit(false);
        end;

        // 3. Parse and validate the deliver block.
        Data.Get('deliver', Tok);
        if not JsonRead.ReadObject(Tok, 'deliver', Deliver, Fail) then
            exit(false);
        if not ValidateDeliver(Deliver, Setup, PackageFormat, ScheduledFor, IsScheduled, Fail) then
            exit(false);

        // 3b. The query's target must be readable NOW, by this caller (read-only check, same allowlist
        // and platform permission the query op applies). Otherwise the request would be accepted and fail
        // later in the worker — after holding a quota slot, and with the refusal buried in "status".
        if not CheckQueryTarget(Data, Fail) then
            exit(false);

        // 4. Backpressure: cap the caller's in-flight (non-terminal) requests. Locked, so two concurrent
        // enqueues by the same caller cannot both count below the limit and both insert; the lock lasts
        // until the commit that publishes the new row.
        Row.LockTable();
        Row.SetRange(Caller, UserSecurityId());
        Row.SetFilter(Status, '%1|%2|%3', Row.Status::Queued, Row.Status::Scheduled, Row.Status::Running);
        ActiveCount := Row.Count();
        if ActiveCount >= Setup."Max Active Requests" then begin
            Fail := Problem.NewFailure(429, 'too-many-requests', 'Too many active requests',
                StrSubstNo('you already have %1 active async requests (limit %2); wait for one to finish',
                    ActiveCount, Setup."Max Active Requests"));
            exit(false);
        end;
        Row.Reset();

        // Inner payload = the original data WITHOUT the deliver block; the worker re-runs the pure
        // query through the normal pipeline, so field policy / exposure / read-only all still hold.
        InnerData := StripDeliver(Data);
        Canonical.Add('operation', Operation);
        Canonical.Add('data', InnerData);
        Canonical.WriteTo(PayloadText);

        Row.Init();
        if IsScheduled then
            Row.Status := Row.Status::Scheduled
        else
            Row.Status := Row.Status::Queued;
        Row.Caller := UserSecurityId();
        Row.Operation := CopyStr(Operation, 1, MaxStrLen(Row.Operation));
        Row.Origin := CopyStr(Origin, 1, MaxStrLen(Row.Origin));
        Row."Request Id" := CopyStr(RequestId, 1, MaxStrLen(Row."Request Id"));
        Row."Idempotency Key" := CopyStr(IdempotencyKey, 1, MaxStrLen(Row."Idempotency Key"));
        Row."Package Format" := PackageFormat;
        AzureClient.StampDestination(Row); // where the package will live; the worker re-stamps when it starts
        Row."Created At" := CurrentDateTime();
        if IsScheduled then
            Row."Scheduled For" := ScheduledFor;
        // Expires At stays blank until the request completes: retention is anchored on completion
        // (Row.StampCompletion), so a scheduled or long job's package lives the full TTL once produced.
        Row.Insert(true); // assigns SystemId, on which PublicId (the caller-facing requestId) is based

        Row.SetRequestData(PayloadText);
        BlobName := Row.PublicId() + ExtOf(PackageFormat);
        Row."Blob Name" := CopyStr(BlobName, 1, MaxStrLen(Row."Blob Name"));
        // Only the TOKENLESS blob URL is stored; a caller-facing URL is composed at response time.
        Row."Package Url" := CopyStr(AzureClient.ComposeBlobUrl(Row), 1, MaxStrLen(Row."Package Url"));
        Row.Modify(true);

        // Commit-before-run: the worker (a separate session) must be able to read the row. The
        // accepted response is captured from this durable snapshot BEFORE the worker starts, so the
        // concurrent worker can never race the fields we return.
        Commit();
        EnqueueRun.NoteCommitted(Row."Entry No.");
        Result := BuildAcceptedResponse(Row, IsScheduled);

        // Start the runner. If the platform cannot (SaaS task/session ceilings), the row must NOT be
        // left in a non-terminal state with no worker — that would silently never deliver AND leak the
        // caller's Max Active Requests quota forever. Mark it Failed and return a retryable 503. (A
        // CreateTask that RAISES instead is caught by TryEnqueue's boundary and handled the same way.)
        if IsScheduled then begin
            if not TaskScheduler.CanCreateTask() then
                exit(FailToStart(Row."Entry No.", '', Fail));
            TaskId := TaskScheduler.CreateTask(Codeunit::"Bcmag Async Worker", Codeunit::"Bcmag Async Failure",
                true, CompanyName(), ScheduledFor, Row.RecordId());
            StoreRunnerId(Row."Entry No.", TaskId, 0);
        end else begin
            Clear(TaskId);
            if not StartSession(SessionId, Codeunit::"Bcmag Async Worker", CompanyName(), Row) then
                exit(FailToStart(Row."Entry No.", '', Fail));
            StoreRunnerId(Row."Entry No.", TaskId, SessionId);
        end;
        exit(true);
    end;

    // Persist the diagnostic runner id on a FRESH read of the row: the immediate worker runs
    // concurrently and may already have flipped the row to Running (or a terminal state), so writing
    // the stale enqueue-time snapshot back would revert its status (a lost update). Re-Get, skip if
    // already terminal, and Modify the fresh record so its status is preserved.
    local procedure StoreRunnerId(EntryNo: BigInteger; TaskId: Guid; SessionId: Integer)
    var
        Row: Record "Bcmag Request Queue";
    begin
        Row.LockTable();
        if not Row.Get(EntryNo) then
            exit;
        if Row.IsTerminal() then
            exit;
        if not IsNullGuid(TaskId) then
            Row."Task Id" := TaskId;
        if SessionId <> 0 then
            Row."Session Id" := SessionId;
        Row.Modify(true);
        Commit();
    end;

    // PlatformError: the error text when starting the worker RAISED (TryEnqueue's boundary caught it),
    // '' when the platform merely declined (CanCreateTask false / StartSession false).
    local procedure FailToStart(EntryNo: BigInteger; PlatformError: Text; var Fail: JsonObject): Boolean
    var
        Row: Record "Bcmag Request Queue";
        Detail: Text;
    begin
        Detail := 'the platform could not start a background worker (task/session capacity reached)';
        if PlatformError <> '' then
            Detail := 'the platform refused to start a background worker: ' + PlatformError;
        Row.LockTable();
        if Row.Get(EntryNo) then
            if not Row.IsTerminal() then begin
                Row.Status := Row.Status::Failed;
                Row."Problem Type" := CopyStr(Problem.TypeUri('async-start-failed'), 1, MaxStrLen(Row."Problem Type"));
                Row.SetLastError(Detail);
                Row.StampCompletion();
                Row.Modify(true);
            end;
        Commit();
        Fail := Problem.NewFailure(503, 'async-start-failed', 'Could not start async worker',
            'the platform could not start a background worker right now (task/session capacity); retry shortly');
        exit(false);
    end;

    // tableId must be a number naming a table this caller may read through Wicket right now: the
    // exposure allowlist (which also hard-denies the audit/queue tables) and the platform's
    // ReadPermission. Mirrors the query op's own checks and problem types; reads only.
    local procedure CheckQueryTarget(Data: JsonObject; var Fail: JsonObject): Boolean
    var
        Exposure: Record "Bcmag Exposure";
        RecRef: RecordRef;
        Tok: JsonToken;
        TableId: Integer;
    begin
        if not Data.Get('tableId', Tok) then begin
            Fail := Problem.NewFailure(400, 'missing-field', 'Missing tableId', 'data.tableId is required');
            exit(false);
        end;
        if not JsonRead.ReadInteger(Tok, 'tableId', TableId, Fail) then
            exit(false);
        if not Exposure.IsAllowed(Exposure."Object Type"::Table, TableId, 'read') then begin
            Fail := Problem.NewFailure(403, 'not-exposed', 'Table not exposed',
                StrSubstNo('table %1 is not exposed for read; enroll it in Wicket Exposure or switch Mode to Open', TableId));
            exit(false);
        end;
        if not TryOpenTable(RecRef, TableId) then begin
            Fail := Problem.NewFailure(403, 'not-exposed', 'Table not exposed',
                StrSubstNo('table %1 is not readable by the calling principal', TableId));
            exit(false);
        end;
        if not RecRef.ReadPermission() then begin
            RecRef.Close();
            Fail := Problem.NewFailure(403, 'not-exposed', 'Table not exposed',
                StrSubstNo('table %1 is not readable by the calling principal', TableId));
            exit(false);
        end;
        RecRef.Close();
        exit(true);
    end;

    [TryFunction]
    local procedure TryOpenTable(var RecRef: RecordRef; TableId: Integer)
    begin
        RecRef.Open(TableId);
    end;

    local procedure ValidateDeliver(Deliver: JsonObject; Setup: Record "Bcmag Setup"; var PackageFormat: Enum "Bcmag Package Format"; var ScheduledFor: DateTime; var IsScheduled: Boolean; var Fail: JsonObject): Boolean
    var
        Tok: JsonToken;
        Mode, PackageText, ScheduleText: Text;
        MaxAhead: Duration;
    begin
        if Deliver.Get('mode', Tok) then
            if JsonRead.IsNonNullValue(Tok) then
                if not JsonRead.ReadText(Tok, 'deliver.mode', Mode, Fail) then
                    exit(false);
        if Mode <> 'azureBlob' then begin
            Fail := Problem.NewFailure(400, 'invalid-deliver', 'Invalid deliver block',
                StrSubstNo('deliver.mode must be "azureBlob", not "%1"', Mode));
            exit(false);
        end;

        if Deliver.Get('package', Tok) then begin
            if not JsonRead.ReadText(Tok, 'deliver.package', PackageText, Fail) then
                exit(false);
            PackageText := LowerCase(PackageText);
            case PackageText of
                'ndjson':
                    PackageFormat := PackageFormat::Ndjson;
                'json':
                    PackageFormat := PackageFormat::Json;
                'zip':
                    PackageFormat := PackageFormat::Zip;
                else begin
                    Fail := Problem.NewFailure(400, 'invalid-deliver', 'Invalid deliver block',
                        StrSubstNo('deliver.package must be one of ndjson/json/zip, not "%1"', PackageText));
                    exit(false);
                end;
            end;
        end else
            PackageFormat := Setup."Default Package Format";

        if Deliver.Get('scheduleAt', Tok) then begin
            // A present scheduleAt must be a date-time string; null, a number or an object is a typed
            // 400 here, never an AsValue() raise (omit the member for an immediate request).
            if not JsonRead.ReadText(Tok, 'deliver.scheduleAt', ScheduleText, Fail) then
                exit(false);
            if not TryEvalDateTime(ScheduleText, ScheduledFor) then begin
                Fail := Problem.NewFailure(400, 'invalid-deliver', 'Invalid deliver block',
                    StrSubstNo('deliver.scheduleAt "%1" is not a valid RFC 3339 date-time', ScheduleText));
                exit(false);
            end;
            if ScheduledFor <= CurrentDateTime() then begin
                Fail := Problem.NewFailure(400, 'invalid-deliver', 'Invalid deliver block',
                    'deliver.scheduleAt must be in the future');
                exit(false);
            end;
            MaxAhead := DaysToDuration(Setup."Max Schedule Ahead Days");
            if ScheduledFor > CurrentDateTime() + MaxAhead then begin
                Fail := Problem.NewFailure(400, 'invalid-deliver', 'Invalid deliver block',
                    StrSubstNo('deliver.scheduleAt is further ahead than the %1-day limit', Setup."Max Schedule Ahead Days"));
                exit(false);
            end;
            IsScheduled := true;
        end;
        exit(true);
    end;

    local procedure BuildAcceptedResponse(var Row: Record "Bcmag Request Queue"; IsScheduled: Boolean) Result: JsonObject
    var
        AzureClient: Codeunit "Bcmag Azure Client";
        StatusVia, StatusData: JsonObject;
        NullTok: JsonToken;
    begin
        Result.Add('@async', true);
        Result.Add('requestId', Row.PublicId());
        if IsScheduled then
            Result.Add('status', 'scheduled')
        else
            Result.Add('status', 'queued');
        // An immediate request gets its download URL at once (composed now, never stored with a token;
        // it 404s until the package is written). A scheduled one reads it from "status" on completion.
        if not IsScheduled then
            Result.Add('packageUrl', AzureClient.BuildDownloadUrl(Row));
        NullTok.ReadFrom('null');
        if IsScheduled then
            Result.Add('scheduledFor', Format(Row."Scheduled For", 0, 9))
        else
            Result.Add('scheduledFor', NullTok.Clone());
        // Retention is anchored on completion, so no request has an expiry yet when it is accepted;
        // "status" reports expiresAt (completedAt + Package TTL) once the request has finished.
        Result.Add('expiresAt', NullTok.Clone());

        StatusData.Add('requestId', Row.PublicId());
        StatusVia.Add('operation', 'status');
        StatusVia.Add('data', StatusData);
        Result.Add('statusVia', StatusVia);
    end;

    local procedure StripDeliver(Data: JsonObject) Result: JsonObject
    var
        Serialized: Text;
    begin
        // Deep clone via round-trip, then drop the deliver member so the stored payload is the
        // pure query the worker re-runs.
        Data.WriteTo(Serialized);
        Result.ReadFrom(Serialized);
        Result.Remove('deliver');
    end;

    local procedure ExtOf(PackageFormat: Enum "Bcmag Package Format"): Text
    begin
        case PackageFormat of
            PackageFormat::Ndjson:
                exit('.ndjson');
            PackageFormat::Json:
                exit('.json');
            PackageFormat::Zip:
                exit('.zip');
        end;
        exit('.ndjson');
    end;

    local procedure DaysToDuration(Days: Integer): Duration
    var
        Ms: BigInteger;
    begin
        Ms := Days;
        Ms := Ms * 86400000;
        exit(Ms);
    end;

    [TryFunction]
    local procedure TryEvalDateTime(Input: Text; var Dt: DateTime)
    begin
        // Style 9 = XML/ISO 8601 date-time, which covers RFC 3339 input.
        Evaluate(Dt, Input, 9);
    end;
}
