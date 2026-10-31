codeunit 94121 "Bcmag Log Purge"
{
    // Retention purge for the operation and idempotency logs (snapshots and reservations). The async
    // reaper runs it on every pass, so retention holds from install with no setup; a recurring Job Queue
    // Entry on this codeunit (Object ID 94121) still works for a schedule of one's own. Retention is
    // Wicket Setup."Operation Log Retention Days" (0 keeps everything).

    trigger OnRun()
    begin
        PurgeExpired();
    end;

    // The reaper runs as whichever user armed it — often a Read-rung caller whose async submit re-armed it —
    // and Delete on these tables is an Admin grant. Like the queue purge, the delete is INHERENT and scoped
    // to this procedure, whose filters are fixed here (rows past the configured retention), so it widens
    // nothing a caller could steer.
    [InherentPermissions(PermissionObjectType::TableData, Database::"Bcmag Operation Log", 'rd')]
    [InherentPermissions(PermissionObjectType::TableData, Database::"Bcmag Idempotency Log", 'rd')]
    [InherentPermissions(PermissionObjectType::TableData, Database::"Bcmag Idempotency Reservation", 'rd')]
    [InherentPermissions(PermissionObjectType::TableData, Database::"Bcmag Change Entry", 'rd')]
    [InherentPermissions(PermissionObjectType::TableData, Database::"Bcmag Field Change", 'rd')]
    procedure PurgeExpired()
    var
        Setup: Record "Bcmag Setup";
        OperationLog: Record "Bcmag Operation Log";
        IdempotencyLog: Record "Bcmag Idempotency Log";
        Reservation: Record "Bcmag Idempotency Reservation";
        Guard: Codeunit "Bcmag Idempotency Guard";
        Cutoff, StaleCutoff: DateTime;
        RetentionDays: Integer;
    begin
        Setup.GetSingleton();
        // The change history keeps its own retention, whatever the Operation Log's is.
        PurgeChangeHistory(Setup."Change Retention Days");
        RetentionDays := Setup."Operation Log Retention Days";
        if RetentionDays <= 0 then
            exit;
        Cutoff := CreateDateTime(CalcDate(StrSubstNo('<-%1D>', RetentionDays), Today()), 0T);

        OperationLog.SetFilter("Started At", '<%1', Cutoff);
        OperationLog.DeleteAll(false);

        IdempotencyLog.SetFilter("Logged At", '<%1', Cutoff);
        IdempotencyLog.DeleteAll(false);

        // Reservations share the snapshot's retention: once the snapshot of a key is purged, the key's
        // reservation no longer protects anything the caller can use, and without this the table grows
        // by one row per key forever. Settled rows (Completed / Released) go by when they settled. An
        // In Progress row is never purged while it may still be running: it must be older than BOTH the
        // retention cutoff and the stale window (the cutoff is whole days back, so in practice the
        // cutoff decides; the second bound keeps that true for any retention setting).
        Reservation.SetFilter(State, '%1|%2', Reservation.State::Completed, Reservation.State::Released);
        Reservation.SetFilter("Settled At", '<%1', Cutoff);
        Reservation.DeleteAll(false);

        Reservation.Reset();
        StaleCutoff := CurrentDateTime() - Guard.StaleWindow();
        if StaleCutoff < Cutoff then
            Cutoff := StaleCutoff;
        Reservation.SetRange(State, Reservation.State::"In Progress");
        Reservation.SetFilter("Reserved At", '<%1', Cutoff);
        Reservation.DeleteAll(false);
    end;

    // Change history entries older than the retention go, with their field lines. Entry numbers rise
    // with time, so the lines are removed by the highest expired entry number.
    [InherentPermissions(PermissionObjectType::TableData, Database::"Bcmag Change Entry", 'rd')]
    [InherentPermissions(PermissionObjectType::TableData, Database::"Bcmag Field Change", 'rd')]
    local procedure PurgeChangeHistory(RetentionDays: Integer)
    var
        Entry: Record "Bcmag Change Entry";
        FieldChange: Record "Bcmag Field Change";
        Cutoff: DateTime;
    begin
        if RetentionDays <= 0 then
            exit;
        Cutoff := CreateDateTime(CalcDate(StrSubstNo('<-%1D>', RetentionDays), Today()), 0T);
        Entry.SetCurrentKey("Created At");
        Entry.SetFilter("Created At", '<%1', Cutoff);
        if Entry.IsEmpty() then
            exit;
        if Entry.FindSet() then
            repeat
                FieldChange.SetRange("Entry No.", Entry."Entry No.");
                FieldChange.DeleteAll(false);
            until Entry.Next() = 0;
        Entry.DeleteAll(false);
    end;
}
