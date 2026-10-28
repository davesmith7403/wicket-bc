table 94110 "Bcmag Idempotency Reservation"
{
    // Execution reservation for an idempotency key — the guarantee the snapshot log cannot give. The
    // Bcmag Idempotency Log is a replay CACHE: read before, written (best-effort) after the operation,
    // so two identical requests that both miss it both execute, and a crash between the business commit
    // and the snapshot lets a later retry run the operation again. This row is taken and COMMITTED
    // before the runner: its primary key (caller, key) makes the second concurrent request's Insert
    // fail, and its State survives a crash so a retry meets "In Progress" (later: stale) instead of a
    // clean miss. Caller-scoped like the snapshot, so one principal can never block or read another.
    // No Delete for data-plane roles: a row is released (5xx) or completed, never removed by callers.
    Caption = 'Wicket Idempotency Reservation';
    DataClassification = SystemMetadata;
    Access = Public;

    fields
    {
        field(1; Caller; Guid) { Caption = 'Caller'; }                                 // UserSecurityId of the requesting principal
        field(2; "Idempotency Key"; Text[128]) { Caption = 'Idempotency Key'; }
        field(10; State; Enum "Bcmag Reservation State") { Caption = 'State'; }
        field(11; "Body Hash"; Text[128]) { Caption = 'Body Hash'; }                   // canonical {operation, data} SHA-256 of the owning attempt
        field(12; "Request Id"; Text[64]) { Caption = 'Request Id'; }                  // envelope id of the owning attempt (correlation)
        field(20; "Reserved At"; DateTime) { Caption = 'Reserved At'; }
        field(21; "Settled At"; DateTime) { Caption = 'Settled At'; }
    }

    keys
    {
        key(PK; Caller, "Idempotency Key") { Clustered = true; }
    }
}
