codeunit 94326 "Bcmag Idempotency Guard Test"
{
    Subtype = Test;
    TestPermissions = Disabled;

    // The idempotency snapshot (Bcmag Idempotency Log) is a REPLAY cache: it is consulted before and
    // written after execution, so two identical requests that both miss it both execute, and a crash
    // between the business commit and the snapshot leaves a later retry free to run the operation
    // again. The reservation (Bcmag Idempotency Reservation, one row per caller + key, taken and
    // COMMITTED before the runner) is the execution guard. These tests pin its state machine directly
    // and then the dispatcher's use of it. True cross-session concurrency cannot be driven from a test
    // codeunit; the in-flight cases seed the reservation the way a concurrent first request would.

    var
        Helper: Codeunit "Bcmag Test Helper";
        Dispatcher: Codeunit "Bcmag Rpc Dispatcher";
        Guard: Codeunit "Bcmag Idempotency Guard";
        LibraryAssert: Codeunit "Library Assert";

    local procedure InsertData(Marker: Text) Data: JsonObject
    var
        Values: JsonObject;
    begin
        Values.Add('Description', Marker);
        Data.Add('tableId', Database::"Activity Log");
        Data.Add('values', Values);
        Data.Add('init', false);
    end;

    local procedure NewMarker(): Text
    begin
        exit('BCMAG-RSV-' + DelChr(LowerCase(Format(CreateGuid())), '<>', '{}'));
    end;

    local procedure Backdate(IdemKey: Text)
    var
        Res: Record "Bcmag Idempotency Reservation";
    begin
        Res.Get(UserSecurityId(), IdemKey);
        Res."Reserved At" := CurrentDateTime() - Guard.StaleWindow() - 60000;
        Res.Modify();
    end;

    local procedure ProblemType(Result: JsonObject): Text
    var
        Tok: JsonToken;
    begin
        if Result.Get('type', Tok) then
            exit(Tok.AsValue().AsText());
        exit('');
    end;

    // ---- state machine -------------------------------------------------------------------------

    [Test]
    procedure FirstReservationIsGrantedAndHeldInProgressForTheCaller()
    var
        Res: Record "Bcmag Idempotency Reservation";
        IdemKey, StoredHash: Text;
    begin
        IdemKey := Helper.NewIdemKey();
        LibraryAssert.AreEqual("Bcmag Reservation Outcome"::Reserved, Guard.Reserve(IdemKey, 'h1', 'req-1', StoredHash), 'a fresh key must be reserved');
        LibraryAssert.IsTrue(Res.Get(UserSecurityId(), IdemKey), 'the reservation row is keyed by the calling principal and the key');
        LibraryAssert.AreEqual("Bcmag Reservation State"::"In Progress", Res.State, 'held in progress until settled');
        LibraryAssert.AreEqual('h1', Res."Body Hash", 'the body hash is recorded');
        LibraryAssert.AreEqual('req-1', Res."Request Id", 'the request id is recorded');
        LibraryAssert.IsTrue(Res."Reserved At" <> 0DT, 'reserved-at is stamped');
    end;

    [Test]
    procedure SecondReservationWhileInProgressIsRefusedWithTheStoredHash()
    var
        IdemKey, StoredHash: Text;
    begin
        IdemKey := Helper.NewIdemKey();
        Guard.Reserve(IdemKey, 'h1', 'req-1', StoredHash);
        LibraryAssert.AreEqual("Bcmag Reservation Outcome"::"In Progress", Guard.Reserve(IdemKey, 'h1', 'req-2', StoredHash), 'an in-flight key cannot be reserved twice');
        LibraryAssert.AreEqual('h1', StoredHash, 'the caller learns the in-flight body hash to detect conflicts');
    end;

    [Test]
    procedure CompletedReservationReportsCompleted()
    var
        IdemKey, StoredHash: Text;
    begin
        IdemKey := Helper.NewIdemKey();
        Guard.Reserve(IdemKey, 'h1', 'req-1', StoredHash);
        Guard.Complete(IdemKey);
        LibraryAssert.AreEqual("Bcmag Reservation Outcome"::Completed, Guard.Reserve(IdemKey, 'h1', 'req-2', StoredHash), 'a settled key is never re-reserved');
    end;

    [Test]
    procedure ReleasedReservationCanBeTakenOverByARetry()
    var
        Res: Record "Bcmag Idempotency Reservation";
        IdemKey, StoredHash: Text;
    begin
        IdemKey := Helper.NewIdemKey();
        Guard.Reserve(IdemKey, 'h1', 'req-1', StoredHash);
        Guard.Release(IdemKey); // the first attempt ended 5xx: retryable
        LibraryAssert.AreEqual("Bcmag Reservation Outcome"::Reserved, Guard.Reserve(IdemKey, 'h1', 'req-2', StoredHash), 'a released key is reservable again by the same request');
        Res.Get(UserSecurityId(), IdemKey);
        LibraryAssert.AreEqual("Bcmag Reservation State"::"In Progress", Res.State, 'taken over');
        LibraryAssert.AreEqual('req-2', Res."Request Id", 'the new attempt owns the row');
        LibraryAssert.AreEqual('h1', Res."Body Hash", 'the hash is the request''s own');
    end;

    [Test]
    procedure ReleasedReservationWithADifferentBodyIsAConflict()
    var
        Res: Record "Bcmag Idempotency Reservation";
        IdemKey, StoredHash: Text;
    begin
        // A key is a promise of ONE request. Releasing it (5xx, or a lifted pre-execution refusal) lets
        // that request retry — not a different payload under the same key, which would silently flip
        // what the key means.
        IdemKey := Helper.NewIdemKey();
        Guard.Reserve(IdemKey, 'h1', 'req-1', StoredHash);
        Guard.Release(IdemKey);
        LibraryAssert.AreEqual("Bcmag Reservation Outcome"::Conflict, Guard.Reserve(IdemKey, 'h2', 'req-2', StoredHash), 'a different body under a released key is a conflict');
        Res.Get(UserSecurityId(), IdemKey);
        LibraryAssert.AreEqual("Bcmag Reservation State"::Released, Res.State, 'the row is untouched');
        LibraryAssert.AreEqual('h1', Res."Body Hash", 'the original hash is kept');
        LibraryAssert.AreEqual('req-1', Res."Request Id", 'the original owner is kept');
    end;

    [Test]
    procedure StaleInProgressReservationReportsStale()
    var
        IdemKey, StoredHash: Text;
    begin
        IdemKey := Helper.NewIdemKey();
        Guard.Reserve(IdemKey, 'h1', 'req-1', StoredHash);
        Backdate(IdemKey);
        LibraryAssert.AreEqual("Bcmag Reservation Outcome"::Stale, Guard.Reserve(IdemKey, 'h1', 'req-2', StoredHash), 'an attempt that never settled within the window is stale, not re-run');
    end;

    // ---- dispatcher ----------------------------------------------------------------------------

    [Test]
    procedure SuccessfulRequestMarksItsReservationCompleted()
    var
        Res: Record "Bcmag Idempotency Reservation";
        Data, Body: JsonObject;
        Tok: JsonToken;
        Status: Integer;
        IdemKey: Text;
    begin
        Helper.ConfigureOpenMode();
        IdemKey := Helper.NewIdemKey();
        Data := InsertData(NewMarker());
        Body := Helper.EnvelopeWithKey(Data, IdemKey);
        Helper.CommitFixtures();

        Dispatcher.RunEx('insert', Body, '', Status);

        LibraryAssert.AreEqual(200, Status, 'insert must succeed');
        LibraryAssert.IsTrue(Res.Get(UserSecurityId(), IdemKey), 'the request must have reserved its key');
        LibraryAssert.AreEqual("Bcmag Reservation State"::Completed, Res.State, 'a final outcome settles the reservation');
        LibraryAssert.AreEqual(Dispatcher.CanonicalHash('insert', Data), Res."Body Hash", 'the reservation carries the canonical body hash');
        Body.Get('id', Tok);
        LibraryAssert.AreEqual(Tok.AsValue().AsText(), Res."Request Id", 'the reservation names the envelope id');
    end;

    [Test]
    procedure InFlightDuplicateIsRefusedWithoutExecuting()
    var
        ActivityLog: Record "Activity Log";
        Res: Record "Bcmag Idempotency Reservation";
        Data, Body, Result: JsonObject;
        Status: Integer;
        IdemKey, Marker, StoredHash: Text;
    begin
        Helper.ConfigureOpenMode();
        IdemKey := Helper.NewIdemKey();
        Marker := NewMarker();
        Data := InsertData(Marker);
        Body := Helper.EnvelopeWithKey(Data, IdemKey);
        // A concurrent first request holds the reservation for the SAME body and has not finished.
        Guard.Reserve(IdemKey, Dispatcher.CanonicalHash('insert', Data), 'first-attempt', StoredHash);
        Helper.CommitFixtures();

        Result := Dispatcher.RunEx('insert', Body, '', Status);

        LibraryAssert.AreEqual(409, Status, 'a duplicate of an in-flight request is refused');
        LibraryAssert.IsTrue(StrPos(ProblemType(Result), 'idempotency-in-progress') > 0, 'typed as idempotency-in-progress, got ' + ProblemType(Result));
        ActivityLog.SetRange(Description, Marker);
        LibraryAssert.AreEqual(0, ActivityLog.Count(), 'the operation must NOT have executed a second time');
        Res.Get(UserSecurityId(), IdemKey);
        LibraryAssert.AreEqual('first-attempt', Res."Request Id", 'the first attempt still owns the reservation');
        LibraryAssert.AreEqual("Bcmag Reservation State"::"In Progress", Res.State, 'still in progress');
    end;

    [Test]
    procedure InFlightKeyWithDifferentBodyIsAConflict()
    var
        ActivityLog: Record "Activity Log";
        Data, Body, Result: JsonObject;
        Status: Integer;
        IdemKey, Marker, StoredHash: Text;
    begin
        Helper.ConfigureOpenMode();
        IdemKey := Helper.NewIdemKey();
        Marker := NewMarker();
        Data := InsertData(Marker);
        Body := Helper.EnvelopeWithKey(Data, IdemKey);
        Guard.Reserve(IdemKey, 'hash-of-some-other-body', 'first-attempt', StoredHash);
        Helper.CommitFixtures();

        Result := Dispatcher.RunEx('insert', Body, '', Status);

        LibraryAssert.AreEqual(409, Status, 'key reuse with another body is refused');
        LibraryAssert.IsTrue(StrPos(ProblemType(Result), 'idempotency-conflict') > 0, 'typed as idempotency-conflict, got ' + ProblemType(Result));
        ActivityLog.SetRange(Description, Marker);
        LibraryAssert.AreEqual(0, ActivityLog.Count(), 'nothing executed');
    end;

    [Test]
    procedure CompletedReservationWithoutSnapshotIsIndeterminate()
    var
        ActivityLog: Record "Activity Log";
        Data, Body, Result: JsonObject;
        Status: Integer;
        IdemKey, Marker, StoredHash: Text;
    begin
        // The crash window: the first attempt committed its business writes and settled the reservation
        // but its (best-effort) snapshot never landed. A retry must not silently execute again.
        Helper.ConfigureOpenMode();
        IdemKey := Helper.NewIdemKey();
        Marker := NewMarker();
        Data := InsertData(Marker);
        Body := Helper.EnvelopeWithKey(Data, IdemKey);
        Guard.Reserve(IdemKey, Dispatcher.CanonicalHash('insert', Data), 'first-attempt', StoredHash);
        Guard.Complete(IdemKey);
        Helper.CommitFixtures();

        Result := Dispatcher.RunEx('insert', Body, '', Status);

        LibraryAssert.AreEqual(409, Status, 'an unknowable earlier outcome is refused, not repeated');
        LibraryAssert.IsTrue(StrPos(ProblemType(Result), 'idempotency-indeterminate') > 0, 'typed as idempotency-indeterminate, got ' + ProblemType(Result));
        ActivityLog.SetRange(Description, Marker);
        LibraryAssert.AreEqual(0, ActivityLog.Count(), 'nothing executed');
    end;

    [Test]
    procedure StaleReservationIsIndeterminate()
    var
        ActivityLog: Record "Activity Log";
        Data, Body, Result: JsonObject;
        Status: Integer;
        IdemKey, Marker, StoredHash: Text;
    begin
        // The session died mid-operation: the reservation is still In Progress long past any plausible
        // request duration. Whether the business commit happened is unknown → indeterminate, not re-run.
        Helper.ConfigureOpenMode();
        IdemKey := Helper.NewIdemKey();
        Marker := NewMarker();
        Data := InsertData(Marker);
        Body := Helper.EnvelopeWithKey(Data, IdemKey);
        Guard.Reserve(IdemKey, Dispatcher.CanonicalHash('insert', Data), 'first-attempt', StoredHash);
        Backdate(IdemKey);
        Helper.CommitFixtures();

        Result := Dispatcher.RunEx('insert', Body, '', Status);

        LibraryAssert.AreEqual(409, Status, 'stale in-flight attempt is refused');
        LibraryAssert.IsTrue(StrPos(ProblemType(Result), 'idempotency-indeterminate') > 0, 'typed as idempotency-indeterminate, got ' + ProblemType(Result));
        ActivityLog.SetRange(Description, Marker);
        LibraryAssert.AreEqual(0, ActivityLog.Count(), 'nothing executed');
    end;

    [Test]
    procedure ReleasedReservationLetsTheRetryExecute()
    var
        ActivityLog: Record "Activity Log";
        Res: Record "Bcmag Idempotency Reservation";
        Data, Body: JsonObject;
        Status: Integer;
        IdemKey, Marker, StoredHash: Text;
    begin
        // The first attempt ended in a retryable 5xx and released its reservation.
        Helper.ConfigureOpenMode();
        IdemKey := Helper.NewIdemKey();
        Marker := NewMarker();
        Data := InsertData(Marker);
        Body := Helper.EnvelopeWithKey(Data, IdemKey);
        Guard.Reserve(IdemKey, Dispatcher.CanonicalHash('insert', Data), 'first-attempt', StoredHash);
        Guard.Release(IdemKey);
        Helper.CommitFixtures();

        Dispatcher.RunEx('insert', Body, '', Status);

        LibraryAssert.AreEqual(200, Status, 'the retry executes');
        ActivityLog.SetRange(Description, Marker);
        LibraryAssert.AreEqual(1, ActivityLog.Count(), 'executed exactly once');
        Res.Get(UserSecurityId(), IdemKey);
        LibraryAssert.AreEqual("Bcmag Reservation State"::Completed, Res.State, 'the retry settled the reservation');
    end;

    [Test]
    procedure RequestWithoutKeyLeavesNoReservation()
    var
        Res: Record "Bcmag Idempotency Reservation";
        Body: JsonObject;
        Tok: JsonToken;
        Status: Integer;
    begin
        Helper.ConfigureOpenMode();
        Body := Helper.Envelope(InsertData(NewMarker()));
        Helper.CommitFixtures();
        Dispatcher.RunEx('insert', Body, '', Status);
        LibraryAssert.AreEqual(200, Status, 'insert must succeed');
        Body.Get('id', Tok);
        Res.SetRange("Request Id", Tok.AsValue().AsText());
        LibraryAssert.IsTrue(Res.IsEmpty(), 'no key, no reservation');
    end;

    [Test]
    procedure CachedFinalOutcomeReplaysWithTheReservationCompleted()
    var
        Res: Record "Bcmag Idempotency Reservation";
        Data, Body, Second: JsonObject;
        Tok: JsonToken;
        Status: Integer;
        IdemKey: Text;
    begin
        // The existing replay contract is unchanged: a settled key with a snapshot replays verbatim.
        Helper.ConfigureOpenMode();
        IdemKey := Helper.NewIdemKey();
        Data := InsertData(NewMarker());
        Body := Helper.EnvelopeWithKey(Data, IdemKey);
        Helper.CommitFixtures();
        Dispatcher.RunEx('insert', Body, '', Status);
        Helper.CommitFixtures();
        Second := Dispatcher.RunEx('insert', Body, '', Status);
        LibraryAssert.AreEqual(200, Status, 'replay surfaces the stored status');
        LibraryAssert.IsTrue(Second.Get('@replayed', Tok), 'second call must be a replay');
        Res.Get(UserSecurityId(), IdemKey);
        LibraryAssert.AreEqual("Bcmag Reservation State"::Completed, Res.State, 'a replay never reopens the reservation');
    end;
}
