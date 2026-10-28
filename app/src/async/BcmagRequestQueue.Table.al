table 94106 "Bcmag Request Queue"
{
    // One row per async delivery request. The row is the durable source of truth for status,
    // progress, the result URL, and errors — the platform gives no in-app job log, so this table
    // IS the log. Callers address a request by its SystemId (the public "requestId"); Entry No. is
    // the clustered surrogate. The row must be COMMITTED before a background worker runs, because a
    // background session sees only committed data (the commit-before-run rule).
    Caption = 'Wicket Request Queue';
    DataClassification = SystemMetadata;

    fields
    {
        field(1; "Entry No."; BigInteger) { Caption = 'Entry No.'; AutoIncrement = true; }
        field(10; "Status"; Enum "Bcmag Request Status") { Caption = 'Status'; }
        field(11; "Operation"; Text[30]) { Caption = 'Operation'; }
        // UserSecurityId of the submitting principal: status/cancel are scoped to this so one caller
        // can never see or cancel another's request (mirrors the idempotency caller-scoping).
        field(12; "Caller"; Guid) { Caption = 'Caller'; }
        field(13; "Origin"; Text[256]) { Caption = 'Origin'; }
        field(14; "Request Id"; Text[64]) { Caption = 'Request Id'; }          // envelope @requestId, for correlation
        field(15; "Idempotency Key"; Text[128]) { Caption = 'Idempotency Key'; }
        field(20; "Created At"; DateTime) { Caption = 'Created At'; }
        field(21; "Scheduled For"; DateTime) { Caption = 'Scheduled For'; }
        field(22; "Started At"; DateTime) { Caption = 'Started At'; }
        field(23; "Completed At"; DateTime) { Caption = 'Completed At'; }
        // Blank while the request is non-terminal; stamped Completed At + Package TTL Hours when it ends
        // (StampCompletion). Anchoring retention on COMPLETION, not enqueue, is what keeps a scheduled
        // or long-running job's package alive for the full TTL after it is actually produced.
        field(24; "Expires At"; DateTime) { Caption = 'Expires At'; }
        field(30; "Task Id"; Guid) { Caption = 'Task Id'; }                     // TaskScheduler task (scheduled track)
        field(31; "Session Id"; Integer) { Caption = 'Session Id'; }           // StartSession id (immediate track)
        field(32; "Cancel Requested"; Boolean) { Caption = 'Cancel Requested'; }
        field(33; "Attempt Count"; Integer) { Caption = 'Attempt Count'; }
        // Blob cleanup is tracked INDEPENDENTLY of Status: a request is Expired/Cancelled when its
        // lifecycle says so, but the package blob is only gone when a delete has been CONFIRMED. Not
        // Needed means no upload was ever attempted (so no blob can exist); the worker sets Pending, and
        // commits it, immediately BEFORE it uploads. Pending therefore means "a blob may exist"; once the
        // request is Expired/Cancelled the reaper deletes it, retrying up to MaxCleanupAttempts, and a
        // row that hits the cap stays Pending — visibly overdue on the queue list, never silently "done".
        field(34; "Blob Cleanup"; Option) { Caption = 'Blob Cleanup'; OptionMembers = "Not Needed",Pending,Done; OptionCaption = 'Not Needed,Pending,Done'; }
        field(35; "Cleanup Attempts"; Integer) { Caption = 'Cleanup Attempts'; }
        field(40; "Package Format"; Enum "Bcmag Package Format") { Caption = 'Package Format'; }
        // Where the package actually lives — the destination the upload used, stamped from Setup at
        // enqueue and again when the worker starts (so a scheduled job stamps what it uploads to, not
        // what Setup said days earlier). Every later blob operation (download URL, delete) targets THIS,
        // never the current Setup: an administrator who repoints Setup at another container or account
        // must not make cleanup "confirm" absence in the wrong place and strand the real package. Rows
        // from before "Blob Account"/"Blob Endpoint" existed carry them blank; the Azure client then
        // falls back to Setup for the blank parts (the best knowledge available for a legacy row).
        field(41; "Blob Container"; Text[63]) { Caption = 'Blob Container'; }
        field(42; "Blob Name"; Text[1024]) { Caption = 'Blob Name'; }
        field(48; "Blob Account"; Text[100]) { Caption = 'Blob Account'; }
        field(49; "Blob Endpoint"; Text[250]) { Caption = 'Blob Endpoint'; }
        // The package's blob URL WITHOUT any SAS query string. The caller-facing, tokenful URL is composed
        // at response time (accepted response, status) so a live bearer token is never stored where the
        // queue list or the table itself would show it. Rows written by earlier builds may still hold a
        // tokenful URL; the list page displays DisplayPackageUrl(), which strips the query.
        field(43; "Package Url"; Text[2048]) { Caption = 'Package Url'; }
        field(44; "Result Bytes"; BigInteger) { Caption = 'Result Bytes'; }
        field(45; "Result Row Count"; Integer) { Caption = 'Result Row Count'; }
        field(46; "Progress Rows"; Integer) { Caption = 'Progress Rows'; }
        field(47; "Content Type"; Text[100]) { Caption = 'Content Type'; }
        field(50; "Problem Type"; Text[250]) { Caption = 'Problem Type'; }
        // The request payload ({operation, data} snapshot) the worker re-runs, and the full error
        // text — both blobs because they can exceed a Text field and may echo caller-supplied values.
        field(60; "Request Data"; Blob) { Caption = 'Request Data'; DataClassification = CustomerContent; }
        field(61; "Last Error"; Blob) { Caption = 'Last Error'; DataClassification = CustomerContent; }
    }

    keys
    {
        key(PK; "Entry No.") { Clustered = true; }
        key(Caller; "Caller", "Status") { }            // caller-scoped status/list lookups
        key(Due; "Status", "Scheduled For") { }        // reaper / due-row scans
        key(Cleanup; "Blob Cleanup") { }               // reaper: pending blob deletions, any status
        key(CallerEntry; "Caller", "Entry No.") { }    // "requests": the caller's rows, newest first
    }

    procedure SetRequestData(Payload: Text)
    var
        OutStr: OutStream;
    begin
        Clear("Request Data");
        "Request Data".CreateOutStream(OutStr, TextEncoding::UTF8);
        OutStr.Write(Payload);
    end;

    procedure GetRequestData() Payload: Text
    var
        InStr: InStream;
    begin
        CalcFields("Request Data");
        if not "Request Data".HasValue() then
            exit('');
        "Request Data".CreateInStream(InStr, TextEncoding::UTF8);
        InStr.Read(Payload);
    end;

    procedure SetLastError(ErrorText: Text)
    var
        OutStr: OutStream;
    begin
        Clear("Last Error");
        "Last Error".CreateOutStream(OutStr, TextEncoding::UTF8);
        OutStr.Write(ErrorText);
    end;

    procedure GetLastError() ErrorText: Text
    var
        InStr: InStream;
    begin
        CalcFields("Last Error");
        if not "Last Error".HasValue() then
            exit('');
        "Last Error".CreateInStream(InStr, TextEncoding::UTF8);
        InStr.Read(ErrorText);
    end;

    procedure PublicId(): Text
    begin
        // The stable, caller-facing request id.
        exit(LowerCase(DelChr(Format(SystemId, 0, 4), '=', '{}')));
    end;

    // Terminal transition bookkeeping: Completed At now, Expires At = Completed At + Package TTL Hours.
    // Every path that ends a request (worker success/failure, cancel, stale reaping, failed start, the
    // task failure codeunit) calls this, so no terminal row is left without a retention deadline.
    procedure StampCompletion()
    var
        Setup: Record "Bcmag Setup";
        Ms: BigInteger;
    begin
        "Completed At" := CurrentDateTime();
        Setup.GetSingleton();
        Ms := Setup."Package TTL Hours";
        Ms := Ms * 3600000; // BigInteger: no Integer overflow for large TTLs
        "Expires At" := "Completed At" + Ms;
    end;

    // The stored URL minus any query string (a SAS token written by an earlier build). For display on
    // the admin list, which Audit-role users see across every caller.
    procedure DisplayPackageUrl(): Text
    var
        QueryPos: Integer;
    begin
        QueryPos := StrPos("Package Url", '?');
        if QueryPos = 0 then
            exit("Package Url");
        exit(CopyStr("Package Url", 1, QueryPos - 1));
    end;

    procedure IsTerminal(): Boolean
    begin
        exit(Status in [Status::Succeeded, Status::Failed, Status::Cancelled, Status::Expired]);
    end;
}
