codeunit 94346 "Bcmag Change History Test"
{
    Subtype = Test;
    TestPermissions = Disabled;

    // The change history: what the agent created, changed or deleted through Wicket, old and new per
    // field, under the Setup card's Change History controls.

    var
        OpInsert: Codeunit "Bcmag Op Insert";
        OpModify: Codeunit "Bcmag Op Modify";
        OpDelete: Codeunit "Bcmag Op Delete";
        Dispatcher: Codeunit "Bcmag Rpc Dispatcher";
        Recorder: Codeunit "Bcmag Change Recorder";
        OpChanges: Codeunit "Bcmag Op Changes";
        Masker: Codeunit "Bcmag Field Masker";
        Helper: Codeunit "Bcmag Test Helper";
        LibraryAssert: Codeunit "Library Assert";
        ChangeEchoTok: Label 'bcmag-change-echo', Locked = true;
        ChangeProbeTok: Label 'bcmag-change-probe', Locked = true;
        BcmagAppIdTok: Label '4057cf1f-1b34-409a-a570-c6fdf625c434', Locked = true;

    // ---- Setup controls -----------------------------------------------------------------------------

    [Test]
    procedure FreshSetupRecordsOldAndNewValues()
    var
        Setup: Record "Bcmag Setup";
    begin
        Setup.Init();
        LibraryAssert.AreEqual(Setup."Record Changes"::OldAndNewValues, Setup."Record Changes", 'fresh default: old and new values');
        LibraryAssert.AreEqual(90, Setup."Change Retention Days", 'fresh default: 90 days');
        LibraryAssert.AreEqual(250, Setup."Max Value Length", 'fresh default: 250 characters');
        LibraryAssert.IsTrue(Setup."Agent Can Read Changes", 'fresh default: the agent may read its changes');
    end;

    [Test]
    procedure UpgradeDefaultsTurnTheHistoryOn()
    var
        Setup: Record "Bcmag Setup";
        Upgrade: Codeunit "Bcmag Upgrade";
    begin
        // An upgraded singleton arrives with the SQL defaults (Off, 0, 0, false).
        Setup.Init();
        Setup."Record Changes" := Setup."Record Changes"::Off;
        Setup."Change Retention Days" := 0;
        Setup."Max Value Length" := 0;
        Setup."Agent Can Read Changes" := false;
        Upgrade.ApplyChangeHistoryDefaults(Setup);
        LibraryAssert.AreEqual(Setup."Record Changes"::OldAndNewValues, Setup."Record Changes", 'the upgrade turns the history on');
        LibraryAssert.AreEqual(90, Setup."Change Retention Days", 'the upgrade sets the retention');
        LibraryAssert.AreEqual(250, Setup."Max Value Length", 'the upgrade sets the value length');
        LibraryAssert.IsTrue(Setup."Agent Can Read Changes", 'the upgrade lets the agent read its changes');
    end;

    [Test]
    procedure UpgradeNeverOverridesTheAdministratorOnceDone()
    var
        Setup: Record "Bcmag Setup";
        Upgrade: Codeunit "Bcmag Upgrade";
        UpgradeTag: Codeunit "Upgrade Tag";
    begin
        // Once the upgrade has run (its tag is set), an administrator's Off stays Off.
        if not UpgradeTag.HasUpgradeTag(Upgrade.ChangeHistoryTag()) then
            UpgradeTag.SetUpgradeTag(Upgrade.ChangeHistoryTag());
        Setup.GetSingleton();
        Setup."Record Changes" := Setup."Record Changes"::Off;
        Setup.Modify();
        Upgrade.EnableChangeHistoryOnce(Setup);
        Setup.Get('');
        LibraryAssert.AreEqual(Setup."Record Changes"::Off, Setup."Record Changes", 'the administrator''s Off must stay');
    end;

    // ---- Record changes through insert / modify / delete -------------------------------------------

    [Test]
    procedure ModifyRecordsOldAndNewForEachChangedField()
    var
        Entry: Record "Bcmag Change Entry";
    begin
        Prepare("Bcmag Record Changes"::OldAndNewValues);
        NewCustomer('CH-1', 'Old Co', '111');
        ModifyCustomer('CH-1', 'New Co', '222');
        LastEntry(Entry);
        LibraryAssert.AreEqual(Entry.Kind::Changed, Entry.Kind, 'a modify is recorded as Changed');
        LibraryAssert.AreEqual(Database::Customer, Entry."Table Id", 'the table');
        LibraryAssert.IsTrue(StrPos(Entry."Record Key", 'CH-1') > 0, 'the record key names the customer: ' + Entry."Record Key");
        AssertLine(Entry."Entry No.", 2, 'Old Co', 'New Co', "Bcmag Read Access"::Clear);
        AssertLine(Entry."Entry No.", 9, '111', '222', "Bcmag Read Access"::Clear);
    end;

    [Test]
    procedure ModifyRecordsValidationSideEffects()
    var
        Entry: Record "Bcmag Change Entry";
    begin
        // Customer.Name's validation copies the name into Search Name: the agent sent one field, the
        // table changed two, and the history shows both.
        Prepare("Bcmag Record Changes"::OldAndNewValues);
        NewCustomer('CH-2', 'Old Co', '');
        ModifyCustomer('CH-2', 'New Co', '');
        LastEntry(Entry);
        AssertLine(Entry."Entry No.", 3, 'OLD CO', 'NEW CO', "Bcmag Read Access"::Clear);
    end;

    [Test]
    procedure InsertRecordsEveryNonEmptyField()
    var
        Entry: Record "Bcmag Change Entry";
        Data, Values, Response, Fail: JsonObject;
        Cost: Integer;
    begin
        Prepare("Bcmag Record Changes"::OldAndNewValues);
        DeleteCustomer('CH-3');
        Values.Add('No.', 'CH-3');
        Values.Add('Name', 'Made Co');
        Data.Add('tableId', Database::Customer);
        Data.Add('values', Values);
        Data.Add('init', false);
        LibraryAssert.IsTrue(OpInsert.Run(Data, Response, Fail, Cost), 'insert: ' + Helper.DetailOf(Fail));
        LastEntry(Entry);
        LibraryAssert.AreEqual(Entry.Kind::Created, Entry.Kind, 'an insert is recorded as Created');
        AssertLine(Entry."Entry No.", 1, '', 'CH-3', "Bcmag Read Access"::Clear);
        AssertLine(Entry."Entry No.", 2, '', 'Made Co', "Bcmag Read Access"::Clear);
    end;

    [Test]
    procedure DeleteRecordsEveryNonEmptyField()
    var
        Entry: Record "Bcmag Change Entry";
        Customer: Record Customer;
        Data, Response, Fail: JsonObject;
        Cost: Integer;
    begin
        Prepare("Bcmag Record Changes"::OldAndNewValues);
        NewCustomer('CH-4', 'Gone Co', '444');
        Customer.Get('CH-4');
        Data.Add('tableId', Database::Customer);
        Data.Add('recordId', RecordIdOf(Customer));
        LibraryAssert.IsTrue(OpDelete.Run(Data, Response, Fail, Cost), 'delete: ' + Helper.DetailOf(Fail));
        LastEntry(Entry);
        LibraryAssert.AreEqual(Entry.Kind::Deleted, Entry.Kind, 'a delete is recorded as Deleted');
        AssertLine(Entry."Entry No.", 2, 'Gone Co', '', "Bcmag Read Access"::Clear);
        AssertLine(Entry."Entry No.", 9, '444', '', "Bcmag Read Access"::Clear);
    end;

    [Test]
    procedure FailedModifyLeavesNoEntry()
    var
        Entry: Record "Bcmag Change Entry";
        Customer: Record Customer;
        Data, Values, Response, Fail: JsonObject;
        Cost: Integer;
        Before: Integer;
    begin
        Prepare("Bcmag Record Changes"::OldAndNewValues);
        NewCustomer('CH-5', 'Kept Co', '');
        Customer.Get('CH-5');
        Before := Entry.Count();
        // A stale etag (412) and a value that cannot be coerced (400): nothing changes, nothing is recorded.
        Values.Add('Name', 'Never');
        Data.Add('tableId', Database::Customer);
        Data.Add('recordId', RecordIdOf(Customer));
        Data.Add('etag', 'stale-etag');
        Data.Add('values', Values);
        LibraryAssert.IsFalse(OpModify.Run(Data, Response, Fail, Cost), 'a stale etag must be refused');
        Clear(Data);
        Clear(Values);
        Values.Add('Credit Limit (LCY)', 'not a number');
        Data.Add('tableId', Database::Customer);
        Data.Add('recordId', RecordIdOf(Customer));
        Data.Add('values', Values);
        LibraryAssert.IsFalse(OpModify.Run(Data, Response, Fail, Cost), 'an uncoercible value must be refused');
        LibraryAssert.AreEqual(Before, Entry.Count(), 'a refused write records nothing');
    end;

    [Test]
    procedure MaskedFieldStoredMaskedAndHiddenFieldAsChangedOnly()
    var
        Entry: Record "Bcmag Change Entry";
    begin
        Prepare("Bcmag Record Changes"::OldAndNewValues);
        NewCustomer('CH-6', 'Old Co', '5550011');
        Helper.SetFieldPolicyMode("Bcmag Field Policy Mode"::Explicit);
        Helper.SetFieldAccess(Database::Customer, 1, "Bcmag Read Access"::Clear, '', false);
        Helper.SetFieldAccess(Database::Customer, 2, "Bcmag Read Access"::Clear, '', true);
        Helper.SetFieldAccess(Database::Customer, 3, "Bcmag Read Access"::Hidden, '', false);
        Helper.SetFieldAccess(Database::Customer, 9, "Bcmag Read Access"::Masked, 'PARTIAL', true);
        ModifyCustomer('CH-6', 'New Co', '5559988');
        LastEntry(Entry);
        AssertLine(Entry."Entry No.", 9, Masker.MaskText('5550011', 'PARTIAL'), Masker.MaskText('5559988', 'PARTIAL'), "Bcmag Read Access"::Masked);
        AssertLine(Entry."Entry No.", 3, '', '', "Bcmag Read Access"::Hidden);
    end;

    [Test]
    procedure FieldsOnlyStoresNoValues()
    var
        Entry: Record "Bcmag Change Entry";
    begin
        Prepare("Bcmag Record Changes"::FieldsOnly);
        NewCustomer('CH-7', 'Old Co', '');
        ModifyCustomer('CH-7', 'New Co', '');
        LastEntry(Entry);
        AssertLine(Entry."Entry No.", 2, '', '', "Bcmag Read Access"::Clear);
    end;

    [Test]
    procedure OffRecordsNothing()
    var
        Entry: Record "Bcmag Change Entry";
        Before: Integer;
    begin
        Prepare("Bcmag Record Changes"::Off);
        NewCustomer('CH-8', 'Old Co', '');
        Before := Entry.Count();
        ModifyCustomer('CH-8', 'New Co', '');
        LibraryAssert.AreEqual(Before, Entry.Count(), 'Off records nothing');
    end;

    [Test]
    procedure LongValueIsCutAndMarked()
    var
        Entry: Record "Bcmag Change Entry";
        FieldChange: Record "Bcmag Field Change";
        Setup: Record "Bcmag Setup";
    begin
        Prepare("Bcmag Record Changes"::OldAndNewValues);
        Setup.GetSingleton();
        Setup."Max Value Length" := 20;
        Setup.Modify();
        NewCustomer('CH-9', 'Old Co', '');
        ModifyCustomer('CH-9', 'A name well over twenty characters long', '');
        LastEntry(Entry);
        FieldChange.Get(Entry."Entry No.", LineNoOf(Entry."Entry No.", 2));
        LibraryAssert.AreEqual(20, StrLen(FieldChange."New Value"), 'cut to Max Value Length');
        LibraryAssert.IsTrue(FieldChange.Truncated, 'marked as cut');
    end;

    [Test]
    procedure BinaryFieldOfADeletedRecordIsListedWithoutValues()
    var
        Entry: Record "Bcmag Change Entry";
        FieldChange: Record "Bcmag Field Change";
        Catalog: Record "Bcmag Action Catalog";
        RecRef: RecordRef;
        OutStr: OutStream;
        Before: Dictionary of [Integer, Text];
    begin
        // Wicket never writes a Blob or Media field, so only a created or deleted record lists one,
        // as changed and without values.
        Prepare("Bcmag Record Changes"::OldAndNewValues);
        if Catalog.Get('CH-BLOB') then Catalog.Delete();
        Catalog.Init();
        Catalog."Action Code" := 'CH-BLOB';
        Catalog."Wrapper Codeunit Id" := Codeunit::"Bcmag Wrap Ping";
        Catalog."Args Schema".CreateOutStream(OutStr);
        OutStr.WriteText('{"type":"object"}');
        Catalog.Insert();
        Catalog.Get('CH-BLOB');
        RecRef.GetTable(Catalog);
        Before := Recorder.Snapshot(RecRef);
        Recorder.RecordDeleted(Before, RecRef);
        LastEntry(Entry);
        FieldChange.Get(Entry."Entry No.", LineNoOf(Entry."Entry No.", Catalog.FieldNo("Args Schema")));
        LibraryAssert.AreEqual('', FieldChange."Old Value", 'no value for a binary field');
        LibraryAssert.AreEqual('', FieldChange."New Value", 'no value for a binary field');
    end;

    [Test]
    procedure EntryNamesTheRequestAndTheConnection()
    var
        Entry: Record "Bcmag Change Entry";
        Customer: Record Customer;
        Body, Data, Values: JsonObject;
        Status: Integer;
        Id: Text;
    begin
        Prepare("Bcmag Record Changes"::OldAndNewValues);
        NewCustomer('CH-10', 'Old Co', '');
        Customer.Get('CH-10');
        Values.Add('Name', 'New Co');
        Data.Add('tableId', Database::Customer);
        Data.Add('recordId', RecordIdOf(Customer));
        Data.Add('values', Values);
        Id := DelChr(LowerCase(Format(CreateGuid())), '<>', '{}');
        Body.Add('id', Id);
        Body.Add('issuedAt', Format(CurrentDateTime(), 0, 9));
        Body.Add('origin', 'mcp.wicket/2.6.0+contoso-sandbox');
        Body.Add('data', Data);
        Helper.CommitFixtures();
        Dispatcher.RunEx('modify', Body, '', Status);
        LibraryAssert.AreEqual(200, Status, 'the modify through the dispatcher');
        LastEntry(Entry);
        LibraryAssert.AreEqual(Id, Entry."Request Id", 'the entry names its request');
        LibraryAssert.AreEqual('contoso-sandbox', Entry.Connection, 'the connection is the origin after +');
        LibraryAssert.AreEqual(UserSecurityId(), Entry."User Security Id", 'the BC user who made the change');
    end;

    // ---- Actions and procedures ----------------------------------------------------------------------

    [Test]
    procedure ActionRunRecordsOneEntryWithResult()
    var
        Entry: Record "Bcmag Change Entry";
        FieldChange: Record "Bcmag Field Change";
        Args, Response, Fail: JsonObject;
    begin
        Prepare("Bcmag Record Changes"::OldAndNewValues);
        Helper.EnrolAction(ChangeEchoTok, Codeunit::"Bcmag Echo Args Wrapper", true);
        Args.Add('marker', 'hello');
        LibraryAssert.IsTrue(RunAction(ActionData(ChangeEchoTok, Args, false), Response, Fail), 'action: ' + Helper.DetailOf(Fail));
        LastEntry(Entry);
        LibraryAssert.AreEqual(Entry.Kind::Action, Entry.Kind, 'an action run is recorded as Action');
        LibraryAssert.AreEqual(ChangeEchoTok, Entry.Name, 'the action code');
        LibraryAssert.AreEqual('Succeeded', Entry.Outcome, 'the outcome');
        LibraryAssert.IsTrue(StrPos(Entry.Result, 'hello') > 0, 'the result the action returned: ' + Entry.Result);
        FieldChange.SetRange("Entry No.", Entry."Entry No.");
        LibraryAssert.IsTrue(FieldChange.IsEmpty(), 'an action has no field lines');
    end;

    [Test]
    procedure PreviewRecordsNothing()
    var
        Entry: Record "Bcmag Change Entry";
        Args, Response, Fail: JsonObject;
        Before: Integer;
    begin
        Prepare("Bcmag Record Changes"::OldAndNewValues);
        Helper.EnrolAction(ChangeEchoTok, Codeunit::"Bcmag Echo Args Wrapper", true);
        Before := Entry.Count();
        LibraryAssert.IsTrue(RunAction(ActionData(ChangeEchoTok, Args, true), Response, Fail), 'preview: ' + Helper.DetailOf(Fail));
        LibraryAssert.AreEqual(Before, Entry.Count(), 'a preview changes nothing and is not listed');
    end;

    [Test]
    procedure NonMutatingVerbRecordsNothing()
    var
        Entry: Record "Bcmag Change Entry";
        Catalog: Record "Bcmag Action Catalog";
        Args, Response, Fail: JsonObject;
        Before: Integer;
    begin
        Prepare("Bcmag Record Changes"::OldAndNewValues);
        Helper.EnrolAction(ChangeEchoTok, Codeunit::"Bcmag Echo Args Wrapper", false);
        Catalog.Get(ChangeEchoTok);
        Catalog."Is Mutating" := false;
        Catalog.Modify();
        Before := Entry.Count();
        LibraryAssert.IsTrue(RunAction(ActionData(ChangeEchoTok, Args, false), Response, Fail), 'run: ' + Helper.DetailOf(Fail));
        LibraryAssert.AreEqual(Before, Entry.Count(), 'a verb that changes nothing is not listed');
    end;

    [Test]
    procedure FailedMutatingActionRecordsFailedMayHaveChanged()
    var
        Entry: Record "Bcmag Change Entry";
        Args, Response: JsonObject;
        Status: Integer;
    begin
        // The wrapper commits a write and then fails: the data changed, and the history says so.
        Prepare("Bcmag Record Changes"::OldAndNewValues);
        Helper.EnrolAction(ChangeProbeTok, Codeunit::"Bcmag Rollback Probe Wrapper", false);
        Args.Add('marker', 'change-history-probe');
        Args.Add('commit', true);
        Args.Add('failAfterWrite', true);
        // Through the dispatcher: the runner rolls a failed request's own writes back, and the entry
        // must survive that.
        Helper.CommitFixtures();
        Response := Dispatcher.RunEx('action', Helper.EnvelopeWithKey(ActionData(ChangeProbeTok, Args, false), Helper.NewIdemKey()), '', Status);
        LibraryAssert.AreEqual(422, Status, 'the probe fails');
        LastEntry(Entry);
        LibraryAssert.AreEqual(Entry.Kind::Action, Entry.Kind, 'the failed run is listed');
        LibraryAssert.AreEqual(ChangeProbeTok, Entry.Name, 'the action code');
        LibraryAssert.AreEqual('Failed - may have changed data', Entry.Outcome, 'the outcome says data may have changed');
    end;

    [Test]
    procedure ErrorAfterTheWrapperReturnedRecordsMayHaveChanged()
    var
        Entry: Record "Bcmag Change Entry";
        ActivityLog: Record "Activity Log";
        FailSucceeded: Codeunit "Bcmag Fail Succeeded Entry";
        Args, Target, Data: JsonObject;
        Status: Integer;
        Before: BigInteger;
    begin
        // The wrapper commits and returns, then an error escapes before the request completes: the
        // request is a 500, the write persisted, and the history must still say data may have changed.
        Prepare("Bcmag Record Changes"::OldAndNewValues);
        Helper.EnrolAction(ChangeProbeTok, Codeunit::"Bcmag Rollback Probe Wrapper", false);
        NewCustomer('CH-AFTER', 'After Wrapper', '');
        Args.Add('marker', 'change-history-after');
        Args.Add('commit', true);
        Data := ActionData(ChangeProbeTok, Args, false);
        Target.Add('systemId', Format(CustomerSystemId('CH-AFTER'), 0, 4));
        Data.Add('target', Target);
        Helper.CommitFixtures();
        if Entry.FindLast() then
            Before := Entry."Entry No.";
        BindSubscription(FailSucceeded);
        Dispatcher.RunEx('action', Helper.EnvelopeWithKey(Data, Helper.NewIdemKey()), '', Status);
        UnbindSubscription(FailSucceeded);
        LibraryAssert.AreEqual(500, Status, 'an error after the wrapper returned');
        ActivityLog.SetRange(Description, 'change-history-after');
        LibraryAssert.IsFalse(ActivityLog.IsEmpty(), 'the wrapper''s committed write persisted');
        LastEntry(Entry);
        LibraryAssert.IsTrue(Entry."Entry No." > Before, 'a new entry for this run');
        LibraryAssert.AreEqual(Entry.Kind::Action, Entry.Kind, 'the run is listed');
        LibraryAssert.AreEqual(ChangeProbeTok, Entry.Name, 'the action code');
        LibraryAssert.AreEqual('Failed - may have changed data', Entry.Outcome, 'the outcome says data may have changed');
        LibraryAssert.AreEqual(CustomerSystemId('CH-AFTER'), Entry."Record SystemId", 'the target');
    end;

    [Test]
    procedure ActionWithoutResultKeepsItsTarget()
    var
        Entry: Record "Bcmag Change Entry";
        Args, Target, Data, Response, Fail: JsonObject;
    begin
        Prepare("Bcmag Record Changes"::OldAndNewValues);
        Helper.EnrolAction(ChangeEchoTok, Codeunit::"Bcmag Echo Args Wrapper", true);
        NewCustomer('CH-NORES', 'No Result', '');
        Args.Add('noResult', true);
        Data := ActionData(ChangeEchoTok, Args, false);
        Target.Add('systemId', Format(CustomerSystemId('CH-NORES'), 0, 4));
        Data.Add('target', Target);
        LibraryAssert.IsTrue(RunAction(Data, Response, Fail), 'action: ' + Helper.DetailOf(Fail));
        LastEntry(Entry);
        LibraryAssert.AreEqual(CustomerSystemId('CH-NORES'), Entry."Record SystemId", 'the target, though the wrapper returned nothing');
    end;

    [Test]
    procedure NewCompaniesAndFreshInstallsKeepTheAdministratorsChoice()
    var
        UpgradeTag: Codeunit "Upgrade Tag";
        Upgrade: Codeunit "Bcmag Upgrade";
        Tags: List of [Code[250]];
    begin
        // A company created (or installed) with the history settings already in place must never get
        // them reset by the next upgrade: the one-time switch is registered as done for it.
        UpgradeTag.GetPerCompanyUpgradeTags(Tags);
        LibraryAssert.IsTrue(Tags.Contains(Upgrade.ChangeHistoryTag()), 'the change history tag is a per-company tag');
    end;

    [Test]
    procedure InvokeRecordsProcedureEntry()
    var
        Entry: Record "Bcmag Change Entry";
        OpInvoke: Codeunit "Bcmag Op Invoke";
        Data, Args, Response, Fail: JsonObject;
        Cost: Integer;
    begin
        Prepare("Bcmag Record Changes"::OldAndNewValues);
        Helper.ExposeCodeunitInvoke(94190);
        Helper.EnrolProcedure(94190, 'Ping', 94190, "Bcmag Return Shape"::json);
        Args.Add('message', 'hi');
        Data.Add('codeunitId', 94190);
        Data.Add('procedure', 'Ping');
        Data.Add('args', Args);
        Helper.CommitFixtures();
        LibraryAssert.IsTrue(OpInvoke.Run(Data, Response, Fail, Cost), 'invoke: ' + Helper.DetailOf(Fail));
        LastEntry(Entry);
        LibraryAssert.AreEqual(Entry.Kind::ProcedureRun, Entry.Kind, 'an invoke is recorded as Procedure');
        LibraryAssert.AreEqual('94190.Ping', Entry.Name, 'codeunit and procedure');
        LibraryAssert.AreEqual('Succeeded', Entry.Outcome, 'the outcome');
    end;

    local procedure ActionData(ActionCode: Text; Args: JsonObject; Preview: Boolean) Data: JsonObject
    begin
        Data.Add('action', ActionCode);
        Data.Add('args', Args);
        if Preview then
            Data.Add('preview', true);
    end;

    local procedure RunAction(Data: JsonObject; var Response: JsonObject; var Fail: JsonObject): Boolean
    var
        OpAction: Codeunit "Bcmag Op Action";
        Cost: Integer;
    begin
        Helper.CommitFixtures();
        exit(OpAction.Run(Data, Response, Fail, Cost));
    end;

    // ---- Page, permission, retention, read denial -----------------------------------------------------

    [Test]
    procedure PurgeRemovesEntriesPastRetentionWithTheirLines()
    var
        Entry: Record "Bcmag Change Entry";
        FieldChange: Record "Bcmag Field Change";
        Setup: Record "Bcmag Setup";
        LogPurge: Codeunit "Bcmag Log Purge";
        OldNo, NewNo: BigInteger;
    begin
        Prepare("Bcmag Record Changes"::OldAndNewValues);
        Setup.GetSingleton();
        Setup."Change Retention Days" := 30;
        Setup.Modify();
        OldNo := SeedEntry(CreateDateTime(Today() - 40, 0T));
        NewNo := SeedEntry(CurrentDateTime());
        LogPurge.PurgeExpired();
        LibraryAssert.IsFalse(Entry.Get(OldNo), 'an entry past the retention is purged');
        FieldChange.SetRange("Entry No.", OldNo);
        LibraryAssert.IsTrue(FieldChange.IsEmpty(), 'with its field lines');
        LibraryAssert.IsTrue(Entry.Get(NewNo), 'a recent entry stays');
        FieldChange.SetRange("Entry No.", NewNo);
        LibraryAssert.IsFalse(FieldChange.IsEmpty(), 'with its field lines');
    end;

    [Test]
    procedure PurgeOfTheHistoryDoesNotWaitForTheOperationLogSetting()
    var
        Entry: Record "Bcmag Change Entry";
        Setup: Record "Bcmag Setup";
        LogPurge: Codeunit "Bcmag Log Purge";
        OldNo: BigInteger;
    begin
        // "Operation Log Retention Days" = 0 keeps the Operation Log forever; the history has its own.
        Prepare("Bcmag Record Changes"::OldAndNewValues);
        Setup.GetSingleton();
        Setup."Operation Log Retention Days" := 0;
        Setup."Change Retention Days" := 30;
        Setup.Modify();
        OldNo := SeedEntry(CreateDateTime(Today() - 40, 0T));
        LogPurge.PurgeExpired();
        LibraryAssert.IsFalse(Entry.Get(OldNo), 'the history keeps its own retention');
    end;

    [Test]
    procedure HistoryTablesAreNotReadableThroughQuery()
    var
        Data, Response, Fail: JsonObject;
        OpQuery: Codeunit "Bcmag Op Query";
        Cost: Integer;
        TableId: Integer;
    begin
        // They hold other principals' rows: denied on the data plane in every mode, like the Operation Log.
        Prepare("Bcmag Record Changes"::OldAndNewValues);
        foreach TableId in HistoryTables() do begin
            Clear(Data);
            Clear(Response);
            Clear(Fail);
            Data.Add('tableId', TableId);
            LibraryAssert.IsFalse(OpQuery.Run(Data, Response, Fail, Cost), StrSubstNo('query on %1 must be refused', TableId));
            LibraryAssert.AreEqual(403, Helper.StatusOf(Fail), StrSubstNo('403 for table %1', TableId));
        end;
    end;

    [Test]
    procedure AuditChangesSetIsInAuditAndAdmin()
    var
        Perm: Record "Expanded Permission";
        Roles: List of [Text];
        RoleId: Text;
    begin
        Roles.Add('Wicket - Changes');
        Roles.Add('Wicket - Audit');
        Roles.Add('Wicket - Admin');
        foreach RoleId in Roles do begin
            LibraryAssert.IsTrue(FindPermission(RoleId, Perm."Object Type"::"Table Data", Database::"Bcmag Changes Gate", Perm),
                RoleId + ' must reach the Changes Gate');
            LibraryAssert.AreEqual(Perm."Modify Permission"::Yes, Perm."Modify Permission", RoleId + ': the gate is written-permission, like the Unmask gate');
            LibraryAssert.IsTrue(FindPermission(RoleId, Perm."Object Type"::"Table Data", Database::"Bcmag Change Entry", Perm),
                RoleId + ' must read the change entries');
            LibraryAssert.AreEqual(Perm."Read Permission"::Yes, Perm."Read Permission", RoleId + ': read');
        end;
        LibraryAssert.IsFalse(FindPermission('Wicket - Read', Perm."Object Type"::"Table Data", Database::"Bcmag Changes Gate", Perm)
            and (Perm."Modify Permission" = Perm."Modify Permission"::Yes), 'the read rung must not see everyone''s changes');
    end;

    local procedure HistoryTables() Ids: List of [Integer]
    begin
        Ids.Add(Database::"Bcmag Change Entry");
        Ids.Add(Database::"Bcmag Field Change");
        Ids.Add(Database::"Bcmag Changes Gate");
    end;

    local procedure SeedEntry(CreatedAt: DateTime): BigInteger
    var
        Entry: Record "Bcmag Change Entry";
        FieldChange: Record "Bcmag Field Change";
    begin
        Entry.Init();
        Entry."Entry No." := 0;
        Entry.Kind := Entry.Kind::Changed;
        Entry."Created At" := CreatedAt;
        Entry."Table Id" := Database::Customer;
        Entry.Insert();
        FieldChange.Init();
        FieldChange."Entry No." := Entry."Entry No.";
        FieldChange."Line No." := 10000;
        FieldChange."Field No." := 2;
        FieldChange.Insert();
        exit(Entry."Entry No.");
    end;

    local procedure FindPermission(RoleId: Text; ObjectType: Option; ObjectId: Integer; var Perm: Record "Expanded Permission"): Boolean
    var
        AppId: Guid;
    begin
        Evaluate(AppId, BcmagAppIdTok);
        Perm.Reset();
        Perm.SetRange("App ID", AppId);
        Perm.SetRange("Role ID", CopyStr(RoleId, 1, MaxStrLen(Perm."Role ID")));
        Perm.SetRange("Object Type", ObjectType);
        Perm.SetRange("Object ID", ObjectId);
        exit(Perm.FindFirst());
    end;

    // ---- The changes operation -----------------------------------------------------------------------

    [Test]
    procedure ChangesReturnsOwnEntriesOnly()
    var
        Response, Fail: JsonObject;
        Mine, Theirs: BigInteger;
    begin
        Prepare("Bcmag Record Changes"::OldAndNewValues);
        Mine := SeedEntryFor(UserSecurityId(), CurrentDateTime());
        Theirs := SeedEntryFor(CreateGuid(), CurrentDateTime());
        LibraryAssert.IsTrue(OpChanges.RunScoped(NoFilter(), false, Response, Fail), 'changes: ' + Helper.DetailOf(Fail));
        LibraryAssert.IsTrue(HasEntry(Response, Mine), 'the caller sees its own entry');
        LibraryAssert.IsFalse(HasEntry(Response, Theirs), 'and never another principal''s');
    end;

    [Test]
    procedure GateHolderSeesEveryone()
    var
        Response, Fail: JsonObject;
        Mine, Theirs: BigInteger;
    begin
        Prepare("Bcmag Record Changes"::OldAndNewValues);
        Mine := SeedEntryFor(UserSecurityId(), CurrentDateTime());
        Theirs := SeedEntryFor(CreateGuid(), CurrentDateTime());
        LibraryAssert.IsTrue(OpChanges.RunScoped(NoFilter(), true, Response, Fail), 'changes: ' + Helper.DetailOf(Fail));
        LibraryAssert.IsTrue(HasEntry(Response, Mine) and HasEntry(Response, Theirs), 'the auditor sees every principal''s entries');
    end;

    [Test]
    procedure UserFilterWithoutGateIsRefused()
    var
        Data, Response, Fail: JsonObject;
    begin
        Prepare("Bcmag Record Changes"::OldAndNewValues);
        Data.Add('user', 'SOMEONE');
        LibraryAssert.IsFalse(OpChanges.RunScoped(Data, false, Response, Fail), 'a user filter needs the gate');
        LibraryAssert.AreEqual(403, Helper.StatusOf(Fail), '403');
        LibraryAssert.IsTrue(StrPos(Helper.TypeOf(Fail), 'changes-forbidden') > 0, 'changes-forbidden: ' + Helper.TypeOf(Fail));
    end;

    [Test]
    procedure ChangesOffIsRefused()
    var
        Setup: Record "Bcmag Setup";
        Response, Fail: JsonObject;
        Cost: Integer;
    begin
        Prepare("Bcmag Record Changes"::OldAndNewValues);
        Setup.GetSingleton();
        Setup."Agent Can Read Changes" := false;
        Setup.Modify();
        LibraryAssert.IsFalse(OpChanges.Run(NoFilter(), Response, Fail, Cost), 'the switch is off');
        LibraryAssert.IsTrue(StrPos(Helper.TypeOf(Fail), 'changes-off') > 0, 'changes-off: ' + Helper.TypeOf(Fail));
        Setup."Agent Can Read Changes" := true;
        Setup."Record Changes" := Setup."Record Changes"::Off;
        Setup.Modify();
        Clear(Fail);
        LibraryAssert.IsFalse(OpChanges.Run(NoFilter(), Response, Fail, Cost), 'the history is off');
        LibraryAssert.IsTrue(StrPos(Helper.TypeOf(Fail), 'changes-off') > 0, 'changes-off: ' + Helper.TypeOf(Fail));
    end;

    [Test]
    procedure TightenedFieldIsDowngradedOnRead()
    var
        Response, Fail, FieldObj: JsonObject;
        EntryNo: BigInteger;
    begin
        // Stored Clear; the policy now masks the field, then hides it: the reader gets no more than now allowed.
        Prepare("Bcmag Record Changes"::OldAndNewValues);
        EntryNo := SeedEntryFor(UserSecurityId(), CurrentDateTime());
        SeedLine(EntryNo, 9, '5550011', '5559988', "Bcmag Read Access"::Clear);
        Helper.SetFieldPolicyMode("Bcmag Field Policy Mode"::Explicit);
        Helper.SetFieldAccess(Database::Customer, 9, "Bcmag Read Access"::Masked, 'PARTIAL', false);
        LibraryAssert.IsTrue(OpChanges.RunScoped(NoFilter(), false, Response, Fail), 'changes: ' + Helper.DetailOf(Fail));
        FieldObj := FieldOf(Response, EntryNo, 9);
        LibraryAssert.AreEqual('masked', Helper.TextField(FieldObj, 'shownAs'), 'now masked');
        LibraryAssert.AreEqual(Masker.MaskText('5550011', 'PARTIAL'), Helper.TextField(FieldObj, 'old'), 'the stored value masked now');

        Helper.SetFieldAccess(Database::Customer, 9, "Bcmag Read Access"::Hidden, '', false);
        Clear(Response);
        LibraryAssert.IsTrue(OpChanges.RunScoped(NoFilter(), false, Response, Fail), 'changes: ' + Helper.DetailOf(Fail));
        FieldObj := FieldOf(Response, EntryNo, 9);
        LibraryAssert.AreEqual('hidden', Helper.TextField(FieldObj, 'shownAs'), 'now hidden');
        LibraryAssert.IsFalse(FieldObj.Contains('old') or FieldObj.Contains('new'), 'a hidden field carries no values');
    end;

    [Test]
    procedure NeverShownMoreClearlyThanStored()
    var
        Response, Fail, FieldObj: JsonObject;
        EntryNo: BigInteger;
    begin
        // Stored Masked; the policy now shows the field in clear: the stored mask is all there is.
        Prepare("Bcmag Record Changes"::OldAndNewValues);
        EntryNo := SeedEntryFor(UserSecurityId(), CurrentDateTime());
        SeedLine(EntryNo, 9, '****11', '****88', "Bcmag Read Access"::Masked);
        LibraryAssert.IsTrue(OpChanges.RunScoped(NoFilter(), false, Response, Fail), 'changes: ' + Helper.DetailOf(Fail));
        FieldObj := FieldOf(Response, EntryNo, 9);
        LibraryAssert.AreEqual('masked', Helper.TextField(FieldObj, 'shownAs'), 'stays masked');
        LibraryAssert.AreEqual('****11', Helper.TextField(FieldObj, 'old'), 'the stored rendering');
    end;

    [Test]
    procedure PagingFollowsCursor()
    var
        Data, Response, Fail: JsonObject;
        First, Second, Third: BigInteger;
        Cursor: Text;
    begin
        Prepare("Bcmag Record Changes"::OldAndNewValues);
        First := SeedEntryFor(UserSecurityId(), CurrentDateTime());
        Second := SeedEntryFor(UserSecurityId(), CurrentDateTime());
        Third := SeedEntryFor(UserSecurityId(), CurrentDateTime());
        Data.Add('top', 2);
        LibraryAssert.IsTrue(OpChanges.RunScoped(Data, false, Response, Fail), 'page 1: ' + Helper.DetailOf(Fail));
        LibraryAssert.IsTrue(HasEntry(Response, Third) and HasEntry(Response, Second), 'newest first');
        LibraryAssert.IsFalse(HasEntry(Response, First), 'the page holds two');
        Cursor := Helper.TextField(Response, '@nextLink');
        LibraryAssert.AreNotEqual('', Cursor, 'a cursor to the next page');
        Clear(Data);
        Clear(Response);
        Data.Add('top', 2);
        Data.Add('cursor', Cursor);
        LibraryAssert.IsTrue(OpChanges.RunScoped(Data, false, Response, Fail), 'page 2: ' + Helper.DetailOf(Fail));
        LibraryAssert.IsTrue(HasEntry(Response, First), 'the next page continues');
        LibraryAssert.IsFalse(HasEntry(Response, Third), 'without repeating');
    end;

    local procedure NoFilter() Data: JsonObject
    begin
    end;

    local procedure SeedEntryFor(UserSid: Guid; CreatedAt: DateTime): BigInteger
    var
        Entry: Record "Bcmag Change Entry";
    begin
        Entry.Init();
        Entry."Entry No." := 0;
        Entry.Kind := Entry.Kind::Changed;
        Entry."Created At" := CreatedAt;
        Entry."Table Id" := Database::Customer;
        Entry."Table Name" := 'Customer';
        Entry."User Security Id" := UserSid;
        Entry.Insert();
        exit(Entry."Entry No.");
    end;

    local procedure SeedLine(EntryNo: BigInteger; FieldNo: Integer; OldValue: Text; NewValue: Text; StoredAs: Enum "Bcmag Read Access")
    var
        FieldChange: Record "Bcmag Field Change";
    begin
        FieldChange.Init();
        FieldChange."Entry No." := EntryNo;
        FieldChange."Line No." := FieldNo * 10;
        FieldChange."Field No." := FieldNo;
        FieldChange."Old Value" := CopyStr(OldValue, 1, MaxStrLen(FieldChange."Old Value"));
        FieldChange."New Value" := CopyStr(NewValue, 1, MaxStrLen(FieldChange."New Value"));
        FieldChange."Stored As" := StoredAs;
        FieldChange.Insert();
    end;

    local procedure HasEntry(Response: JsonObject; EntryNo: BigInteger): Boolean
    var
        Obj: JsonObject;
    begin
        exit(FindEntry(Response, EntryNo, Obj));
    end;

    local procedure FindEntry(Response: JsonObject; EntryNo: BigInteger; var Obj: JsonObject): Boolean
    var
        Tok, EntryTok: JsonToken;
    begin
        if not Response.Get('value', Tok) then
            exit(false);
        foreach EntryTok in Tok.AsArray() do begin
            Obj := EntryTok.AsObject();
            if Obj.Get('entryNo', Tok) then
                if Tok.AsValue().AsBigInteger() = EntryNo then
                    exit(true);
        end;
        exit(false);
    end;

    local procedure FieldOf(Response: JsonObject; EntryNo: BigInteger; FieldNo: Integer) Result: JsonObject
    var
        EntryObj: JsonObject;
        Tok, FieldTok: JsonToken;
    begin
        LibraryAssert.IsTrue(FindEntry(Response, EntryNo, EntryObj), 'the entry is in the answer');
        EntryObj.Get('fields', Tok);
        foreach FieldTok in Tok.AsArray() do begin
            Result := FieldTok.AsObject();
            if Result.Get('fieldNo', Tok) then
                if Tok.AsValue().AsInteger() = FieldNo then
                    exit(Result);
        end;
        LibraryAssert.Fail(StrSubstNo('field %1 is not in entry %2', FieldNo, EntryNo));
    end;

    // ---- helpers -------------------------------------------------------------------------------------

    local procedure Prepare(Level: Enum "Bcmag Record Changes")
    var
        Setup: Record "Bcmag Setup";
    begin
        Helper.ConfigureOpenMode();
        Helper.ResetFieldPolicyState();
        Helper.SetFieldPolicyMode("Bcmag Field Policy Mode"::AllFields);
        Helper.EnsureManualCustomerNos();
        Setup.GetSingleton();
        Setup."Record Changes" := Level;
        Setup."Max Value Length" := 250;
        Setup.Modify();
    end;

    local procedure NewCustomer(No: Code[20]; Name: Text[100]; Phone: Text[30])
    var
        Customer: Record Customer;
    begin
        DeleteCustomer(No);
        Customer.Init();
        Customer."No." := No;
        Customer.Name := Name;
        Customer."Search Name" := UpperCase(Name);
        Customer."Phone No." := Phone;
        Customer.Insert();
    end;

    local procedure DeleteCustomer(No: Code[20])
    var
        Customer: Record Customer;
    begin
        if Customer.Get(No) then
            Customer.Delete();
    end;

    local procedure ModifyCustomer(No: Code[20]; Name: Text; Phone: Text)
    var
        Customer: Record Customer;
        Data, Values, Response, Fail: JsonObject;
        Cost: Integer;
    begin
        Customer.Get(No);
        Values.Add('Name', Name);
        if Phone <> '' then
            Values.Add('Phone No.', Phone);
        Data.Add('tableId', Database::Customer);
        Data.Add('recordId', RecordIdOf(Customer));
        Data.Add('values', Values);
        LibraryAssert.IsTrue(OpModify.Run(Data, Response, Fail, Cost), 'modify: ' + Helper.DetailOf(Fail));
    end;

    local procedure RecordIdOf(Customer: Record Customer): Text
    var
        Codec: Codeunit "Bcmag Record Id Codec";
    begin
        exit(Codec.Encode(Customer.RecordId));
    end;

    local procedure CustomerSystemId(No: Code[20]): Guid
    var
        Customer: Record Customer;
    begin
        Customer.Get(No);
        exit(Customer.SystemId);
    end;

    local procedure LastEntry(var Entry: Record "Bcmag Change Entry")
    begin
        Entry.Reset();
        LibraryAssert.IsTrue(Entry.FindLast(), 'a change entry must exist');
    end;

    local procedure LineNoOf(EntryNo: BigInteger; FieldNo: Integer): Integer
    var
        FieldChange: Record "Bcmag Field Change";
    begin
        FieldChange.SetRange("Entry No.", EntryNo);
        FieldChange.SetRange("Field No.", FieldNo);
        LibraryAssert.IsTrue(FieldChange.FindFirst(), StrSubstNo('a line for field %1', FieldNo));
        exit(FieldChange."Line No.");
    end;

    local procedure AssertLine(EntryNo: BigInteger; FieldNo: Integer; OldValue: Text; NewValue: Text; StoredAs: Enum "Bcmag Read Access")
    var
        FieldChange: Record "Bcmag Field Change";
    begin
        FieldChange.Get(EntryNo, LineNoOf(EntryNo, FieldNo));
        LibraryAssert.AreEqual(OldValue, FieldChange."Old Value", StrSubstNo('old value of field %1', FieldNo));
        LibraryAssert.AreEqual(NewValue, FieldChange."New Value", StrSubstNo('new value of field %1', FieldNo));
        LibraryAssert.AreEqual(StoredAs, FieldChange."Stored As", StrSubstNo('stored-as of field %1', FieldNo));
    end;
}
