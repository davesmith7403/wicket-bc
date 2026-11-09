codeunit 94349 "Bcmag Restricted Identity Test"
{
    Subtype = Test;
    TestPermissions = Disabled;

    // The rest of the suite runs as SUPER, which holds every permission, so a rung that reaches for an
    // object or a table right it was never granted cannot fail there. These tests call the dispatcher
    // as a principal that holds ONE Wicket rung (Microsoft's Permissions Mock), the way an agent's
    // application user does. Each asserts the answer the rung is meant to get — and so fails with a
    // 500 when a handler on that rung calls a codeunit, or writes a table, only a higher rung may.
    //
    // The mock is given EXACTLY the rung plus the test rig (its own objects and its own table as the
    // business table). Deliberately NOT the mock's "All Objects" set and NOT D365 BASIC: both grant
    // execute on every codeunit (D365 BASIC through "BaseApp Objects - Exec"), which hides a rung
    // calling a codeunit above itself. A principal that holds only Wicket sets and a data set — the
    // minimal setup the presets name — has no such wildcard. Fixtures and envelopes are prepared as
    // SUPER first; the mock is stopped before anything is asserted.

    var
        Dispatcher: Codeunit "Bcmag Rpc Dispatcher";
        Helper: Codeunit "Bcmag Test Helper";
        PermissionsMock: Codeunit "Permissions Mock";
        LibraryAssert: Codeunit "Library Assert";
        ReadSetTok: Label 'Wicket - Read', Locked = true;
        ExecuteSetTok: Label 'Wicket - Execute', Locked = true;
        EditSetTok: Label 'Wicket - Edit', Locked = true;
        RigSetTok: Label 'Wicket Test Rig', Locked = true;

    [Test]
    procedure ReadRungGetsCapabilities()
    begin
        AssertCapabilitiesAs(ReadSetTok);
    end;

    [Test]
    procedure ExecuteRungGetsCapabilities()
    begin
        AssertCapabilitiesAs(ExecuteSetTok);
    end;

    [Test]
    procedure EditRungGetsCapabilities()
    begin
        AssertCapabilitiesAs(EditSetTok);
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
