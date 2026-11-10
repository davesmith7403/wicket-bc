codeunit 94349 "Bcmag Restricted Identity Test"
{
    Subtype = Test;
    TestPermissions = Disabled;

    // The rest of the suite runs as SUPER, which holds every permission, so a rung that reaches for an
    // object or a table right it was never granted cannot fail there. These tests call the dispatcher
    // as a principal that holds ONE Wicket set (Microsoft's Permissions Mock), the way an agent's
    // application user does. Each asserts the answer the set is meant to get — and so fails with a
    // 500 when a handler on that rung calls a codeunit, or writes a table, only a higher rung may.
    //
    // The mock is given EXACTLY the set plus the test rig (its own objects and its own table as the
    // business table). Deliberately NOT the mock's "All Objects" set and NOT D365 BASIC: both grant
    // execute on every codeunit (D365 BASIC through "BaseApp Objects - Exec"), which hides a rung
    // calling a codeunit above itself. A principal that holds only Wicket sets and a data set — the
    // minimal setup the presets name — has no such wildcard. Fixtures and envelopes are prepared as
    // SUPER first; the mock is stopped before anything is asserted.
    //
    // ORDER MATTERS. Business Central checks execute on a codeunit the first time it runs in a session
    // and not again: once a principal that may run it has done so, a later principal that may not runs
    // it too. Table rights are checked on every access. So:
    //   - the tests are declared lowest rung first (Read, Execute, Edit, the data sets, the viewer sets,
    //     Admin last), and no test calls the dispatcher as SUPER;
    //   - a run of THIS CODEUNIT ALONE (a fresh session) is the proof of the execute grants. In a run of
    //     the whole suite the codeunits before it have already run everything as SUPER, and these tests
    //     then prove the table rights and the gates only.

    var
        Dispatcher: Codeunit "Bcmag Rpc Dispatcher";
        Helper: Codeunit "Bcmag Test Helper";
        PermissionsMock: Codeunit "Permissions Mock";
        LibraryAssert: Codeunit "Library Assert";
        ReadSetTok: Label 'Wicket - Read', Locked = true;
        ExecuteSetTok: Label 'Wicket - Execute', Locked = true;
        EditSetTok: Label 'Wicket - Edit', Locked = true;
        RigSetTok: Label 'Wicket Test Rig', Locked = true;
        DataReadSetTok: Label 'Wicket Data - Read', Locked = true;
        DataExecSetTok: Label 'Wicket Data - Exec', Locked = true;
        AuditSetTok: Label 'Wicket - Audit', Locked = true;
        ChangesSetTok: Label 'Wicket - Changes', Locked = true;
        AdminSetTok: Label 'Wicket - Admin', Locked = true;
        UnmaskSetTok: Label 'Wicket - Unmask', Locked = true;
        EchoActionTok: Label 'RI-ECHO', Locked = true;
        FixtureTok: Label 'RI-FIX', Locked = true;

    // -- The Read rung -----------------------------------------------------------------------------------

    [Test]
    procedure ReadRungGetsCapabilities()
    begin
        AssertCapabilitiesAs(ReadSetTok);
    end;

    [Test]
    procedure ReadRungRunsTheReadPlane()
    begin
        AssertReadPlaneAs(ReadSetTok);
    end;

    [Test]
    procedure ReadRungReadsItsOwnChanges()
    var
        Response, Body, NoFilter: JsonObject;
        Status: Integer;
    begin
        Prepare("Bcmag Record Changes"::OldAndNewValues, 'RI-4');
        Body := Helper.Envelope(NoFilter);
        Become(ReadSetTok);
        Response := Dispatcher.RunEx('changes', Body, '', Status);
        PermissionsMock.Stop();
        LibraryAssert.AreEqual(200, Status, 'changes as Wicket - Read: ' + Describe(Response));
    end;

    [Test]
    procedure ReadRungEnqueuesFollowsAndCancelsADelivery()
    var
        Calls, Results: JsonArray;
        Deliver, Data, Response: JsonObject;
        Tok: JsonToken;
        RequestId: Text;
        FutureMs: BigInteger;
    begin
        // The queue row is written, read and updated under the caller's rights (Request Queue = RIM).
        PrepareFixture();
        Helper.ConfigureAsync();
        Helper.CommitFixtures();
        FutureMs := 3600000;
        Deliver.Add('mode', 'azureBlob');
        Deliver.Add('package', 'ndjson');
        Deliver.Add('scheduleAt', Format(CurrentDateTime() + FutureMs, 0, 9));
        Data.Add('tableId', Database::"Bcmag Test Record");
        Data.Add('deliver', Deliver);
        AddCall(Calls, 'enqueue', 'query', Data, false);
        Results := RunAs(ReadSetTok, '', Calls);
        if not TaskScheduler.CanCreateTask() then begin
            // No task scheduler (the CI container): the contract is a retryable 503, for every caller.
            Helper.DisableAsync();
            Helper.CommitFixtures();
            AssertAll(Results, 'enqueue', 503, 'async-start-failed', ReadSetTok);
            exit;
        end;
        Response := ResponseOf(Results, 'enqueue');
        if Response.Get('requestId', Tok) then begin
            RequestId := Tok.AsValue().AsText();
            Clear(Calls);
            AddCall(Calls, 'status', 'status', RequestRef(RequestId), false);
            AddCall(Calls, 'requests', 'requests', EmptyData(), false);
            AddCall(Calls, 'cancel', 'cancel', RequestRef(RequestId), false);
            Calls.Get(0, Tok);
            Results.Add(Tok);
            Results := Merge(Results, RunAs(ReadSetTok, '', Calls));
        end;
        Helper.DisableAsync();
        Helper.CommitFixtures();
        AssertAll(Results, 'enqueue', 200, '', ReadSetTok);
        AssertAll(Results, 'status|requests|cancel', 200, '', ReadSetTok);
    end;

    [Test]
    procedure OnlyTheChangesSetReadsAnotherUsersChanges()
    var
        Calls, Results: JsonArray;
        Data: JsonObject;
    begin
        Prepare("Bcmag Record Changes"::OldAndNewValues, 'RI-C1');
        Data.Add('user', 'SOMEONE.ELSE');
        AddCall(Calls, 'others', 'changes', Data, false);
        Results := RunAs(ReadSetTok, '', Calls);
        AssertAll(Results, 'others', 403, 'changes-forbidden', ReadSetTok);

        Clear(Calls);
        Clear(Data);
        Data.Add('user', 'SOMEONE.ELSE');
        AddCall(Calls, 'others', 'changes', Data, false);
        Results := RunAs(ReadSetTok, ChangesSetTok, Calls);
        AssertAll(Results, 'others', 200, '', 'Wicket - Read + Wicket - Changes');
    end;

    [Test]
    procedure OnlyTheUnmaskSetLiftsAMask()
    var
        Results: JsonArray;
        Masked, Lifted: Text;
    begin
        PrepareFixture();
        Helper.SetFieldPolicyMode(Enum::"Bcmag Field Policy Mode"::ByClassification);
        Helper.SetFieldAccess(Database::"Bcmag Test Record", 2, "Bcmag Read Access"::Masked, 'PARTIAL', false);
        Helper.SetUnmaskTierEnabled(true);
        Helper.CommitFixtures();

        Results := RunAs(ReadSetTok, '', FixtureQuery());
        Masked := FirstRowName(Results);
        Results := RunAs(ReadSetTok, UnmaskSetTok, FixtureQuery());
        Lifted := FirstRowName(Results);

        Helper.ConfigureOpenMode();
        Helper.CommitFixtures();
        LibraryAssert.AreNotEqual('Restricted Identity', Masked, 'the Read rung alone reads the masked value');
        LibraryAssert.AreNotEqual('', Masked, 'and it is a masked value, not a missing one');
        LibraryAssert.AreEqual('Restricted Identity', Lifted, 'the Unmask set lifts it');
    end;

    [Test]
    procedure ReadRungWithoutDataRightsGetsATypedRefusal()
    var
        Results: JsonArray;
    begin
        PrepareUnshared();
        Results := RunAs(ReadSetTok, '', UnsharedCalls());
        AssertAll(Results, 'query|count', 403, 'not-exposed', ReadSetTok);
    end;

    [Test]
    procedure ReadRungIsRefusedAWriteAsRoleForbidden()
    var
        Response, Body: JsonObject;
        Status: Integer;
    begin
        Prepare("Bcmag Record Changes"::OldAndNewValues, 'RI-1');
        Body := Helper.EnvelopeWithKey(InsertData('RI-1'), Helper.NewIdemKey());
        Become(ReadSetTok);
        Response := Dispatcher.RunEx('insert', Body, '', Status);
        PermissionsMock.Stop();
        LibraryAssert.AreEqual(403, Status, 'a read-rung write is a typed refusal: ' + Describe(Response));
        LibraryAssert.IsTrue(StrPos(Helper.TextField(Response, 'type'), 'role-forbidden') > 0, 'role-forbidden: ' + Describe(Response));
    end;

    [Test]
    procedure ReadRungIsRefusedEveryGatedOperation()
    var
        Results: JsonArray;
    begin
        PrepareGated('RI-G1');
        Results := RunAs(ReadSetTok, '', GatedCalls('RI-G1'));
        CleanGated();
        AssertAll(Results, 'invoke|action|preview|insert|modify|delete|batch', 403, 'role-forbidden', ReadSetTok);
        AssertNoRecord('RI-G1');
    end;

    // -- The Execute rung --------------------------------------------------------------------------------

    [Test]
    procedure ExecuteRungGetsCapabilities()
    begin
        AssertCapabilitiesAs(ExecuteSetTok);
    end;

    [Test]
    procedure ExecuteRungRunsTheReadPlane()
    begin
        AssertReadPlaneAs(ExecuteSetTok);
    end;

    [Test]
    procedure ExecuteRungRunsInvokeAndActionButNoWrites()
    var
        Results: JsonArray;
    begin
        PrepareGated('RI-G2');
        Results := RunAs(ExecuteSetTok, '', GatedCalls('RI-G2'));
        CleanGated();
        AssertAll(Results, 'invoke|action|preview', 200, '', ExecuteSetTok);
        AssertAll(Results, 'insert|modify|delete|batch', 403, 'role-forbidden', ExecuteSetTok);
        AssertNoRecord('RI-G2');
    end;

    // -- The Edit rung -----------------------------------------------------------------------------------

    [Test]
    procedure EditRungGetsCapabilities()
    begin
        AssertCapabilitiesAs(EditSetTok);
    end;

    [Test]
    procedure EditRungRunsTheReadPlane()
    begin
        AssertReadPlaneAs(EditSetTok);
    end;

    [Test]
    procedure EditRungWritesWithTheChangeHistoryOn()
    var
        TestRecord: Record "Bcmag Test Record";
        Entry: Record "Bcmag Change Entry";
        Codec: Codeunit "Bcmag Record Id Codec";
        Response, InsertBody, ModifyBody, DeleteBody, Data, Values: JsonObject;
        RecordToken: Text;
        Before, InsertStatus, ModifyStatus, DeleteStatus: Integer;
    begin
        // The recorder writes the history inside the caller's transaction, under the caller's rights.
        Prepare("Bcmag Record Changes"::OldAndNewValues, 'RI-2');
        Before := Entry.Count();
        TestRecord."Code" := 'RI-2';
        RecordToken := Codec.Encode(TestRecord.RecordId);
        InsertBody := Helper.EnvelopeWithKey(InsertData('RI-2'), Helper.NewIdemKey());
        Values.Add('Name', 'Restricted Renamed');
        Data.Add('tableId', Database::"Bcmag Test Record");
        Data.Add('recordId', RecordToken);
        Data.Add('values', Values);
        ModifyBody := Helper.EnvelopeWithKey(Data, Helper.NewIdemKey());
        Clear(Data);
        Data.Add('tableId', Database::"Bcmag Test Record");
        Data.Add('recordId', RecordToken);
        DeleteBody := Helper.EnvelopeWithKey(Data, Helper.NewIdemKey());

        Become(EditSetTok);
        Response := Dispatcher.RunEx('insert', InsertBody, '', InsertStatus);
        if InsertStatus = 200 then
            Response := Dispatcher.RunEx('modify', ModifyBody, '', ModifyStatus);
        if ModifyStatus = 200 then
            Response := Dispatcher.RunEx('delete', DeleteBody, '', DeleteStatus);
        PermissionsMock.Stop();

        LibraryAssert.AreEqual(200, InsertStatus, 'insert as Wicket - Edit: ' + Describe(Response));
        LibraryAssert.AreEqual(200, ModifyStatus, 'modify as Wicket - Edit: ' + Describe(Response));
        LibraryAssert.AreEqual(200, DeleteStatus, 'delete as Wicket - Edit: ' + Describe(Response));
        LibraryAssert.IsFalse(TestRecord.Get('RI-2'), 'the record went through all three writes');
        LibraryAssert.AreEqual(Before + 3, Entry.Count(), 'and each write is in the change history');
    end;

    [Test]
    procedure EditRungRunsABatchWithTheChangeHistoryOn()
    var
        TestRecord: Record "Bcmag Test Record";
        Response, Body, Data, Item, Ref, Values: JsonObject;
        Items: JsonArray;
        Status: Integer;
    begin
        Prepare("Bcmag Record Changes"::OldAndNewValues, 'RI-3');
        Item := InsertData('RI-3');
        Item.Add('op', 'insert');
        Items.Add(Item);
        Clear(Item);
        Ref.Add('fromItem', 0);
        Values.Add('Name', 'Batch Renamed');
        Item.Add('op', 'modify');
        Item.Add('tableId', Database::"Bcmag Test Record");
        Item.Add('recordId', Ref);
        Item.Add('values', Values);
        Items.Add(Item);
        Data.Add('items', Items);

        Body := Helper.EnvelopeWithKey(Data, Helper.NewIdemKey());
        Become(EditSetTok);
        Response := Dispatcher.RunEx('batch', Body, '', Status);
        PermissionsMock.Stop();
        LibraryAssert.AreEqual(200, Status, 'batch as Wicket - Edit: ' + Describe(Response));
        LibraryAssert.IsTrue(TestRecord.Get('RI-3'), 'the batch committed');
        LibraryAssert.AreEqual('Batch Renamed', TestRecord.Name, 'both items ran');
        TestRecord.Delete();
        Commit();
    end;

    [Test]
    procedure EditRungRunsEveryGatedOperation()
    var
        Results: JsonArray;
    begin
        PrepareGated('RI-G3');
        Results := RunAs(EditSetTok, '', GatedCalls('RI-G3'));
        CleanGated();
        AssertAll(Results, 'invoke|action|preview|insert|modify|delete|batch', 200, '', EditSetTok);
    end;

    [Test]
    procedure EditRungReplaysAnIdempotentWrite()
    var
        TestRecord: Record "Bcmag Test Record";
        Calls, Results: JsonArray;
        Call: JsonObject;
        Body: JsonObject;
    begin
        // The replay reads the idempotency log and the reservation under the caller's rights.
        Prepare("Bcmag Record Changes"::OldAndNewValues, 'RI-G6');
        Body := Helper.EnvelopeWithKey(InsertData('RI-G6'), Helper.NewIdemKey());
        Call.Add('label', 'first');
        Call.Add('op', 'insert');
        Call.Add('body', Body);
        Calls.Add(Call);
        Clear(Call);
        Call.Add('label', 'replay');
        Call.Add('op', 'insert');
        Call.Add('body', Body);
        Calls.Add(Call);
        Results := RunAs(EditSetTok, '', Calls);
        AssertAll(Results, 'first|replay', 200, '', EditSetTok);
        TestRecord.SetRange("Code", 'RI-G6');
        LibraryAssert.AreEqual(1, TestRecord.Count(), 'the replay did not insert again');
        TestRecord.DeleteAll();
        Commit();
    end;

    // -- The data sets (Data - Exec holds execute on every codeunit, so it comes after the rungs) --------

    [Test]
    procedure DataReadSetRunsTheReadPlane()
    begin
        AssertReadPlaneAs(DataReadSetTok);
    end;

    [Test]
    procedure DataReadSetReadsATableTheRungAloneCannot()
    var
        Results: JsonArray;
    begin
        PrepareUnshared();
        Results := RunAs(DataReadSetTok, '', UnsharedCalls());
        AssertAll(Results, 'query|count', 200, '', DataReadSetTok);
    end;

    [Test]
    procedure DataReadSetIsRefusedEveryGatedOperation()
    var
        Results: JsonArray;
    begin
        PrepareGated('RI-G4');
        Results := RunAs(DataReadSetTok, '', GatedCalls('RI-G4'));
        CleanGated();
        AssertAll(Results, 'invoke|action|preview|insert|modify|delete|batch', 403, 'role-forbidden', DataReadSetTok);
        AssertNoRecord('RI-G4');
    end;

    [Test]
    procedure DataExecSetRunsTheReadPlane()
    begin
        AssertReadPlaneAs(DataExecSetTok);
    end;

    [Test]
    procedure DataExecSetRunsInvokeAndActionButNeverTheWritePlane()
    var
        Results: JsonArray;
    begin
        // The set holds Execute on EVERY codeunit, the write handlers included, and the rig gives it full
        // rights on the business table: only the Write Gate keeps the generic write plane closed.
        PrepareGated('RI-G5');
        Results := RunAs(DataExecSetTok, '', GatedCalls('RI-G5'));
        CleanGated();
        AssertAll(Results, 'invoke|action|preview', 200, '', DataExecSetTok);
        AssertAll(Results, 'insert|modify|delete|batch', 403, 'role-forbidden', DataExecSetTok);
        AssertNoRecord('RI-G5');
    end;

    // -- The viewer sets and Admin -----------------------------------------------------------------------

    [Test]
    procedure ViewerSetsAreRefusedEveryOperation()
    var
        Results: JsonArray;
    begin
        // The viewer sets carry the object rung, so their holder reaches the endpoint — but it is not a
        // caller: it cannot write the Operation Log, so an operation it ran would leave no audit row,
        // and a keyed request would raise at the idempotency reservation instead of answering.
        PrepareFixture();
        Results := RunAs(AuditSetTok, '', ViewerCalls());
        AssertAll(Results, 'capabilities|whoAmI|discover tables|query|changes|requests|insert', 403, 'role-forbidden', AuditSetTok);
        Results := RunAs(ChangesSetTok, '', ViewerCalls());
        AssertAll(Results, 'capabilities|whoAmI|discover tables|query|changes|requests|insert', 403, 'role-forbidden', ChangesSetTok);
        AssertNoRecord('RI-V1');
    end;

    [Test]
    procedure AuditSetReadsEveryWicketTableAndWritesNone()
    var
        Problem: Text;
    begin
        Prepare("Bcmag Record Changes"::OldAndNewValues, 'RI-A1');
        Become(AuditSetTok);
        if not TryAuditTour() then
            Problem := GetLastErrorText();
        PermissionsMock.Stop();
        LibraryAssert.AreEqual('', Problem, 'the viewer reads every Wicket table and can write none');
    end;

    [Test]
    procedure ChangesSetAloneReadsTheChangeHistory()
    var
        Problem: Text;
    begin
        Prepare("Bcmag Record Changes"::OldAndNewValues, 'RI-A2');
        Become(ChangesSetTok);
        if not TryChangesTour() then
            Problem := GetLastErrorText();
        PermissionsMock.Stop();
        LibraryAssert.AreEqual('', Problem, 'Wicket - Audit Changes reads the change history on its own and cannot write it');
    end;

    [Test]
    procedure AdminSetEditsThePolicyRunsThePurgeAndWrites()
    var
        Setup: Record "Bcmag Setup";
        Exposure: Record "Bcmag Exposure";
        TestRecord: Record "Bcmag Test Record";
        LogPurge: Codeunit "Bcmag Log Purge";
        Response, Body: JsonObject;
        Status: Integer;
    begin
        Prepare("Bcmag Record Changes"::OldAndNewValues, 'RI-A3');
        Body := Helper.EnvelopeWithKey(InsertData('RI-A3'), Helper.NewIdemKey());
        Become(AdminSetTok);
        Setup.GetSingleton();
        Setup.Modify(true);
        Helper.ExposeTable(Database::"Bcmag Test Record", true, false, false, false);
        Helper.UnexposeTable(Database::"Bcmag Test Record");
        Commit();
        LogPurge.PurgeExpired();
        Commit();
        Response := Dispatcher.RunEx('insert', Body, '', Status);
        PermissionsMock.Stop();
        LibraryAssert.AreEqual(200, Status, 'insert as Wicket - Admin: ' + Describe(Response));
        Exposure.SetRange("Object Id", Database::"Bcmag Test Record");
        LibraryAssert.IsTrue(Exposure.IsEmpty(), 'the exposure row was added and removed');
        if TestRecord.Get('RI-A3') then
            TestRecord.Delete();
        Commit();
    end;

    [TryFunction]
    local procedure TryAuditTour()
    var
        Setup: Record "Bcmag Setup";
        Exposure: Record "Bcmag Exposure";
        FieldExposure: Record "Bcmag Field Exposure";
        Rule: Record "Bcmag Classification Rule";
        MaskProfile: Record "Bcmag Mask Profile";
        AccessException: Record "Bcmag Access Exception";
        ProcedureCatalog: Record "Bcmag Procedure Catalog";
        ActionCatalog: Record "Bcmag Action Catalog";
        OperationLog: Record "Bcmag Operation Log";
        IdempotencyLog: Record "Bcmag Idempotency Log";
        Reservation: Record "Bcmag Idempotency Reservation";
        RequestQueue: Record "Bcmag Request Queue";
        ChangeEntry: Record "Bcmag Change Entry";
        FieldChange: Record "Bcmag Field Change";
    begin
        if Setup.FindFirst() then;
        if Exposure.FindFirst() then;
        if FieldExposure.FindFirst() then;
        if Rule.FindFirst() then;
        if MaskProfile.FindFirst() then;
        if AccessException.FindFirst() then;
        if ProcedureCatalog.FindFirst() then;
        if ActionCatalog.FindFirst() then;
        if OperationLog.FindFirst() then;
        if IdempotencyLog.FindFirst() then;
        if Reservation.FindFirst() then;
        if RequestQueue.FindFirst() then;
        if ChangeEntry.FindFirst() then;
        if FieldChange.FindFirst() then;
        if Setup.WritePermission() then Error('the viewer may write Setup');
        if Exposure.WritePermission() then Error('the viewer may write Exposure');
        if FieldExposure.WritePermission() then Error('the viewer may write Field Exposure');
        if Rule.WritePermission() then Error('the viewer may write Classification Rule');
        if MaskProfile.WritePermission() then Error('the viewer may write Mask Profile');
        if AccessException.WritePermission() then Error('the viewer may write Access Exception');
        if ProcedureCatalog.WritePermission() then Error('the viewer may write Procedure Catalog');
        if ActionCatalog.WritePermission() then Error('the viewer may write Action Catalog');
        if OperationLog.WritePermission() then Error('the viewer may write Operation Log');
        if IdempotencyLog.WritePermission() then Error('the viewer may write Idempotency Log');
        if Reservation.WritePermission() then Error('the viewer may write Idempotency Reservation');
        if RequestQueue.WritePermission() then Error('the viewer may write Request Queue');
        if ChangeEntry.WritePermission() then Error('the viewer may write Change Entry');
        if FieldChange.WritePermission() then Error('the viewer may write Field Change');
    end;

    [TryFunction]
    local procedure TryChangesTour()
    var
        ChangeEntry: Record "Bcmag Change Entry";
        FieldChange: Record "Bcmag Field Change";
    begin
        if ChangeEntry.FindFirst() then;
        if FieldChange.FindFirst() then;
        if ChangeEntry.WritePermission() then Error('the change history auditor may write Change Entry');
        if FieldChange.WritePermission() then Error('the change history auditor may write Field Change');
    end;

    local procedure AssertReadPlaneAs(RoleId: Code[20])
    var
        Results: JsonArray;
        Tok: JsonToken;
        Result: JsonObject;
        Mismatch: Text;
    begin
        // Never run as the test's own identity first: see the note on execute checks at the top.
        PrepareFixture();
        Results := RunAs(RoleId, '', ReadPlaneCalls());
        foreach Tok in Results do begin
            Result := Tok.AsObject();
            if IntOf(Result, 'status') <> IntOf(Result, 'expect') then
                Mismatch += StrSubstNo('%1: expected %2, got %3 (%4) | ', Helper.TextField(Result, 'label'), IntOf(Result, 'expect'),
                    IntOf(Result, 'status'), CopyStr(Helper.TextField(Result, 'detail'), 1, 200));
        end;
        LibraryAssert.AreEqual('', Mismatch, StrSubstNo('every read operation answers %1 as designed', RoleId));
    end;

    local procedure ReadPlaneCalls() Calls: JsonArray
    var
        TestRecord: Record "Bcmag Test Record";
        Codec: Codeunit "Bcmag Record Id Codec";
        Data, Agg: JsonObject;
    begin
        TestRecord.Get(FixtureTok);
        AddExpectedCall(Calls, 'capabilities', 'capabilities', EmptyData(), 200);
        AddExpectedCall(Calls, 'whoAmI', 'whoAmI', EmptyData(), 200);
        AddExpectedCall(Calls, 'skill (no document configured)', 'skill', EmptyData(), 404);
        AddExpectedCall(Calls, 'discover tables', 'discover', DiscoverData('tables'), 200);
        AddExpectedCall(Calls, 'discover codeunits', 'discover', DiscoverData('codeunits'), 200);
        AddExpectedCall(Calls, 'discover companies', 'discover', DiscoverData('companies'), 200);
        AddExpectedCall(Calls, 'discover apis', 'discover', DiscoverData('apis'), 200);
        Data.Add('kind', 'table');
        Data.Add('tableId', Database::"Bcmag Test Record");
        AddExpectedCall(Calls, 'describe', 'describe', Data, 200);
        Clear(Data);
        Data.Add('tableId', Database::"Bcmag Test Record");
        Data.Add('top', 1);
        AddExpectedCall(Calls, 'query', 'query', Data, 200);
        Clear(Data);
        Agg.Add('count', true);
        Data.Add('tableId', Database::"Bcmag Test Record");
        Data.Add('aggregate', Agg);
        AddExpectedCall(Calls, 'aggregate', 'query', Data, 200);
        Clear(Data);
        Data.Add('tableId', Database::"Bcmag Test Record");
        Data.Add('recordId', Codec.Encode(TestRecord.RecordId));
        Data.Add('fieldNo', 3);
        AddExpectedCall(Calls, 'readBlob', 'readBlob', Data, 200);
        Clear(Data);
        Data.Add('tableId', Database::"Bcmag Test Record");
        Data.Add('systemId', LowerCase(DelChr(Format(TestRecord.SystemId), '<>', '{}')));
        AddExpectedCall(Calls, 'pageUrl (the table has no lookup page)', 'pageUrl', Data, 404);
        AddExpectedCall(Calls, 'status of an unknown request', 'status', RequestRef('00000000-0000-0000-0000-000000000000'), 404);
        AddExpectedCall(Calls, 'cancel of an unknown request', 'cancel', RequestRef('00000000-0000-0000-0000-000000000000'), 404);
        AddExpectedCall(Calls, 'requests', 'requests', EmptyData(), 200);
        AddExpectedCall(Calls, 'changes', 'changes', EmptyData(), 200);
    end;

    local procedure GatedCalls(RecordCode: Code[20]) Calls: JsonArray
    var
        TestRecord: Record "Bcmag Test Record";
        Codec: Codeunit "Bcmag Record Id Codec";
        Data, Args, Values, Item: JsonObject;
        Items: JsonArray;
        RecordToken: Text;
    begin
        TestRecord."Code" := RecordCode;
        RecordToken := Codec.Encode(TestRecord.RecordId);

        Args.Add('message', 'hi');
        Data.Add('codeunitId', Codeunit::"Bcmag Wrap Ping");
        Data.Add('procedure', 'Ping');
        Data.Add('args', Args);
        AddCall(Calls, 'invoke', 'invoke', Data, true);

        Clear(Data);
        Clear(Args);
        Args.Add('message', 'hi');
        Data.Add('action', EchoActionTok);
        Data.Add('args', Args);
        AddCall(Calls, 'action', 'action', Data, true);

        Clear(Data);
        Clear(Args);
        Args.Add('message', 'hi');
        Data.Add('action', EchoActionTok);
        Data.Add('args', Args);
        Data.Add('preview', true);
        AddCall(Calls, 'preview', 'action', Data, false);

        AddCall(Calls, 'insert', 'insert', InsertData(RecordCode), true);

        Clear(Data);
        Values.Add('Name', 'Gated Renamed');
        Data.Add('tableId', Database::"Bcmag Test Record");
        Data.Add('recordId', RecordToken);
        Data.Add('values', Values);
        AddCall(Calls, 'modify', 'modify', Data, true);

        Clear(Data);
        Data.Add('tableId', Database::"Bcmag Test Record");
        Data.Add('recordId', RecordToken);
        AddCall(Calls, 'delete', 'delete', Data, true);

        Clear(Data);
        Item := InsertData(RecordCode);
        Item.Add('op', 'insert');
        Items.Add(Item);
        Clear(Item);
        Item.Add('op', 'delete');
        Item.Add('tableId', Database::"Bcmag Test Record");
        Item.Add('recordId', RecordToken);
        Items.Add(Item);
        Data.Add('items', Items);
        AddCall(Calls, 'batch', 'batch', Data, true);
    end;

    local procedure UnsharedCalls() Calls: JsonArray
    var
        Data, Agg: JsonObject;
    begin
        Data.Add('tableId', Database::"Bcmag Test Unshared Record");
        Data.Add('top', 1);
        AddCall(Calls, 'query', 'query', Data, false);
        Clear(Data);
        Agg.Add('count', true);
        Data.Add('tableId', Database::"Bcmag Test Unshared Record");
        Data.Add('aggregate', Agg);
        AddCall(Calls, 'count', 'query', Data, false);
    end;

    local procedure ViewerCalls() Calls: JsonArray
    var
        Data: JsonObject;
    begin
        AddCall(Calls, 'capabilities', 'capabilities', EmptyData(), false);
        AddCall(Calls, 'whoAmI', 'whoAmI', EmptyData(), false);
        AddCall(Calls, 'discover tables', 'discover', DiscoverData('tables'), false);
        Data.Add('tableId', Database::"Bcmag Test Record");
        Data.Add('top', 1);
        AddCall(Calls, 'query', 'query', Data, false);
        AddCall(Calls, 'changes', 'changes', EmptyData(), false);
        AddCall(Calls, 'requests', 'requests', EmptyData(), false);
        AddCall(Calls, 'insert', 'insert', InsertData('RI-V1'), true);
    end;

    local procedure FixtureQuery() Calls: JsonArray
    var
        Data: JsonObject;
        Names: JsonArray;
    begin
        Data.Add('tableId', Database::"Bcmag Test Record");
        Data.Add('filter', '"Code" eq ''RI-FIX''');
        Names.Add('Name');
        Data.Add('select', Names);
        AddCall(Calls, 'query', 'query', Data, false);
    end;

    local procedure FirstRowName(Results: JsonArray): Text
    var
        Response: JsonObject;
        Rows: JsonArray;
        Tok: JsonToken;
    begin
        Response := ResponseOf(Results, 'query');
        LibraryAssert.IsTrue(Response.Get('value', Tok), 'the query answered rows: ' + Describe(Response));
        Rows := Tok.AsArray();
        LibraryAssert.AreEqual(1, Rows.Count(), 'one fixture row: ' + Describe(Response));
        Rows.Get(0, Tok);
        exit(Helper.TextField(Tok.AsObject(), 'Name'));
    end;

    local procedure Merge(First: JsonArray; Second: JsonArray) Both: JsonArray
    var
        Tok: JsonToken;
    begin
        foreach Tok in First do
            if Tok.AsObject().Contains('status') then
                Both.Add(Tok);
        foreach Tok in Second do
            Both.Add(Tok);
    end;

    local procedure EmptyData() Data: JsonObject
    begin
    end;

    local procedure DiscoverData(Kind: Text) Data: JsonObject
    begin
        Data.Add('kind', Kind);
        Data.Add('top', 5);
    end;

    local procedure RequestRef(RequestId: Text) Data: JsonObject
    begin
        Data.Add('requestId', RequestId);
    end;

    local procedure AddCall(var Calls: JsonArray; CallLabel: Text; Operation: Text; Data: JsonObject; WithKey: Boolean)
    var
        Call: JsonObject;
    begin
        Call.Add('label', CallLabel);
        Call.Add('op', Operation);
        if WithKey then
            Call.Add('body', Helper.EnvelopeWithKey(Data, Helper.NewIdemKey()))
        else
            Call.Add('body', Helper.Envelope(Data));
        Calls.Add(Call);
    end;

    local procedure AddExpectedCall(var Calls: JsonArray; CallLabel: Text; Operation: Text; Data: JsonObject; Expected: Integer)
    var
        Call: JsonObject;
    begin
        Call.Add('label', CallLabel);
        Call.Add('op', Operation);
        Call.Add('expect', Expected);
        Call.Add('body', Helper.Envelope(Data));
        Calls.Add(Call);
    end;

    // Runs the calls in order as a principal holding exactly RoleId (+ ExtraRoleId) and the test rig;
    // RoleId '' runs them as the test's own identity. One result per call: label, status, type, detail,
    // response.
    local procedure RunAs(RoleId: Code[20]; ExtraRoleId: Code[20]; Calls: JsonArray) Results: JsonArray
    var
        Tok, BodyTok: JsonToken;
        Call, Response, Result: JsonObject;
        Status: Integer;
    begin
        if RoleId <> '' then begin
            Become(RoleId);
            if ExtraRoleId <> '' then
                PermissionsMock.Assign(ExtraRoleId);
        end;
        foreach Tok in Calls do begin
            Call := Tok.AsObject();
            Call.Get('body', BodyTok);
            Clear(Status);
            Response := Dispatcher.RunEx(Helper.TextField(Call, 'op'), BodyTok.AsObject(), '', Status);
            // Over HTTP every request ends its own transaction; the audit row the dispatcher writes last
            // would otherwise still be open when the next call reaches the Codeunit.Run boundary.
            Commit();
            Clear(Result);
            Result.Add('label', Helper.TextField(Call, 'label'));
            Result.Add('status', Status);
            if Call.Contains('expect') then
                Result.Add('expect', IntOf(Call, 'expect'));
            if Status >= 400 then begin
                Result.Add('type', Helper.TextField(Response, 'type'));
                Result.Add('detail', Helper.TextField(Response, 'detail'));
            end;
            Result.Add('response', Response);
            Results.Add(Result);
        end;
        if RoleId <> '' then
            PermissionsMock.Stop();
    end;

    // Every call named in Labels ('a|b|c') answered Expected, with TypeFragment in its problem type.
    local procedure AssertAll(Results: JsonArray; Labels: Text; Expected: Integer; TypeFragment: Text; Who: Text)
    var
        Tok: JsonToken;
        Result: JsonObject;
        Wanted: List of [Text];
        Wrong: Text;
        Seen: Integer;
    begin
        Wanted := Labels.Split('|');
        foreach Tok in Results do begin
            Result := Tok.AsObject();
            if Wanted.Contains(Helper.TextField(Result, 'label')) then begin
                Seen += 1;
                if (IntOf(Result, 'status') <> Expected) or ((TypeFragment <> '') and (StrPos(Helper.TextField(Result, 'type'), TypeFragment) = 0)) then
                    Wrong += StrSubstNo('%1: %2 %3 (%4) | ', Helper.TextField(Result, 'label'), IntOf(Result, 'status'),
                        Helper.TextField(Result, 'type'), CopyStr(Helper.TextField(Result, 'detail'), 1, 200));
            end;
        end;
        LibraryAssert.AreEqual('', Wrong, StrSubstNo('as %1, expected %2 %3', Who, Expected, TypeFragment));
        LibraryAssert.AreEqual(Wanted.Count(), Seen, 'every named call ran: ' + Labels);
    end;

    local procedure ResponseOf(Results: JsonArray; CallLabel: Text) Response: JsonObject
    var
        Tok, ResponseTok: JsonToken;
    begin
        foreach Tok in Results do
            if Helper.TextField(Tok.AsObject(), 'label') = CallLabel then begin
                Tok.AsObject().Get('response', ResponseTok);
                exit(ResponseTok.AsObject());
            end;
        Error('no call labelled %1', CallLabel);
    end;

    local procedure IntOf(Obj: JsonObject; Name: Text): Integer
    var
        Tok: JsonToken;
    begin
        if Obj.Get(Name, Tok) then
            exit(Tok.AsValue().AsInteger());
    end;

    // A committed fixture row with a name and a blob, for the read plane.
    local procedure PrepareFixture()
    var
        TestRecord: Record "Bcmag Test Record";
        Out: OutStream;
    begin
        Prepare("Bcmag Record Changes"::OldAndNewValues, FixtureTok);
        TestRecord.Init();
        TestRecord."Code" := FixtureTok;
        TestRecord.Name := 'Restricted Identity';
        TestRecord.Note.CreateOutStream(Out, TextEncoding::UTF8);
        Out.WriteText('a note');
        TestRecord.Insert();
        Helper.CommitFixtures();
    end;

    local procedure PrepareGated(RecordCode: Code[20])
    begin
        Prepare("Bcmag Record Changes"::OldAndNewValues, RecordCode);
        Helper.ConfigureAllowlistedMode();
        Helper.ExposeTable(Database::"Bcmag Test Record", true, true, true, true);
        Helper.ExposeCodeunitInvoke(Codeunit::"Bcmag Wrap Ping");
        Helper.EnrolProcedure(Codeunit::"Bcmag Wrap Ping", 'Ping', Codeunit::"Bcmag Wrap Ping", "Bcmag Return Shape"::json);
        Helper.EnrolAction(EchoActionTok, Codeunit::"Bcmag Echo Args Wrapper", true);
        Helper.CommitFixtures();
    end;

    // The enrolments are committed fixtures: take them out again so the company's catalogs and
    // allowlist are left as they were.
    local procedure CleanGated()
    var
        ActionCatalog: Record "Bcmag Action Catalog";
    begin
        Helper.RemoveProcedure(Codeunit::"Bcmag Wrap Ping", 'Ping');
        Helper.UnexposeCodeunit(Codeunit::"Bcmag Wrap Ping");
        Helper.UnexposeTable(Database::"Bcmag Test Record");
        if ActionCatalog.Get(EchoActionTok) then
            ActionCatalog.Delete();
        Helper.ConfigureOpenMode();
        Helper.CommitFixtures();
    end;

    local procedure PrepareUnshared()
    var
        Unshared: Record "Bcmag Test Unshared Record";
    begin
        Helper.ConfigureOpenMode();
        if not Unshared.Get('RI-U') then begin
            Unshared."Code" := 'RI-U';
            Unshared.Insert();
        end;
        Helper.CommitFixtures();
    end;

    local procedure AssertNoRecord(RecordCode: Code[20])
    var
        TestRecord: Record "Bcmag Test Record";
    begin
        LibraryAssert.IsFalse(TestRecord.Get(RecordCode), 'no refused write reached the table');
    end;

    local procedure AssertCapabilitiesAs(RoleId: Code[20])
    var
        Response, Body, NoData: JsonObject;
        Tok: JsonToken;
        Status: Integer;
    begin
        Helper.ConfigureOpenMode();
        Helper.CommitFixtures();
        Body := Helper.Envelope(NoData);
        Become(RoleId);
        Response := Dispatcher.RunEx('capabilities', Body, '', Status);
        PermissionsMock.Stop();
        LibraryAssert.AreEqual(200, Status, StrSubstNo('capabilities as %1: %2', RoleId, Describe(Response)));
        Response.Get('value', Tok);
        Tok.AsObject().Get('limits', Tok);
        LibraryAssert.IsTrue(Tok.AsObject().Contains('maxBatchItems'), 'the batch limit is reported to every rung');
    end;

    // From here until PermissionsMock.Stop() the session holds exactly the rung and the test rig.
    local procedure Become(RoleId: Code[20])
    begin
        PermissionsMock.Start();
        PermissionsMock.SetExactPermissionSet(RoleId);
        PermissionsMock.Assign(RigSetTok);
    end;

    local procedure Prepare(Level: Enum "Bcmag Record Changes"; RecordCode: Code[20])
    var
        Setup: Record "Bcmag Setup";
        TestRecord: Record "Bcmag Test Record";
    begin
        Helper.ConfigureOpenMode();
        Setup.GetSingleton();
        Setup."Record Changes" := Level;
        Setup.Modify();
        if TestRecord.Get(RecordCode) then
            TestRecord.Delete();
        Helper.CommitFixtures();
    end;

    local procedure InsertData(RecordCode: Code[20]) Data: JsonObject
    var
        Values: JsonObject;
    begin
        Values.Add('Code', RecordCode);
        Values.Add('Name', 'Restricted Identity');
        Data.Add('tableId', Database::"Bcmag Test Record");
        Data.Add('values', Values);
        Data.Add('init', false);
    end;

    local procedure Describe(Response: JsonObject) Json: Text
    begin
        Response.WriteTo(Json);
        Json := CopyStr(Json, 1, 600);
    end;
}
