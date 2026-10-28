codeunit 94154 "Bcmag Async Queue Purge"
{
    // Retention purge for the request queue, run by the reaper behind a Codeunit.Run boundary. Delete on
    // the queue is an Admin-only grant, yet the reaper runs as whichever user armed it — often a Read-rung
    // caller whose enqueue re-armed it. The purge therefore carries an INHERENT delete on the queue: it is
    // scoped to this one procedure and to rows that are already terminal and past retention, so it widens
    // nothing a caller could steer (the filters are fixed here, not taken from any request). Deletes terminal
    // rows (Failed, Cancelled, Expired) that completed longer ago than Bcmag Setup."Operation Log
    // Retention Days" — the same retention the operation and idempotency logs use; 0 or less disables it.
    // A Succeeded row is never purged here: it first expires (and its blob is cleaned) after the package
    // TTL. A row whose blob deletion is still owed (Blob Cleanup = Pending) is NEVER purged: the row is the
    // only record that a package may still sit in the container, so it stays until the delete is confirmed
    // (or, past the attempt cap, as the visible overdue signal).

    Access = Public;

    trigger OnRun()
    begin
        PurgeTerminal();
    end;

    [InherentPermissions(PermissionObjectType::TableData, Database::"Bcmag Request Queue", 'd')]
    procedure PurgeTerminal()
    var
        Setup: Record "Bcmag Setup";
        Row: Record "Bcmag Request Queue";
        Cutoff: DateTime;
    begin
        Setup.GetSingleton();
        if Setup."Operation Log Retention Days" <= 0 then
            exit;
        Cutoff := CreateDateTime(CalcDate(StrSubstNo('<-%1D>', Setup."Operation Log Retention Days"), Today()), 0T);

        Row.SetFilter(Status, '%1|%2|%3', Row.Status::Failed, Row.Status::Cancelled, Row.Status::Expired);
        Row.SetFilter("Blob Cleanup", '<>%1', Row."Blob Cleanup"::Pending);
        Row.SetFilter("Completed At", '<%1&<>%2', Cutoff, 0DT);
        Row.DeleteAll(false);

        // Terminal rows that never recorded a completion time (earlier builds): judge them by creation.
        Row.SetRange("Completed At", 0DT);
        Row.SetFilter("Created At", '<%1', Cutoff);
        Row.DeleteAll(false);
        Commit();
    end;
}
