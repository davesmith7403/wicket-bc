codeunit 94137 "Bcmag Async Reaper"
{
    // Maintenance task that (a) fails rows stuck Running past a generous timeout (a worker session that
    // died without finishing), (b) expires Succeeded/Failed rows past their retention and deletes the
    // blob — retrying any deletion that could not be CONFIRMED on Expired/Cancelled rows — (c) purges
    // terminal rows past the log retention period, and (d) RE-ARMS itself — the platform has no
    // recurring-task primitive, so each run schedules the next. It re-arms FIRST and commits that, so a
    // fault anywhere in the run cannot end the chain; the task's failure codeunit ("Bcmag Async Reaper
    // Guard") re-arms again if even that did not stick. Ensure() (called from Install/Upgrade and, cheaply,
    // from every enqueue) creates a task if none is live; the live task id is tracked in IsolatedStorage
    // so Ensure stays idempotent without depending on the Base App.
    //
    // No lock is held across an HTTP call: the blob phases collect row keys first, then per row make the
    // delete call unlocked, re-read the row under LockTable, re-check it is still eligible, apply the
    // outcome and commit.

    Access = Public;

    var
        ReaperTaskKeyLbl: Label 'BcmagReaperTaskId', Locked = true;
        ReaperNextAtKeyLbl: Label 'BcmagReaperNextAt', Locked = true;
        StaleErrLbl: Label 'the worker session ended without completing the request (stale)', Locked = true;
        CleanupTelemetryIdTok: Label 'WICKET-0002', Locked = true;
        PurgeTelemetryIdTok: Label 'WICKET-0004', Locked = true;
        LogPurgeTelemetryIdTok: Label 'WICKET-0005', Locked = true;
        LogPurgeFailedLbl: Label 'Wicket: operation log retention purge failed (%1)', Locked = true;
        TaskIdAtStart: Text;

    trigger OnRun()
    begin
        TaskIdAtStart := StoredTaskIdText();
        Rearm();
        Commit(); // the successor task is durable before any maintenance work can fail
        RunOnce();
    end;

    procedure RunOnce()
    begin
        FailStaleRunning();
        FailStuckPending();
        // Retry BEFORE expiring: a package that expires in this run gets its first delete attempt from
        // ExpirePackages; if that fails it waits for the next run, one attempt per interval.
        RetryPendingCleanups();
        ExpirePackages();
        PurgeTerminalRows();
        PurgeOperationLogs();
    end;

    // Upper bound on delete attempts per package. Past it the row stays "Blob Cleanup = Pending" with
    // the cap as its attempt count — the overdue signal an operator acts on (telemetry WICKET-0002 fires
    // once, when the cap is reached). Each attempt is one HTTP call, one per reaper interval.
    procedure MaxCleanupAttempts(): Integer
    begin
        exit(12);
    end;

    // One delete attempt for the row's blob, recorded on the row (the caller Modifies). Composition of
    // AttemptDelete (the HTTP call, no database access) and ApplyCleanup (the bookkeeping); callers that
    // must not hold a lock across the call use the two halves separately.
    procedure CleanupBlob(var Row: Record "Bcmag Request Queue")
    var
        Attempted, Confirmed: Boolean;
        ErrorText: Text;
    begin
        AttemptDelete(Row, Attempted, Confirmed, ErrorText);
        ApplyCleanup(Row, Attempted, Confirmed, ErrorText);
    end;

    // The delete call, only when a blob may exist (Blob Cleanup = Pending: the worker set it before it
    // uploaded). Not Needed means no upload was ever attempted, so there is nothing to delete and no
    // reliance on the service answering BlobNotFound for a name it never saw. Targets the destination
    // RECORDED on the row, never today's Setup — "confirmed absent" must mean absent where the package
    // was put. Writes nothing.
    procedure AttemptDelete(Row: Record "Bcmag Request Queue"; var Attempted: Boolean; var Confirmed: Boolean; var ErrorText: Text)
    var
        AzureClient: Codeunit "Bcmag Azure Client";
    begin
        Attempted := false;
        Confirmed := false;
        ErrorText := '';
        if (Row."Blob Name" = '') or (Row."Blob Cleanup" <> Row."Blob Cleanup"::Pending) then
            exit;
        Attempted := true;
        Confirmed := AzureClient.RemoveBlob(Row, ErrorText);
    end;

    // Bookkeeping for one AttemptDelete outcome on (a fresh read of) the row: Done only when the blob is
    // CONFIRMED absent, else still Pending with the attempt counted.
    procedure ApplyCleanup(var Row: Record "Bcmag Request Queue"; Attempted: Boolean; Confirmed: Boolean; ErrorText: Text)
    begin
        if Row."Blob Name" = '' then begin
            Row."Blob Cleanup" := Row."Blob Cleanup"::"Not Needed";
            exit;
        end;
        if not Attempted then
            exit;
        Row."Cleanup Attempts" += 1;
        if Confirmed then begin
            Row."Blob Cleanup" := Row."Blob Cleanup"::Done;
            exit;
        end;
        Row."Blob Cleanup" := Row."Blob Cleanup"::Pending;
        if Row."Cleanup Attempts" = MaxCleanupAttempts() then
            Session.LogMessage(CleanupTelemetryIdTok,
                StrSubstNo('Wicket async: blob cleanup for request %1 gave up after %2 attempts (%3)', Row.PublicId(), Row."Cleanup Attempts", ErrorText),
                Verbosity::Warning, DataClassification::SystemMetadata, TelemetryScope::ExtensionPublisher, 'requestId', Row.PublicId());
    end;

    // Arm a reaper task per company if one is not already live. Called from Install/Upgrade, from the
    // Guard (the reaper task's failure codeunit) and from every enqueue — cheap when a task is live (one
    // IsolatedStorage read + TaskExists), and idempotent: it never starts a second chain.
    procedure Ensure()
    begin
        if not ReaperTaskLive() then
            ScheduleNext(CurrentDateTime() + IntervalDuration());
    end;

    local procedure FailStaleRunning()
    var
        Row: Record "Bcmag Request Queue";
        Cutoff: DateTime;
    begin
        Cutoff := CurrentDateTime() - StaleTimeoutDuration();
        Row.SetRange(Status, Row.Status::Running);
        Row.SetFilter("Started At", '<%1', Cutoff);
        MarkSetStale(Row);
    end;

    // Orphan guard: a row that was accepted but whose worker never actually ran — a StartSession that
    // succeeded yet died before setting Running, or a scheduled task cancelled/lost externally. Such a
    // row would otherwise sit non-terminal forever, holding a slot against the caller's Max Active
    // Requests. Queued rows are judged by Created At (Started At is still blank); a Scheduled row is only
    // stuck once its time is well past and it still never promoted to Running.
    local procedure FailStuckPending()
    var
        Row: Record "Bcmag Request Queue";
        Cutoff: DateTime;
    begin
        Cutoff := CurrentDateTime() - StaleTimeoutDuration();
        Row.SetRange(Status, Row.Status::Queued);
        Row.SetFilter("Created At", '<%1', Cutoff);
        MarkSetStale(Row);

        Row.Reset();
        Row.SetRange(Status, Row.Status::Scheduled);
        Row.SetFilter("Scheduled For", '<%1&<>%2', Cutoff, 0DT);
        MarkSetStale(Row);
    end;

    // No HTTP in here, so the locked FindSet(true) loop is fine. A stale row whose worker had begun an
    // upload keeps Blob Cleanup = Pending; it expires after the TTL like any Failed row and is cleaned then.
    local procedure MarkSetStale(var Row: Record "Bcmag Request Queue")
    var
        Problem: Codeunit "Bcmag Problem";
    begin
        if Row.FindSet(true) then
            repeat
                Row.Status := Row.Status::Failed;
                Row."Problem Type" := CopyStr(Problem.TypeUri('async-stale'), 1, MaxStrLen(Row."Problem Type"));
                Row.SetLastError(StaleErrLbl);
                Row.StampCompletion();
                Row.Modify(true);
            until Row.Next() = 0;
        Commit();
    end;

    // Succeeded/Failed rows past Expires At become Expired and get their first delete attempt. Expires At
    // is blank on non-terminal rows (and on terminal rows from before it was stamped at completion) —
    // never "expired".
    local procedure ExpirePackages()
    var
        Row: Record "Bcmag Request Queue";
        Keys: List of [BigInteger];
        EntryNo: BigInteger;
    begin
        Row.SetFilter(Status, '%1|%2', Row.Status::Succeeded, Row.Status::Failed);
        Row.SetFilter("Expires At", '<%1&<>%2', CurrentDateTime(), 0DT);
        if Row.FindSet() then
            repeat
                Keys.Add(Row."Entry No.");
            until Row.Next() = 0;
        foreach EntryNo in Keys do
            ExpireOne(EntryNo);
    end;

    local procedure ExpireOne(EntryNo: BigInteger)
    var
        Row, Fresh : Record "Bcmag Request Queue";
        Attempted, Confirmed : Boolean;
        ErrorText: Text;
    begin
        if not Row.Get(EntryNo) then
            exit;
        if not IsExpirable(Row) then
            exit;
        MarkLegacyUpload(Row);
        AttemptDelete(Row, Attempted, Confirmed, ErrorText); // HTTP, no lock held

        Fresh.LockTable();
        if Fresh.Get(EntryNo) then
            if IsExpirable(Fresh) then begin
                MarkLegacyUpload(Fresh);
                Fresh.Status := Fresh.Status::Expired;
                ApplyCleanup(Fresh, Attempted, Confirmed, ErrorText);
                Fresh.Modify(true);
            end;
        Commit();
    end;

    local procedure IsExpirable(Row: Record "Bcmag Request Queue"): Boolean
    begin
        exit((Row.Status in [Row.Status::Succeeded, Row.Status::Failed]) and
             (Row."Expires At" <> 0DT) and (Row."Expires At" < CurrentDateTime()));
    end;

    // A Succeeded row has, by definition, uploaded its package. Rows that succeeded before the worker
    // began recording Pending ahead of its upload still say Not Needed; treat them as owing a delete.
    local procedure MarkLegacyUpload(var Row: Record "Bcmag Request Queue")
    begin
        if (Row.Status = Row.Status::Succeeded) and (Row."Blob Name" <> '') and
           (Row."Blob Cleanup" = Row."Blob Cleanup"::"Not Needed")
        then
            Row."Blob Cleanup" := Row."Blob Cleanup"::Pending;
    end;

    // Every Expired or Cancelled row whose blob deletion is still owed gets one more attempt per run
    // until it is confirmed gone or the cap is reached. Only those statuses: a Succeeded row is Pending
    // while its package is live, and must not lose it before it expires. The keys are collected first,
    // so the loop never modifies the sort key (Blob Cleanup) of a set it is iterating.
    local procedure RetryPendingCleanups()
    var
        Row: Record "Bcmag Request Queue";
        Keys: List of [BigInteger];
        EntryNo: BigInteger;
    begin
        Row.SetCurrentKey("Blob Cleanup");
        Row.SetRange("Blob Cleanup", Row."Blob Cleanup"::Pending);
        Row.SetFilter("Cleanup Attempts", '<%1', MaxCleanupAttempts());
        if Row.FindSet() then
            repeat
                if IsRetryable(Row) then
                    Keys.Add(Row."Entry No.");
            until Row.Next() = 0;
        foreach EntryNo in Keys do
            RetryOne(EntryNo);
    end;

    local procedure RetryOne(EntryNo: BigInteger)
    var
        Row, Fresh : Record "Bcmag Request Queue";
        Attempted, Confirmed : Boolean;
        ErrorText: Text;
    begin
        if not Row.Get(EntryNo) then
            exit;
        if not IsRetryable(Row) then
            exit;
        AttemptDelete(Row, Attempted, Confirmed, ErrorText); // HTTP, no lock held

        Fresh.LockTable();
        if Fresh.Get(EntryNo) then
            if IsRetryable(Fresh) then begin
                ApplyCleanup(Fresh, Attempted, Confirmed, ErrorText);
                Fresh.Modify(true);
            end;
        Commit();
    end;

    local procedure IsRetryable(Row: Record "Bcmag Request Queue"): Boolean
    begin
        exit((Row.Status in [Row.Status::Expired, Row.Status::Cancelled]) and
             (Row."Blob Cleanup" = Row."Blob Cleanup"::Pending) and
             (Row."Cleanup Attempts" < MaxCleanupAttempts()));
    end;

    // Retention of the queue rows themselves (Bcmag Setup."Operation Log Retention Days", shared with the
    // logs). Deleting needs Delete on the queue table, which only Wicket - Admin grants — and the reaper
    // runs as whichever user armed it. So the purge runs behind its own Codeunit.Run boundary: a
    // permission refusal is logged (WICKET-0004) and the rest of the maintenance is unaffected.
    local procedure PurgeTerminalRows()
    begin
        Commit(); // Codeunit.Run with a return value needs no open write transaction
        ClearLastError();
        if not Codeunit.Run(Codeunit::"Bcmag Async Queue Purge") then
            Session.LogMessage(PurgeTelemetryIdTok,
                StrSubstNo('Wicket async: queue retention purge failed (%1)', GetLastErrorText()),
                Verbosity::Warning, DataClassification::SystemMetadata, TelemetryScope::ExtensionPublisher, 'phase', 'purge');
    end;

    // Retention of the Operation Log, idempotency snapshots and reservations, so that "Operation Log
    // Retention Days" holds from the moment the app is installed. Codeunit 94121 was meant to be put on a
    // Job Queue Entry by hand, but the core app cannot create one (Job Queue Entry belongs to the Base
    // Application) and a tenant that never set one up kept every row forever — request details included.
    // The reaper already runs on its own schedule, so it runs the purge too; a Job Queue Entry on 94121
    // still works alongside it (purging twice deletes nothing twice). Same boundary as the queue purge: the
    // purge carries its own inherent delete, and Execute on it is inherent HERE only — running 94121 by hand stays
    // an Admin right — so it works whichever user armed the reaper; a failure is logged (WICKET-0005)
    // without stopping the rest of the maintenance.
    [InherentPermissions(PermissionObjectType::Codeunit, Codeunit::"Bcmag Log Purge", 'X')]
    local procedure PurgeOperationLogs()
    begin
        Commit();
        ClearLastError();
        if not Codeunit.Run(Codeunit::"Bcmag Log Purge") then
            Session.LogMessage(LogPurgeTelemetryIdTok,
                StrSubstNo(LogPurgeFailedLbl, GetLastErrorText()),
                Verbosity::Warning, DataClassification::SystemMetadata, TelemetryScope::ExtensionPublisher, 'phase', 'log-purge');
    end;

    local procedure Rearm()
    begin
        // Ensure() cannot be used here: this run's own task may still count as live. Skip only when a
        // DIFFERENT live task was armed since this run started (an enqueue's Ensure raced us) — that
        // one is already the successor.
        if (StoredTaskIdText() <> TaskIdAtStart) and ReaperTaskLive() then
            exit;
        // Two chains can exist (two enqueues re-arming a dead chain at the same moment). A run cannot
        // learn its own task id, but it can see that the recorded task is live and not due for at
        // least another minute — then it is someone else's future run, the successor already exists,
        // and this chain ends here instead of doubling the maintenance forever.
        if ReaperTaskLive() and (StoredNextAt() > CurrentDateTime() + 60000) then
            exit;
        ScheduleNext(CurrentDateTime() + IntervalDuration());
    end;

    local procedure ScheduleNext(NotBefore: DateTime)
    var
        EmptyRecId: RecordId;
        TaskId: Guid;
    begin
        if not TaskScheduler.CanCreateTask() then
            exit;
        TaskId := TaskScheduler.CreateTask(Codeunit::"Bcmag Async Reaper", Codeunit::"Bcmag Async Reaper Guard", true, CompanyName(), NotBefore, EmptyRecId);
        IsolatedStorage.Set(ReaperTaskKeyLbl, Format(TaskId), DataScope::Company);
        IsolatedStorage.Set(ReaperNextAtKeyLbl, Format(NotBefore, 0, 9), DataScope::Company);
    end;

    local procedure StoredTaskIdText(): Text
    var
        StoredText: Text;
    begin
        if IsolatedStorage.Get(ReaperTaskKeyLbl, DataScope::Company, StoredText) then
            exit(StoredText);
        exit('');
    end;

    local procedure StoredNextAt(): DateTime
    var
        StoredText: Text;
        NextAt: DateTime;
    begin
        if not IsolatedStorage.Get(ReaperNextAtKeyLbl, DataScope::Company, StoredText) then
            exit(0DT);
        if not Evaluate(NextAt, StoredText, 9) then
            exit(0DT);
        exit(NextAt);
    end;

    local procedure ReaperTaskLive(): Boolean
    var
        TaskId: Guid;
        StoredText: Text;
    begin
        StoredText := StoredTaskIdText();
        if StoredText = '' then
            exit(false);
        if not Evaluate(TaskId, StoredText) then
            exit(false);
        exit((not IsNullGuid(TaskId)) and TaskScheduler.TaskExists(TaskId));
    end;

    local procedure StaleTimeoutDuration(): Duration
    var
        Ms: BigInteger;
    begin
        // 13 hours — comfortably beyond a background session's own ~12h ceiling, so only a genuinely
        // dead worker trips it.
        Ms := 13;
        Ms := Ms * 3600000;
        exit(Ms);
    end;

    local procedure IntervalDuration(): Duration
    var
        Ms: BigInteger;
    begin
        Ms := 4;
        Ms := Ms * 3600000; // re-arm every 4 hours
        exit(Ms);
    end;
}
