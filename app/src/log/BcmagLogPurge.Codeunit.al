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
    // to these procedures, whose filters are fixed here (rows past the configured retention), so it widens
    // nothing a caller could steer.
    //
    // Every table is purged in slices of entry numbers, each slice committed: the requests running
    // meanwhile insert into these same tables (the audit row, the idempotency snapshot, the reservation),
    // and one delete across a backlog would hold its locks until the end — the audit row and the
    // snapshot are best-effort and would be lost silently, the reservation would time out.
    procedure PurgeExpired()
    var
        Setup: Record "Bcmag Setup";
        Cutoff: DateTime;
        RetentionDays: Integer;
    begin
        Setup.GetSingleton();
        // The change history keeps its own retention, whatever the Operation Log's is.
        PurgeChangeHistory(Setup."Change Retention Days");
        RetentionDays := Setup."Operation Log Retention Days";
        if RetentionDays <= 0 then
            exit;
        Cutoff := CreateDateTime(CalcDate(StrSubstNo('<-%1D>', RetentionDays), Today()), 0T);
        PurgeOperationLog(Cutoff);
        PurgeIdempotencyLog(Cutoff);
        PurgeReservations(Cutoff);
    end;

    // Upper case on purpose: a lower-case letter declares an INDIRECT permission, which does nothing for
    // a caller that holds no right of its own on the table — the purge then fails for every
    // non-administrator, silently, since the maintenance pass only logs it (found 2026-11-10).
    [InherentPermissions(PermissionObjectType::TableData, Database::"Bcmag Operation Log", 'RD')]
    local procedure PurgeOperationLog(Cutoff: DateTime)
    var
        OperationLog: Record "Bcmag Operation Log";
    begin
        OperationLog.SetFilter("Started At", '<%1', Cutoff);
        while OperationLog.FindFirst() do begin
            OperationLog.SetRange("Entry No.", OperationLog."Entry No.", OperationLog."Entry No." + SliceSize() - 1);
            OperationLog.DeleteAll(false);
            Commit();
            OperationLog.SetRange("Entry No.");
        end;
    end;

    [InherentPermissions(PermissionObjectType::TableData, Database::"Bcmag Idempotency Log", 'RD')]
    local procedure PurgeIdempotencyLog(Cutoff: DateTime)
    var
        IdempotencyLog: Record "Bcmag Idempotency Log";
    begin
        IdempotencyLog.SetFilter("Logged At", '<%1', Cutoff);
        while IdempotencyLog.FindFirst() do begin
            IdempotencyLog.SetRange("Entry No.", IdempotencyLog."Entry No.", IdempotencyLog."Entry No." + SliceSize() - 1);
            IdempotencyLog.DeleteAll(false);
            Commit();
            IdempotencyLog.SetRange("Entry No.");
        end;
    end;

    // Reservations share the snapshot's retention: once the snapshot of a key is purged, the key's
    // reservation no longer protects anything the caller can use, and without this the table grows
    // by one row per key forever. Settled rows (Completed / Released) go by when they settled. An
    // In Progress row is never purged while it may still be running: it must be older than BOTH the
    // retention cutoff and the stale window (the cutoff is whole days back, so in practice the
    // cutoff decides; the second bound keeps that true for any retention setting).
    [InherentPermissions(PermissionObjectType::TableData, Database::"Bcmag Idempotency Reservation", 'RD')]
    local procedure PurgeReservations(Cutoff: DateTime)
    var
        Reservation: Record "Bcmag Idempotency Reservation";
        Guard: Codeunit "Bcmag Idempotency Guard";
        StaleCutoff: DateTime;
    begin
        Reservation.SetFilter(State, '%1|%2', Reservation.State::Completed, Reservation.State::Released);
        Reservation.SetFilter("Settled At", '<%1', Cutoff);
        Reservation.DeleteAll(false);
        Commit();

        Reservation.Reset();
        StaleCutoff := CurrentDateTime() - Guard.StaleWindow();
        if StaleCutoff < Cutoff then
            Cutoff := StaleCutoff;
        Reservation.SetRange(State, Reservation.State::"In Progress");
        Reservation.SetFilter("Reserved At", '<%1', Cutoff);
        Reservation.DeleteAll(false);
        Commit();
    end;

    // Change history entries older than the retention go, with their field lines: a slice of entry
    // numbers at a time, the lines of each expired entry first, then the entries, then a commit.
    [InherentPermissions(PermissionObjectType::TableData, Database::"Bcmag Change Entry", 'RD')]
    [InherentPermissions(PermissionObjectType::TableData, Database::"Bcmag Field Change", 'RD')]
    local procedure PurgeChangeHistory(RetentionDays: Integer)
    var
        Entry: Record "Bcmag Change Entry";
        FieldChange: Record "Bcmag Field Change";
        Cutoff: DateTime;
    begin
        if RetentionDays <= 0 then
            exit;
        Cutoff := CreateDateTime(CalcDate(StrSubstNo('<-%1D>', RetentionDays), Today()), 0T);
        Entry.SetFilter("Created At", '<%1', Cutoff);
        while Entry.FindFirst() do begin
            Entry.SetRange("Entry No.", Entry."Entry No.", Entry."Entry No." + SliceSize() - 1);
            if Entry.FindSet() then
                repeat
                    FieldChange.SetRange("Entry No.", Entry."Entry No.");
                    FieldChange.DeleteAll(false);
                until Entry.Next() = 0;
            Entry.DeleteAll(false);
            Commit();
            Entry.SetRange("Entry No.");
        end;
    end;

    local procedure SliceSize(): Integer
    begin
        exit(5000);
    end;
}
