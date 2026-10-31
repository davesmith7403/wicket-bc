codeunit 94348 "Bcmag Batch Test"
{
    Subtype = Test;
    TestPermissions = Disabled;

    // The batch operation: many inserts, modifies and deletes in one call and one transaction. Every item
    // runs through the single-record handlers; the first failing item stops the batch, nothing is written,
    // and the problem names the item. A preview runs every item and rolls back.

    var
        OpBatch: Codeunit "Bcmag Op Batch";
        Dispatcher: Codeunit "Bcmag Rpc Dispatcher";
        Helper: Codeunit "Bcmag Test Helper";
        LibraryAssert: Codeunit "Library Assert";

    [Test]
    procedure BatchCommitsEveryItem()
    var
        Customer: Record Customer;
        Items: JsonArray;
        Response, Fail, Value: JsonObject;
        Tok: JsonToken;
        Cost: Integer;
    begin
        Prepare();
        DeleteCustomers('BT-1|BT-2');
        Items.Add(InsertCustomer('BT-1', 'Batch One'));
        Items.Add(InsertCustomer('BT-2', 'Batch Two'));
        Items.Add(ModifyName(FromItem(0), 'Batch One Renamed'));
        Items.Add(DeleteItem(Database::Customer, FromItem(1)));
        LibraryAssert.IsTrue(OpBatch.Run(BatchData(Items, false), Response, Fail, Cost), 'batch: ' + Helper.DetailOf(Fail));

        Customer.Get('BT-1');
        LibraryAssert.AreEqual('Batch One Renamed', Customer.Name, 'the modify through a reference to the insert');
        LibraryAssert.IsFalse(Customer.Get('BT-2'), 'the delete through a reference to the insert');
        Value := Helper.ValueObject(Response);
        Value.Get('items', Tok);
        LibraryAssert.AreEqual(4, Tok.AsArray().Count(), 'one result per item');
        LibraryAssert.AreEqual(4, Cost, 'cost = items');
        Tok.AsArray().Get(2, Tok);
        LibraryAssert.AreEqual('modify', Helper.TextField(Tok.AsObject(), 'op'), 'each result says its op');
        LibraryAssert.AreNotEqual('', Helper.TextField(Tok.AsObject(), '@etag'), 'a modify result carries the new etag');
    end;

    [Test]
    procedure FailingItemWritesNothingAndNamesTheItem()
    var
        Customer: Record Customer;
        Items: JsonArray;
        Values, Result: JsonObject;
        Status: Integer;
    begin
        Prepare();
        DeleteCustomers('BT-3');
        Items.Add(InsertCustomer('BT-3', 'Batch Three'));
        Values.Add('NoSuchField', 'x');
        Items.Add(Item('modify', Database::Customer, FromItem(0), Values));
        Helper.CommitFixtures();
        Result := Dispatcher.RunEx('batch', Helper.EnvelopeWithKey(BatchData(Items, false), Helper.NewIdemKey()), '', Status);

        LibraryAssert.AreEqual(400, Status, 'the failing item''s own status');
        LibraryAssert.AreEqual(1, IntField(Result, 'item'), 'the problem names the failing item');
        LibraryAssert.IsTrue(StrPos(Helper.TextField(Result, 'detail'), 'items[1] (modify, table 18)') = 1,
            'the detail starts with the item: ' + Helper.TextField(Result, 'detail'));
        LibraryAssert.IsFalse(Customer.Get('BT-3'), 'the earlier insert was rolled back with the batch');
    end;

    [Test]
    procedure PreviewWritesNothingAndAnswersPerItem()
    var
        Customer: Record Customer;
        Items: JsonArray;
        Response, Fail, Value: JsonObject;
        Tok: JsonToken;
        Cost: Integer;
    begin
        Prepare();
        DeleteCustomers('BT-4');
        Items.Add(InsertCustomer('BT-4', 'Batch Four'));
        Items.Add(ModifyName(FromItem(0), 'Batch Four Renamed'));
        Helper.CommitFixtures();
        LibraryAssert.IsTrue(OpBatch.Run(BatchData(Items, true), Response, Fail, Cost), 'preview: ' + Helper.DetailOf(Fail));

        LibraryAssert.IsFalse(Customer.Get('BT-4'), 'a preview writes nothing');
        Value := Helper.ValueObject(Response);
        Value.Get('preview', Tok);
        LibraryAssert.IsTrue(Tok.AsValue().AsBoolean(), 'the answer says it was a preview');
        Value.Get('items', Tok);
        LibraryAssert.AreEqual(2, Tok.AsArray().Count(), 'one result per item');
    end;

    [Test]
    procedure PreviewReportsTheFailingItem()
    var
        Customer: Record Customer;
        Items: JsonArray;
        Values, Response, Fail: JsonObject;
        Cost: Integer;
    begin
        Prepare();
        DeleteCustomers('BT-5');
        Items.Add(InsertCustomer('BT-5', 'Batch Five'));
        Values.Add('NoSuchField', 'x');
        Items.Add(Item('modify', Database::Customer, FromItem(0), Values));
        Helper.CommitFixtures();
        LibraryAssert.IsFalse(OpBatch.Run(BatchData(Items, true), Response, Fail, Cost), 'the preview fails');
        LibraryAssert.AreEqual(1, IntField(Fail, 'item'), 'and names the item');
        LibraryAssert.IsFalse(Customer.Get('BT-5'), 'nothing was written');
    end;

    [Test]
    procedure ReferenceCarriesAnEarlierItemsField()
    var
        ShipTo: Record "Ship-to Address";
        Items: JsonArray;
        Values, Response, Fail: JsonObject;
        Cost: Integer;
    begin
        Prepare();
        DeleteCustomers('BT-6');
        if ShipTo.Get('BT-6', 'MAIN') then ShipTo.Delete();
        Items.Add(InsertCustomer('BT-6', 'Batch Six'));
        Values.Add('Customer No.', FieldFrom(0, 'No.'));
        Values.Add('Code', 'MAIN');
        Values.Add('Name', FieldFrom(0, 'Name'));
        Items.Add(Item('insert', Database::"Ship-to Address", '', Values));
        LibraryAssert.IsTrue(OpBatch.Run(BatchData(Items, false), Response, Fail, Cost), 'batch: ' + Helper.DetailOf(Fail));
        LibraryAssert.IsTrue(ShipTo.Get('BT-6', 'MAIN'), 'the line carries the header''s number');
        LibraryAssert.AreEqual('Batch Six', ShipTo.Name, 'and any other field of it');
    end;

    [Test]
    procedure ReferenceToAHiddenFieldIsRefused()
    var
        Items: JsonArray;
        Values, Response, Fail: JsonObject;
        Cost: Integer;
    begin
        // A value the reader could not see must not be copied into another field it can.
        Prepare();
        DeleteCustomers('BT-7');
        Helper.SetFieldPolicyMode("Bcmag Field Policy Mode"::Explicit);
        Helper.SetFieldAccess(Database::Customer, 2, "Bcmag Read Access"::Clear, '', true);
        Helper.SetFieldAccess(Database::Customer, 9, "Bcmag Read Access"::Hidden, '', true);
        Items.Add(InsertCustomer('BT-7', 'Batch Seven'));
        Values.Add('Name', FieldFrom(0, 'Phone No.'));
        Items.Add(Item('modify', Database::Customer, FromItem(0), Values));
        Helper.CommitFixtures();
        LibraryAssert.IsFalse(OpBatch.Run(BatchData(Items, true), Response, Fail, Cost), 'refused');
        LibraryAssert.AreEqual(403, Helper.StatusOf(Fail), '403');
        LibraryAssert.IsTrue(StrPos(Helper.TypeOf(Fail), 'field-restricted') > 0, 'field-restricted: ' + Helper.TypeOf(Fail));
        LibraryAssert.AreEqual(1, IntField(Fail, 'item'), 'the item with the reference');
    end;

    [Test]
    procedure ReferenceToALaterItemIsRefused()
    var
        Items: JsonArray;
        Values, Response, Fail: JsonObject;
        Cost: Integer;
    begin
        Prepare();
        DeleteCustomers('BT-8|BT-9');
        Values.Add('No.', 'BT-8');
        Values.Add('Name', FieldFrom(1, 'Name'));
        Items.Add(Item('insert', Database::Customer, '', Values));
        Items.Add(InsertCustomer('BT-9', 'Batch Nine'));
        Helper.CommitFixtures();
        LibraryAssert.IsFalse(OpBatch.Run(BatchData(Items, true), Response, Fail, Cost), 'refused');
        LibraryAssert.IsTrue(StrPos(Helper.TypeOf(Fail), 'invalid-reference') > 0, 'invalid-reference: ' + Helper.TypeOf(Fail));
        LibraryAssert.AreEqual(0, IntField(Fail, 'item'), 'the item with the reference');
    end;

    [Test]
    procedure TooManyItemsAreRefused()
    var
        Items: JsonArray;
        Response, Fail: JsonObject;
        i, Cost: Integer;
    begin
        Prepare();
        for i := 1 to 101 do
            Items.Add(InsertCustomer(CopyStr('BX-' + Format(i), 1, 20), 'Too Many'));
        LibraryAssert.IsFalse(OpBatch.Run(BatchData(Items, false), Response, Fail, Cost), 'refused');
        LibraryAssert.AreEqual(400, Helper.StatusOf(Fail), '400');
        LibraryAssert.IsTrue(StrPos(Helper.TypeOf(Fail), 'batch-too-large') > 0, 'batch-too-large: ' + Helper.TypeOf(Fail));
    end;

    [Test]
    procedure EmptyBatchIsRefused()
    var
        Items: JsonArray;
        Response, Fail: JsonObject;
        Cost: Integer;
    begin
        Prepare();
        LibraryAssert.IsFalse(OpBatch.Run(BatchData(Items, false), Response, Fail, Cost), 'refused');
        LibraryAssert.AreEqual(400, Helper.StatusOf(Fail), '400');
    end;

    [Test]
    procedure UnknownOpIsRefusedWithTheItem()
    var
        Items: JsonArray;
        Values, Response, Fail: JsonObject;
        Cost: Integer;
    begin
        Prepare();
        Values.Add('Name', 'x');
        Items.Add(Item('upsert', Database::Customer, '', Values));
        LibraryAssert.IsFalse(OpBatch.Run(BatchData(Items, false), Response, Fail, Cost), 'refused');
        LibraryAssert.AreEqual(0, IntField(Fail, 'item'), 'item 0');
        LibraryAssert.IsTrue(StrPos(Helper.DetailOf(Fail), 'insert, modify or delete') > 0, 'says the choices: ' + Helper.DetailOf(Fail));
    end;

    [Test]
    procedure ReadOnlyModeAllowsOnlyAPreview()
    var
        Customer: Record Customer;
        Items: JsonArray;
        Result: JsonObject;
        Status: Integer;
    begin
        Prepare();
        DeleteCustomers('BT-10');
        Items.Add(InsertCustomer('BT-10', 'Batch Ten'));
        Helper.SetReadOnlyMode(true);
        Helper.CommitFixtures();
        Result := Dispatcher.RunEx('batch', Helper.EnvelopeWithKey(BatchData(Items, false), Helper.NewIdemKey()), '', Status);
        LibraryAssert.AreEqual(403, Status, 'a real batch is a write');
        Result := Dispatcher.RunEx('batch', Helper.EnvelopeWithKey(BatchData(Items, true), Helper.NewIdemKey()), '', Status);
        LibraryAssert.AreEqual(200, Status, 'a preview writes nothing: ' + Helper.TextField(Result, 'detail'));
        LibraryAssert.IsFalse(Customer.Get('BT-10'), 'nothing was written');
        Helper.SetReadOnlyMode(false);
        Helper.CommitFixtures();
    end;

    [Test]
    procedure EachItemIsInTheChangeHistory()
    var
        Entry: Record "Bcmag Change Entry";
        Setup: Record "Bcmag Setup";
        Items: JsonArray;
        Response, Fail: JsonObject;
        Before, Cost: Integer;
    begin
        Prepare();
        Setup.GetSingleton();
        Setup."Record Changes" := Setup."Record Changes"::OldAndNewValues;
        Setup.Modify();
        DeleteCustomers('BT-11|BT-12');
        Before := Entry.Count();
        Items.Add(InsertCustomer('BT-11', 'Batch Eleven'));
        Items.Add(InsertCustomer('BT-12', 'Batch Twelve'));
        LibraryAssert.IsTrue(OpBatch.Run(BatchData(Items, false), Response, Fail, Cost), 'batch: ' + Helper.DetailOf(Fail));
        LibraryAssert.AreEqual(Before + 2, Entry.Count(), 'one history entry per item');
    end;

    // ---- helpers -------------------------------------------------------------------------------------

    local procedure Prepare()
    begin
        Helper.ConfigureOpenMode();
        Helper.EnsureManualCustomerNos();
    end;

    local procedure DeleteCustomers(Filter: Text)
    var
        Customer: Record Customer;
    begin
        Customer.SetFilter("No.", Filter);
        if not Customer.IsEmpty() then
            Customer.DeleteAll();
    end;

    local procedure BatchData(Items: JsonArray; Preview: Boolean) Data: JsonObject
    begin
        Data.Add('items', Items);
        if Preview then
            Data.Add('preview', true);
    end;

    local procedure InsertCustomer(No: Text; Name: Text) Result: JsonObject
    var
        Values: JsonObject;
    begin
        Values.Add('No.', No);
        Values.Add('Name', Name);
        Result := Item('insert', Database::Customer, '', Values);
        Result.Add('init', false);
    end;

    local procedure ModifyName(RecordRef: JsonObject; Name: Text) Result: JsonObject
    var
        Values: JsonObject;
    begin
        Values.Add('Name', Name);
        Result := Item('modify', Database::Customer, RecordRef, Values);
    end;

    local procedure DeleteItem(TableId: Integer; RecordRef: JsonObject) Result: JsonObject
    var
        NoValues: JsonObject;
    begin
        Result := Item('delete', TableId, RecordRef, NoValues);
    end;

    local procedure Item(Op: Text; TableId: Integer; RecordRef: Variant; Values: JsonObject) Result: JsonObject
    var
        RefObject: JsonObject;
        Keys: List of [Text];
    begin
        Result.Add('op', Op);
        Result.Add('tableId', TableId);
        if RecordRef.IsJsonObject() then begin
            RefObject := RecordRef;
            Result.Add('recordId', RefObject);
        end else
            if Format(RecordRef) <> '' then
                Result.Add('recordId', Format(RecordRef));
        Keys := Values.Keys();
        if Keys.Count() > 0 then
            Result.Add('values', Values);
    end;

    local procedure FromItem(Index: Integer) Ref: JsonObject
    begin
        Ref.Add('fromItem', Index);
    end;

    local procedure FieldFrom(Index: Integer; FieldName: Text) Ref: JsonObject
    begin
        Ref.Add('fromItem', Index);
        Ref.Add('field', FieldName);
    end;

    local procedure IntField(Obj: JsonObject; Name: Text): Integer
    var
        Tok: JsonToken;
    begin
        if not Obj.Get(Name, Tok) then
            exit(-1);
        exit(Tok.AsValue().AsInteger());
    end;
}
