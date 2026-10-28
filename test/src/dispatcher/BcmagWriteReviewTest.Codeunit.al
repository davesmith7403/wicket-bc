codeunit 94340 "Bcmag Write Review Test"
{
    Subtype = Test;
    TestPermissions = Disabled;

    // Regression tests for the 2026-09-23 dispatcher / write-plane review: pre-execution refusals do not
    // burn an idempotency key; the key-required, trigger-bypass and primary-key policies; the action
    // op's ownership of args.preview and its argument hygiene; replay re-authorization of pageUrl by
    // table name and of undecodable projections; reservation retention.

    var
        Dispatcher: Codeunit "Bcmag Rpc Dispatcher";
        Helper: Codeunit "Bcmag Test Helper";
        LibraryAssert: Codeunit "Library Assert";
        EchoActionTok: Label 'bcmag-test-echo', Locked = true;

    // ---- helpers ------------------------------------------------------------------------------------

    local procedure InsertData(Marker: Text) Data: JsonObject
    var
        Values: JsonObject;
    begin
        Values.Add('Description', Marker);
        Data.Add('tableId', Database::"Activity Log");
        Data.Add('values', Values);
    end;

    local procedure NewMarker(): Text
    begin
        exit('BCMAG-WRV-' + DelChr(LowerCase(Format(CreateGuid())), '<>', '{}'));
    end;

    local procedure HasSnapshot(IdemKey: Text): Boolean
    var
        IdempotencyLog: Record "Bcmag Idempotency Log";
    begin
        IdempotencyLog.SetRange("Idempotency Key", IdemKey);
        exit(not IdempotencyLog.IsEmpty());
    end;

    local procedure ReservationState(IdemKey: Text): Enum "Bcmag Reservation State"
    var
        Res: Record "Bcmag Idempotency Reservation";
    begin
        Res.Get(UserSecurityId(), IdemKey);
        exit(Res.State);
    end;

    local procedure AssertType(Response: JsonObject; Slug: Text; Context: Text)
    begin
        LibraryAssert.IsTrue(StrPos(Helper.TypeOf(Response), Slug) > 0, Context + ': expected ' + Slug + ', got ' + Helper.TypeOf(Response));
    end;

    local procedure ActionData(Args: JsonObject) Data: JsonObject
    begin
        Data.Add('action', EchoActionTok);
        Data.Add('args', Args);
    end;

    local procedure RunAction(Data: JsonObject; var Response: JsonObject; var Fail: JsonObject): Boolean
    var
        OpAction: Codeunit "Bcmag Op Action";
        Cost: Integer;
    begin
        Helper.CommitFixtures();
        exit(OpAction.Run(Data, Response, Fail, Cost));
    end;

    local procedure SeedCustomer(No: Code[20]) Customer: Record Customer
    begin
        if Customer.Get(No) then
            Customer.Delete();
        Customer.Init();
        Customer."No." := No;
        Customer.Name := 'Write Review';
        Customer.Insert();
    end;

    // ---- F3: pre-execution refusals never burn the key ------------------------------------------------

    [Test]
    procedure ReadOnlyRefusalReleasesTheKeyAndTheSameKeyRunsOnceWritesAreBack()
    var
        ActivityLog: Record "Activity Log";
        Body, Response: JsonObject;
        Status: Integer;
        IdemKey, Marker: Text;
    begin
        // A refusal raised before anything executed, for a reason an administrator can lift, is not the
        // key's final answer: nothing is snapshotted, the reservation is released, and the caller's
        // faithful retry with the SAME key runs once the gate is lifted.
        Helper.ConfigureOpenMode();
        Helper.SetReadOnlyMode(true);
        IdemKey := Helper.NewIdemKey();
        Marker := NewMarker();
        Body := Helper.EnvelopeWithKey(InsertData(Marker), IdemKey);
        Helper.CommitFixtures();

        Response := Dispatcher.RunEx('insert', Body, '', Status);
        LibraryAssert.AreEqual(403, Status, 'read-only refuses the insert');
        AssertType(Response, 'read-only', 'first attempt');
        LibraryAssert.IsFalse(HasSnapshot(IdemKey), 'a lifted-later refusal is not snapshotted');
        LibraryAssert.IsTrue(ReservationState(IdemKey) = "Bcmag Reservation State"::Released, 'the reservation is released, not completed');

        Helper.SetReadOnlyMode(false);
        Helper.CommitFixtures();
        Response := Dispatcher.RunEx('insert', Body, '', Status);
        LibraryAssert.AreEqual(200, Status, 'the same key executes once writes are back');
        ActivityLog.SetRange(Description, Marker);
        LibraryAssert.AreEqual(1, ActivityLog.Count(), 'executed exactly once');
        LibraryAssert.IsTrue(ReservationState(IdemKey) = "Bcmag Reservation State"::Completed, 'the successful attempt settles the key');
    end;

    [Test]
    procedure NotExposedRefusalDoesNotBurnTheKey()
    var
        Body, Response: JsonObject;
        Status: Integer;
        IdemKey: Text;
    begin
        Helper.ConfigureAllowlistedMode();
        Helper.ExposeTable(Database::"Activity Log", true, false, false, false);
        IdemKey := Helper.NewIdemKey();
        Body := Helper.EnvelopeWithKey(InsertData(NewMarker()), IdemKey);
        Helper.CommitFixtures();

        Response := Dispatcher.RunEx('insert', Body, '', Status);
        LibraryAssert.AreEqual(403, Status, 'insert is not exposed');
        AssertType(Response, 'not-exposed', 'first attempt');
        LibraryAssert.IsFalse(HasSnapshot(IdemKey), 'not snapshotted');

        Helper.ExposeTable(Database::"Activity Log", true, true, false, false);
        Helper.CommitFixtures();
        Response := Dispatcher.RunEx('insert', Body, '', Status);
        LibraryAssert.AreEqual(200, Status, 'the same key executes once the table is exposed');
    end;

    [Test]
    procedure AsyncNotConfiguredRefusalIsNotSnapshotted()
    var
        Data, Deliver, Body, Response: JsonObject;
        Status: Integer;
        IdemKey: Text;
    begin
        Helper.ConfigureOpenMode();
        Helper.DisableAsync();
        Deliver.Add('mode', 'azureBlob');
        Data.Add('tableId', Database::Customer);
        Data.Add('deliver', Deliver);
        IdemKey := Helper.NewIdemKey();
        Body := Helper.EnvelopeWithKey(Data, IdemKey);
        Helper.CommitFixtures();

        Response := Dispatcher.RunEx('query', Body, '', Status);
        LibraryAssert.AreEqual(403, Status, 'async is not configured');
        AssertType(Response, 'async-not-configured', 'deliver');
        LibraryAssert.IsFalse(HasSnapshot(IdemKey), 'not snapshotted');
        LibraryAssert.IsTrue(ReservationState(IdemKey) = "Bcmag Reservation State"::Released, 'released');
    end;

    [Test]
    procedure FinalValidationFailureStillSettlesTheKey()
    var
        Data, Body, Response: JsonObject;
        Status: Integer;
        IdemKey: Text;
    begin
        // Contrast: a malformed request is the request's own fault and stays final.
        Helper.ConfigureOpenMode();
        Data.Add('tableId', Database::"Activity Log"); // no values
        IdemKey := Helper.NewIdemKey();
        Body := Helper.EnvelopeWithKey(Data, IdemKey);
        Helper.CommitFixtures();
        Response := Dispatcher.RunEx('insert', Body, '', Status);
        LibraryAssert.AreEqual(400, Status, 'missing values is a 400');
        LibraryAssert.IsTrue(HasSnapshot(IdemKey), 'a final 4xx is snapshotted');
        LibraryAssert.IsTrue(ReservationState(IdemKey) = "Bcmag Reservation State"::Completed, 'and settles the key');
    end;

    // ---- W2: idempotency key required for action / invoke --------------------------------------------

    [Test]
    procedure ActionAndInvokeWithoutKeyAreRefusedWhenKeysAreRequired()
    var
        Data, Body, Response: JsonObject;
        Status: Integer;
    begin
        Helper.ConfigureOpenMode();
        Helper.SetRequireKeyForActions(true);
        Data.Add('action', 'bcmag-no-such-action');
        Body := Helper.Envelope(Data);
        Helper.CommitFixtures();
        Response := Dispatcher.RunEx('action', Body, '', Status);
        LibraryAssert.AreEqual(400, Status, 'keyless action is refused');
        AssertType(Response, 'idempotency-key-required', 'action');

        Clear(Data);
        Data.Add('codeunitId', 94190);
        Data.Add('procedure', 'Ping');
        Body := Helper.Envelope(Data);
        Helper.CommitFixtures();
        Response := Dispatcher.RunEx('invoke', Body, '', Status);
        LibraryAssert.AreEqual(400, Status, 'keyless invoke is refused');
        AssertType(Response, 'idempotency-key-required', 'invoke');

        // With a key the request reaches the handler (here: an unknown action).
        Clear(Data);
        Data.Add('action', 'bcmag-no-such-action');
        Body := Helper.EnvelopeWithKey(Data, Helper.NewIdemKey());
        Helper.CommitFixtures();
        Response := Dispatcher.RunEx('action', Body, '', Status);
        LibraryAssert.AreEqual(404, Status, 'a keyed action reaches the handler');
        Helper.SetRequireKeyForActions(false);
    end;

    [Test]
    procedure ActionWithoutKeyRunsWhenKeysAreNotRequired()
    var
        Data, Body, Response: JsonObject;
        Status: Integer;
    begin
        Helper.ConfigureOpenMode(); // pins Require Key For Actions = false (upgrade behaviour)
        Data.Add('action', 'bcmag-no-such-action');
        Body := Helper.Envelope(Data);
        Helper.CommitFixtures();
        Response := Dispatcher.RunEx('action', Body, '', Status);
        LibraryAssert.AreEqual(404, Status, 'without the requirement a keyless action reaches the handler');
    end;

    [Test]
    procedure FreshSetupRequiresKeysAndRefusesTriggerBypass()
    var
        Setup: Record "Bcmag Setup";
    begin
        // The fresh-install defaults (InitValue) are the safe ones; Bcmag Upgrade flips a PRE-EXISTING
        // singleton (marker false) to the compatible ones instead.
        Setup.Init();
        LibraryAssert.IsTrue(Setup."Require Key For Actions", 'fresh default: key required');
        LibraryAssert.IsFalse(Setup."Allow Trigger Bypass", 'fresh default: no trigger bypass');
        LibraryAssert.IsTrue(Setup."Write Policy Defaults Set", 'fresh rows carry the marker, so the upgrade never rewrites them');
    end;

    // ---- W3 / W10 / W11: action argument hygiene --------------------------------------------------------

    [Test]
    procedure DataPreviewAlwaysForcesArgsPreviewTrue()
    var
        Args, Data, Response, Fail, Value: JsonObject;
        Tok: JsonToken;
    begin
        Helper.ConfigureOpenMode();
        Helper.EnrolAction(EchoActionTok, Codeunit::"Bcmag Echo Args Wrapper", true);
        Args.Add('preview', false); // a caller trying to turn a preview into a real run
        Data := ActionData(Args);
        Data.Add('preview', true);
        LibraryAssert.IsTrue(RunAction(Data, Response, Fail), 'preview should run: ' + Helper.DetailOf(Fail));
        Value := Helper.ValueObject(Response);
        LibraryAssert.IsTrue(Value.Get('preview', Tok), 'the wrapper sees args.preview');
        LibraryAssert.IsTrue(Tok.AsValue().AsBoolean(), 'data.preview = true always wins');
    end;

    [Test]
    procedure CallerArgsPreviewWithoutDataPreviewIsRefused()
    var
        Args, Response, Fail: JsonObject;
    begin
        Helper.ConfigureOpenMode();
        // Preview NOT supported: args.preview:true must not sneak past the Preview Supported gate.
        Helper.EnrolAction(EchoActionTok, Codeunit::"Bcmag Echo Args Wrapper", false);
        Args.Add('preview', true);
        LibraryAssert.IsFalse(RunAction(ActionData(Args), Response, Fail), 'args.preview without data.preview is refused');
        LibraryAssert.AreEqual(400, Helper.StatusOf(Fail), 'a 400');
        LibraryAssert.IsTrue(StrPos(Helper.DetailOf(Fail), 'args.preview') > 0, 'the detail names args.preview');
    end;

    [Test]
    procedure NonObjectArgsAreRefused()
    var
        OpInvoke: Codeunit "Bcmag Op Invoke";
        Data, Response, Fail: JsonObject;
        Cost: Integer;
    begin
        Helper.ConfigureOpenMode();
        Helper.EnrolAction(EchoActionTok, Codeunit::"Bcmag Echo Args Wrapper", false);
        Data.Add('action', EchoActionTok);
        Data.Add('args', 'ship=true');
        LibraryAssert.IsFalse(RunAction(Data, Response, Fail), 'string args are refused (action)');
        LibraryAssert.AreEqual(400, Helper.StatusOf(Fail), 'a 400 (action)');

        Clear(Data);
        Data.Add('codeunitId', 94190);
        Data.Add('procedure', 'Ping');
        Data.Add('args', 42);
        Helper.CommitFixtures();
        LibraryAssert.IsFalse(OpInvoke.Run(Data, Response, Fail, Cost), 'numeric args are refused (invoke)');
        LibraryAssert.AreEqual(400, Helper.StatusOf(Fail), 'a 400 (invoke)');
    end;

    [Test]
    procedure ConflictingTargetAndArgsSystemIdAreRefused()
    var
        Args, Target, Data, Response, Fail, Value: JsonObject;
        Id: Guid;
    begin
        Helper.ConfigureOpenMode();
        Helper.EnrolAction(EchoActionTok, Codeunit::"Bcmag Echo Args Wrapper", false);
        Args.Add('systemId', Format(CreateGuid()));
        Target.Add('systemId', Format(CreateGuid()));
        Data := ActionData(Args);
        Data.Add('target', Target);
        LibraryAssert.IsFalse(RunAction(Data, Response, Fail), 'two different records is refused');
        LibraryAssert.AreEqual(400, Helper.StatusOf(Fail), 'a 400');

        // The same GUID in two spellings is one record.
        Id := CreateGuid();
        Clear(Args);
        Clear(Target);
        Args.Add('systemId', Format(Id));                                   // {UPPER-CASE}
        Target.Add('systemId', LowerCase(DelChr(Format(Id), '<>', '{}'))); // bare lower-case
        Data := ActionData(Args);
        Data.Add('target', Target);
        LibraryAssert.IsTrue(RunAction(Data, Response, Fail), 'the same record is accepted: ' + Helper.DetailOf(Fail));
        Value := Helper.ValueObject(Response);
        LibraryAssert.AreEqual(Format(Id), Helper.TextField(Value, 'systemId'), 'the args spelling is kept');
    end;

    [Test]
    procedure OversizedActionCodeAndProcedureNameAre404NotInternal()
    var
        OpInvoke: Codeunit "Bcmag Op Invoke";
        Data, Response, Fail: JsonObject;
        Cost: Integer;
    begin
        Helper.ConfigureOpenMode();
        Data.Add('action', PadStr('', 60, 'x'));
        LibraryAssert.IsFalse(RunAction(Data, Response, Fail), 'a 60-char action code is unknown');
        LibraryAssert.AreEqual(404, Helper.StatusOf(Fail), 'unknown-action, not an overflow 500');

        Helper.ExposeCodeunitInvoke(94190);
        Clear(Data);
        Data.Add('codeunitId', 94190);
        Data.Add('procedure', PadStr('', 130, 'p'));
        Helper.CommitFixtures();
        LibraryAssert.IsFalse(OpInvoke.Run(Data, Response, Fail, Cost), 'a 130-char procedure is unknown');
        LibraryAssert.AreEqual(404, Helper.StatusOf(Fail), 'unknown-procedure, not an overflow 500');
    end;

    // ---- W5 / W8: trigger bypass and primary keys ----------------------------------------------------

    [Test]
    procedure TriggerBypassIsRefusedWhenTheTenantDisallowsIt()
    var
        Customer: Record Customer;
        OpInsert: Codeunit "Bcmag Op Insert";
        OpModify: Codeunit "Bcmag Op Modify";
        Codec: Codeunit "Bcmag Record Id Codec";
        Data, Values, Response, Fail: JsonObject;
        Cost: Integer;
    begin
        Helper.ConfigureAllowlistedMode();
        Helper.EnsureManualCustomerNos();
        Helper.ExposeTable(Database::Customer, true, true, true, true);
        Helper.SetAllowTriggerBypass(false);

        Values.Add('No.', 'WRV-INIT');
        Data.Add('tableId', Database::Customer);
        Data.Add('values', Values);
        Data.Add('init', false);
        LibraryAssert.IsFalse(OpInsert.Run(Data, Response, Fail, Cost), 'init:false is refused');
        LibraryAssert.AreEqual(403, Helper.StatusOf(Fail), 'a 403');
        LibraryAssert.IsTrue(StrPos(Helper.TypeOf(Fail), 'trigger-bypass-disabled') > 0, 'trigger-bypass-disabled');
        LibraryAssert.IsFalse(Customer.Get('WRV-INIT'), 'nothing was inserted');

        Customer := SeedCustomer('WRV-VAL');
        Clear(Data);
        Clear(Values);
        Values.Add('Name', 'Bypassed');
        Data.Add('tableId', Database::Customer);
        Data.Add('recordId', Codec.Encode(Customer.RecordId));
        Data.Add('values', Values);
        Data.Add('validate', false);
        LibraryAssert.IsFalse(OpModify.Run(Data, Response, Fail, Cost), 'validate:false is refused');
        LibraryAssert.IsTrue(StrPos(Helper.TypeOf(Fail), 'trigger-bypass-disabled') > 0, 'trigger-bypass-disabled');

        Helper.SetAllowTriggerBypass(true);
    end;

    [Test]
    procedure ModifyOfAPrimaryKeyFieldIsRefused()
    var
        Customer: Record Customer;
        OpModify: Codeunit "Bcmag Op Modify";
        Codec: Codeunit "Bcmag Record Id Codec";
        Data, Values, Response, Fail: JsonObject;
        Cost: Integer;
    begin
        Helper.ConfigureAllowlistedMode();
        Helper.EnsureManualCustomerNos();
        Helper.ExposeTable(Database::Customer, true, true, true, true);
        Customer := SeedCustomer('WRV-PK1');
        if Customer.Get('WRV-PK2') then
            Customer.Delete();
        Customer.Get('WRV-PK1');

        Values.Add('No.', 'WRV-PK2');
        Data.Add('tableId', Database::Customer);
        Data.Add('recordId', Codec.Encode(Customer.RecordId));
        Data.Add('values', Values);
        LibraryAssert.IsFalse(OpModify.Run(Data, Response, Fail, Cost), 'changing the key is refused');
        LibraryAssert.AreEqual(400, Helper.StatusOf(Fail), 'a 400');
        LibraryAssert.IsTrue(StrPos(Helper.TypeOf(Fail), 'pk-immutable') > 0, 'pk-immutable, got ' + Helper.TypeOf(Fail));
        LibraryAssert.IsTrue(Customer.Get('WRV-PK1'), 'the record keeps its key');
        LibraryAssert.IsFalse(Customer.Get('WRV-PK2'), 'no record under the new key');
    end;

    // ---- replay re-authorization ------------------------------------------------------------------

    [Test]
    procedure ReplayOfPageUrlByTableNameIsReauthorized()
    var
        Customer: Record Customer;
        Data, Body, Response: JsonObject;
        Tok: JsonToken;
        Status: Integer;
    begin
        // pageUrl addressed by table NAME carries no tableId; the replay check must resolve the name the
        // way the handler does, or revoking the table's exposure would not stop the replay.
        Helper.ConfigureAllowlistedMode();
        Helper.ExposeTable(Database::Customer, true, false, false, false);
        Customer := SeedCustomer('WRV-URL');
        Data.Add('table', 'Customer');
        Data.Add('systemId', LowerCase(DelChr(Format(Customer.SystemId), '<>', '{}')));
        Body := Helper.EnvelopeWithKey(Data, Helper.NewIdemKey());
        Helper.CommitFixtures();
        Response := Dispatcher.RunEx('pageUrl', Body, '', Status);
        LibraryAssert.AreEqual(200, Status, 'pageUrl by name succeeds: ' + Helper.DetailOf(Response));

        Helper.UnexposeTable(Database::Customer);
        Helper.CommitFixtures();
        Response := Dispatcher.RunEx('pageUrl', Body, '', Status);
        LibraryAssert.AreEqual(403, Status, 'the replay is refused once the table is unexposed');
        AssertType(Response, 'replay-withheld', 'replay');
        LibraryAssert.AreEqual('not-exposed', Helper.TextField(Response, 'reason'), 'withheld because not exposed');
        LibraryAssert.IsFalse(Response.Get('value', Tok), 'nothing disclosed');
    end;

    [Test]
    procedure ReplayOfAnUndecodableProjectionFailsClosed()
    var
        IdempotencyLog: Record "Bcmag Idempotency Log";
        Data, Body, Response: JsonObject;
        OutStr: OutStream;
        Status: Integer;
        IdemKey: Text;
    begin
        // A stored row whose @recordId cannot be decoded, for a request without a tableId to fall back
        // on: its fields cannot be attributed to a table, so no field policy can vouch for them.
        Helper.ConfigureAllowlistedMode();
        Helper.ExposeCodeunitInvoke(94190);
        Helper.EnrolProcedure(94190, 'Ping', 94190, Enum::"Bcmag Return Shape"::json);
        Data.Add('codeunitId', 94190);
        Data.Add('procedure', 'Ping');
        IdemKey := Helper.NewIdemKey();

        IdempotencyLog.Init();
        IdempotencyLog."Idempotency Key" := CopyStr(IdemKey, 1, MaxStrLen(IdempotencyLog."Idempotency Key"));
        IdempotencyLog."Request Id" := 'seeded';
        IdempotencyLog."Body Hash" := CopyStr(Dispatcher.CanonicalHash('invoke', Data), 1, MaxStrLen(IdempotencyLog."Body Hash"));
        IdempotencyLog."Logged At" := CurrentDateTime();
        IdempotencyLog.Operation := 'invoke';
        IdempotencyLog.Status := 200;
        IdempotencyLog.Caller := UserSecurityId();
        IdempotencyLog.Response.CreateOutStream(OutStr, TextEncoding::UTF8);
        OutStr.WriteText('{"value":{"rows":[{"@recordId":"not a token","Name":"secret"}]},"@requestId":"seeded"}');
        IdempotencyLog.Insert();

        Body := Helper.EnvelopeWithKey(Data, IdemKey);
        Helper.CommitFixtures();
        Response := Dispatcher.RunEx('invoke', Body, '', Status);
        LibraryAssert.AreEqual(403, Status, 'fail closed');
        AssertType(Response, 'replay-withheld', 'undecodable projection');
        LibraryAssert.AreEqual('field-restricted', Helper.TextField(Response, 'reason'), 'withheld as unjudgeable fields');
        LibraryAssert.IsFalse(Response.Contains('value'), 'nothing disclosed');
    end;

    // ---- reservation retention ----------------------------------------------------------------------

    [Test]
    procedure LogPurgeRemovesSettledAndDeadReservationsOnly()
    var
        Setup: Record "Bcmag Setup";
        Res: Record "Bcmag Idempotency Reservation";
        LogPurge: Codeunit "Bcmag Log Purge";
        OldCompleted, OldReleased, OldInProgress, FreshInProgress, FreshCompleted: Text;
        Old: DateTime;
        FortyDays: BigInteger;
    begin
        Setup.GetSingleton();
        Setup."Operation Log Retention Days" := 30;
        Setup.Modify();
        FortyDays := 40;
        FortyDays := FortyDays * 86400000;
        Old := CurrentDateTime() - FortyDays;
        OldCompleted := SeedReservation("Bcmag Reservation State"::Completed, Old, Old);
        OldReleased := SeedReservation("Bcmag Reservation State"::Released, Old, Old);
        OldInProgress := SeedReservation("Bcmag Reservation State"::"In Progress", Old, 0DT);
        FreshInProgress := SeedReservation("Bcmag Reservation State"::"In Progress", CurrentDateTime(), 0DT);
        FreshCompleted := SeedReservation("Bcmag Reservation State"::Completed, CurrentDateTime(), CurrentDateTime());

        LogPurge.PurgeExpired();

        LibraryAssert.IsFalse(Res.Get(UserSecurityId(), OldCompleted), 'an old completed reservation is purged');
        LibraryAssert.IsFalse(Res.Get(UserSecurityId(), OldReleased), 'an old released reservation is purged');
        LibraryAssert.IsFalse(Res.Get(UserSecurityId(), OldInProgress), 'a long-dead in-progress reservation is purged');
        LibraryAssert.IsTrue(Res.Get(UserSecurityId(), FreshInProgress), 'a live in-progress reservation is kept');
        LibraryAssert.IsTrue(Res.Get(UserSecurityId(), FreshCompleted), 'a recent completed reservation is kept');
    end;

    local procedure SeedReservation(State: Enum "Bcmag Reservation State"; ReservedAt: DateTime; SettledAt: DateTime) IdemKey: Text
    var
        Res: Record "Bcmag Idempotency Reservation";
    begin
        IdemKey := Helper.NewIdemKey();
        Res.Init();
        Res.Caller := UserSecurityId();
        Res."Idempotency Key" := CopyStr(IdemKey, 1, MaxStrLen(Res."Idempotency Key"));
        Res.State := State;
        Res."Body Hash" := 'h';
        Res."Reserved At" := ReservedAt;
        Res."Settled At" := SettledAt;
        Res.Insert();
    end;
}
