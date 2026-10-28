codeunit 94147 "Bcmag Idempotency Guard"
{
    // Takes, settles and judges execution reservations (Bcmag Idempotency Reservation). Protocol, as
    // the dispatcher applies it:
    //   Reserved     → execute; afterwards Complete (final 2xx/4xx) or Release (5xx, or a lifted-later
    //                  pre-execution refusal — see the dispatcher's IsPreExecutionRefusal).
    //   In Progress  → 409 idempotency-in-progress (same body) / idempotency-conflict (other body).
    //   Completed    → the snapshot replays; if it is missing, 409 idempotency-indeterminate.
    //   Stale        → 409 idempotency-indeterminate: the owner never settled and may have committed.
    //   Conflict     → 409 idempotency-conflict: a Released key met a different body (no take-over).
    // Reserve COMMITS the row: Codeunit.Run (the runner boundary) requires no open write transaction,
    // and a second session must be able to see the reservation.

    Access = Public;

    procedure Reserve(IdemKey: Text; BodyHash: Text; RequestId: Text; var StoredHash: Text): Enum "Bcmag Reservation Outcome"
    var
        Res: Record "Bcmag Idempotency Reservation";
    begin
        StoredHash := '';
        // Serialize per row: a concurrent Reserve for the same (caller, key) waits here until this
        // transaction commits, then sees the row this one leaves behind.
        Res.LockTable();
        if Res.Get(UserSecurityId(), KeyOf(IdemKey)) then
            exit(Judge(Res, BodyHash, RequestId, StoredHash));
        Res.Init();
        Res.Caller := UserSecurityId();
        Res."Idempotency Key" := KeyOf(IdemKey);
        TakeOver(Res, BodyHash, RequestId);
        if not Res.Insert() then begin
            // Lost the insert race to a concurrent request for the same key: judge its row instead.
            Res.Get(UserSecurityId(), KeyOf(IdemKey));
            exit(Judge(Res, BodyHash, RequestId, StoredHash));
        end;
        Commit();
        exit("Bcmag Reservation Outcome"::Reserved);
    end;

    procedure Complete(IdemKey: Text)
    begin
        Settle(IdemKey, "Bcmag Reservation State"::Completed);
    end;

    procedure Release(IdemKey: Text)
    begin
        Settle(IdemKey, "Bcmag Reservation State"::Released);
    end;

    // How long an In Progress reservation is trusted to still be running. SaaS web-service calls are
    // bounded well inside this; beyond it the owning session is presumed dead and the outcome unknown.
    procedure StaleWindow(): Duration
    begin
        exit(15 * 60000); // 15 minutes
    end;

    local procedure Judge(var Res: Record "Bcmag Idempotency Reservation"; BodyHash: Text; RequestId: Text; var StoredHash: Text): Enum "Bcmag Reservation Outcome"
    begin
        StoredHash := Res."Body Hash";
        case Res.State of
            Res.State::Released:
                begin
                    // The earlier attempt ended retryable: this attempt takes the row over — but only as
                    // the SAME logical request. A key is a promise of one request; a different body under
                    // a released key is the same contract breach as under a live one (409 conflict), and
                    // silently installing the new hash would let the key flip between two payloads.
                    if Res."Body Hash" <> CopyStr(BodyHash, 1, MaxStrLen(Res."Body Hash")) then
                        exit("Bcmag Reservation Outcome"::Conflict);
                    TakeOver(Res, BodyHash, RequestId);
                    Res.Modify();
                    Commit();
                    StoredHash := BodyHash;
                    exit("Bcmag Reservation Outcome"::Reserved);
                end;
            Res.State::Completed:
                exit("Bcmag Reservation Outcome"::Completed);
        end;
        if Res."Reserved At" < CurrentDateTime() - StaleWindow() then
            exit("Bcmag Reservation Outcome"::Stale);
        exit("Bcmag Reservation Outcome"::"In Progress");
    end;

    local procedure TakeOver(var Res: Record "Bcmag Idempotency Reservation"; BodyHash: Text; RequestId: Text)
    begin
        Res.State := Res.State::"In Progress";
        Res."Body Hash" := CopyStr(BodyHash, 1, MaxStrLen(Res."Body Hash"));
        Res."Request Id" := CopyStr(RequestId, 1, MaxStrLen(Res."Request Id"));
        Res."Reserved At" := CurrentDateTime();
        Res."Settled At" := 0DT;
    end;

    local procedure Settle(IdemKey: Text; NewState: Enum "Bcmag Reservation State")
    var
        Res: Record "Bcmag Idempotency Reservation";
    begin
        if not Res.Get(UserSecurityId(), KeyOf(IdemKey)) then
            exit;
        Res.State := NewState;
        Res."Settled At" := CurrentDateTime();
        Res.Modify();
    end;

    local procedure KeyOf(IdemKey: Text): Text[128]
    var
        Res: Record "Bcmag Idempotency Reservation";
    begin
        exit(CopyStr(IdemKey, 1, MaxStrLen(Res."Idempotency Key")));
    end;
}
