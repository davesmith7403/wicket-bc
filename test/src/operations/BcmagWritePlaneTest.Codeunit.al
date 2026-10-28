codeunit 94316 "Bcmag Write Plane Test"
{
    Subtype = Test;
    TestPermissions = Disabled;

    // Full write round-trip through the real OpInsert/OpModify/OpDelete handlers:
    // create -> read back @recordId/@etag -> modify (with @etag) -> delete, plus a 412 on a
    // stale ETag (optimistic concurrency via data.etag).

    var
        OpInsert: Codeunit "Bcmag Op Insert";
        OpModify: Codeunit "Bcmag Op Modify";
        OpDelete: Codeunit "Bcmag Op Delete";
        Helper: Codeunit "Bcmag Test Helper";
        LibraryAssert: Codeunit "Library Assert";

    local procedure Prepare()
    begin
        Helper.ConfigureAllowlistedMode();
        Helper.EnsureManualCustomerNos();
        Helper.ExposeTable(Database::Customer, true, true, true, true);
    end;

    [Test]
    procedure InsertModifyDeleteRoundTrip()
    var
        Customer: Record Customer;
        InsData, ModData, DelData, Response, Value, Fail: JsonObject;
        InsValues, ModValues: JsonObject;
        Cost: Integer;
        RecordId, Etag, NewEtag: Text;
    begin
        Prepare();
        if Customer.Get('W-1') then Customer.Delete();

        // --- insert ---
        InsValues.Add('No.', 'W-1');
        InsValues.Add('Name', 'Write Plane Co');
        InsData.Add('tableId', Database::Customer);
        InsData.Add('values', InsValues);
        InsData.Add('init', false);
        LibraryAssert.IsTrue(OpInsert.Run(InsData, Response, Fail, Cost), StrSubstNo('insert should succeed: %1', Helper.DetailOf(Fail)));
        Value := Helper.ValueObject(Response);
        RecordId := Helper.TextField(Value, 'recordId');
        Etag := Helper.TextField(Value, '@etag');
        LibraryAssert.AreNotEqual('', RecordId, 'insert must return a recordId');
        LibraryAssert.AreNotEqual('', Etag, 'Customer has system fields so @etag is expected');
        LibraryAssert.IsTrue(Customer.Get('W-1'), 'row should be persisted');

        // --- modify with the current etag ---
        Clear(Response);
        ModValues.Add('Name', 'Write Plane Renamed');
        ModData.Add('tableId', Database::Customer);
        ModData.Add('recordId', RecordId);
        ModData.Add('etag', Etag);
        ModData.Add('values', ModValues);
        LibraryAssert.IsTrue(OpModify.Run(ModData, Response, Fail, Cost), StrSubstNo('modify should succeed: %1', Helper.DetailOf(Fail)));
        Value := Helper.ValueObject(Response);
        NewEtag := Helper.TextField(Value, '@etag');
        Customer.Get('W-1');
        LibraryAssert.AreEqual('Write Plane Renamed', Customer.Name, 'name should be updated');

        // --- delete with the refreshed etag ---
        Clear(Response);
        DelData.Add('tableId', Database::Customer);
        DelData.Add('recordId', RecordId);
        if NewEtag <> '' then DelData.Add('etag', NewEtag);
        LibraryAssert.IsTrue(OpDelete.Run(DelData, Response, Fail, Cost), StrSubstNo('delete should succeed: %1', Helper.DetailOf(Fail)));
        Value := Helper.ValueObject(Response);
        LibraryAssert.IsFalse(Customer.Get('W-1'), 'row should be gone after delete');

        Helper.UnexposeTable(Database::Customer);
    end;

    [Test]
    procedure ModifyWithStaleEtagReturns412()
    var
        Customer: Record Customer;
        InsData, ModData, Response, Value, Fail: JsonObject;
        InsValues, ModValues: JsonObject;
        Cost: Integer;
        RecordId: Text;
    begin
        Prepare();
        if Customer.Get('W-2') then Customer.Delete();

        InsValues.Add('No.', 'W-2');
        InsValues.Add('Name', 'Stale Etag Co');
        InsData.Add('tableId', Database::Customer);
        InsData.Add('values', InsValues);
        InsData.Add('init', false);
        LibraryAssert.IsTrue(OpInsert.Run(InsData, Response, Fail, Cost), StrSubstNo('insert should succeed: %1', Helper.DetailOf(Fail)));
        Value := Helper.ValueObject(Response);
        RecordId := Helper.TextField(Value, 'recordId');

        // Supply a deliberately wrong (stale) etag — concurrency check must fail with 412.
        Clear(Response);
        ModValues.Add('Name', 'Should Not Apply');
        ModData.Add('tableId', Database::Customer);
        ModData.Add('recordId', RecordId);
        ModData.Add('etag', 'c3RhbGUtZXRhZw'); // arbitrary base64, will not match current
        ModData.Add('values', ModValues);
        LibraryAssert.IsFalse(OpModify.Run(ModData, Response, Fail, Cost), 'stale etag must be rejected');
        LibraryAssert.AreEqual(412, Helper.StatusOf(Fail), 'expected 412 precondition-failed');

        Customer.Get('W-2');
        LibraryAssert.AreEqual('Stale Etag Co', Customer.Name, 'name must be unchanged after a rejected modify');

        if Customer.Get('W-2') then Customer.Delete();
        Helper.UnexposeTable(Database::Customer);
    end;

    [Test]
    procedure ModifyRefusesTheMaskedRenderingOfTheStoredValue()
    var
        Customer: Record Customer;
        Masker: Codeunit "Bcmag Field Masker";
        Codec: Codeunit "Bcmag Record Id Codec";
        ModData, InsData, Response, Fail: JsonObject;
        EchoValues, NewValues, InsValues: JsonObject;
        Cost: Integer;
        Echo: Text;
    begin
        // A caller who reads Name Masked sees its mask rendering. Writing that rendering back (a client
        // round-tripping the record it read) would replace the real name with the mask for good: refused
        // 400 masked-value, and the stored name is untouched. A genuinely new name is written normally,
        // and an insert has no stored value to compare against.
        Prepare();
        Helper.ClearUserExceptions();
        Helper.SetFieldPolicyMode("Bcmag Field Policy Mode"::ByClassification);
        Helper.UpsertMaskProfile('PARTIAL', "Bcmag Mask Kind"::KeepLast, 0, 2, 4, false);
        Helper.SetFieldAccess(Database::Customer, Customer.FieldNo(Name), "Bcmag Read Access"::Masked, 'PARTIAL', true);
        if Customer.Get('W-3') then Customer.Delete();
        if Customer.Get('W-4') then Customer.Delete();
        Customer.Init();
        Customer."No." := 'W-3';
        Customer.Name := 'Masked Echo Co';
        Customer.Insert();
        Echo := Masker.MaskText(Customer.Name, 'PARTIAL');
        LibraryAssert.AreNotEqual(Customer.Name, Echo, 'the rendering differs from the stored name');

        // --- echoing the mask back ---
        EchoValues.Add('Name', Echo);
        ModData.Add('tableId', Database::Customer);
        ModData.Add('recordId', Codec.Encode(Customer.RecordId));
        ModData.Add('values', EchoValues);
        LibraryAssert.IsFalse(OpModify.Run(ModData, Response, Fail, Cost), 'writing the mask rendering back must be refused');
        LibraryAssert.AreEqual(400, Helper.StatusOf(Fail), 'expected 400');
        LibraryAssert.IsTrue(StrPos(Helper.TypeOf(Fail), 'masked-value') > 0, 'expected the masked-value problem type, got ' + Helper.TypeOf(Fail));
        LibraryAssert.AreEqual('the value is the masked rendering of the current value; send the real value or omit the field', Helper.DetailOf(Fail), 'detail');
        Customer.Get('W-3');
        LibraryAssert.AreEqual('Masked Echo Co', Customer.Name, 'the stored name must be unchanged');

        // --- a genuinely new value ---
        Clear(ModData);
        Clear(Response);
        Clear(Fail);
        NewValues.Add('Name', 'Masked Echo Renamed');
        ModData.Add('tableId', Database::Customer);
        ModData.Add('recordId', Codec.Encode(Customer.RecordId));
        ModData.Add('values', NewValues);
        LibraryAssert.IsTrue(OpModify.Run(ModData, Response, Fail, Cost), StrSubstNo('a new name must be written: %1', Helper.DetailOf(Fail)));
        Customer.Get('W-3');
        LibraryAssert.AreEqual('Masked Echo Renamed', Customer.Name, 'the new name is stored');

        // --- insert: no stored value, nothing to compare ---
        Clear(Response);
        Clear(Fail);
        InsValues.Add('No.', 'W-4');
        InsValues.Add('Name', Echo);
        InsData.Add('tableId', Database::Customer);
        InsData.Add('values', InsValues);
        InsData.Add('init', false);
        LibraryAssert.IsTrue(OpInsert.Run(InsData, Response, Fail, Cost), StrSubstNo('an insert is not judged against a mask: %1', Helper.DetailOf(Fail)));

        if Customer.Get('W-3') then Customer.Delete();
        if Customer.Get('W-4') then Customer.Delete();
        Helper.UnexposeField(Database::Customer, Customer.FieldNo(Name));
        Helper.SetFieldPolicyMode("Bcmag Field Policy Mode"::AllFields);
        Helper.UnexposeTable(Database::Customer);
    end;

    [Test]
    procedure ModifyRefusesAMaskEchoEvenWhenTheWriterHoldsALift()
    var
        Customer: Record Customer;
        Masker: Codeunit "Bcmag Field Masker";
        Codec: Codeunit "Bcmag Record Id Codec";
        RunnerCtx: Codeunit "Bcmag Op Runner Context";
        Policy: Codeunit "Bcmag Field Policy";
        ModData, NoUnmask, Response, Fail: JsonObject;
        EchoValues, NewValues: JsonObject;
        Scope: Option Classification,Field;
        ProfileCode: Code[20];
        Cost: Integer;
        Echo: Text;
    begin
        // The caller's baseline masks Name, and a user exception lifts it to Clear. Reading with
        // "unmask": false served the PARTIAL rendering; the later write carries no opt-out, so under the
        // write's own verdict Name is Clear. The echo must still be recognised — against every rendering
        // the caller could have been served — or the mask would overwrite the real name for good.
        Prepare();
        Helper.ClearUserExceptions();
        Helper.SetFieldPolicyMode("Bcmag Field Policy Mode"::ByClassification);
        Helper.UpsertMaskProfile('PARTIAL', "Bcmag Mask Kind"::KeepLast, 0, 2, 4, false);
        Helper.SetFieldAccess(Database::Customer, Customer.FieldNo(Name), "Bcmag Read Access"::Masked, 'PARTIAL', true);
        Helper.AddUserException(Scope::Field, "Bcmag Data Class"::CustomerContent, Database::Customer, Customer.FieldNo(Name), "Bcmag Read Access"::Clear, '', 0DT);
        if Customer.Get('W-5') then Customer.Delete();
        Customer.Init();
        Customer."No." := 'W-5';
        Customer.Name := 'Lifted Echo Co';
        Customer.Insert();
        Echo := Masker.MaskText(Customer.Name, 'PARTIAL');
        LibraryAssert.AreNotEqual(Customer.Name, Echo, 'the rendering differs from the stored name');

        // The write request carries no "unmask" member: under its own verdict Name reads Clear.
        RunnerCtx.SetRequest('modify', NoUnmask);
        LibraryAssert.IsTrue(Policy.ReadVerdict(Database::Customer, Customer.FieldNo(Name), ProfileCode) = "Bcmag Read Access"::Clear,
            'precondition: the lift makes Name Clear for a request without the opt-out');

        // --- echoing the opt-out rendering back ---
        EchoValues.Add('Name', Echo);
        ModData.Add('tableId', Database::Customer);
        ModData.Add('recordId', Codec.Encode(Customer.RecordId));
        ModData.Add('values', EchoValues);
        LibraryAssert.IsFalse(OpModify.Run(ModData, Response, Fail, Cost), 'writing the mask rendering back must be refused');
        LibraryAssert.AreEqual(400, Helper.StatusOf(Fail), 'expected 400');
        LibraryAssert.IsTrue(StrPos(Helper.TypeOf(Fail), 'masked-value') > 0, 'expected the masked-value problem type, got ' + Helper.TypeOf(Fail));
        Customer.Get('W-5');
        LibraryAssert.AreEqual('Lifted Echo Co', Customer.Name, 'the stored name must be unchanged');

        // --- a genuinely new value ---
        Clear(ModData);
        Clear(Response);
        Clear(Fail);
        NewValues.Add('Name', 'Lifted Echo Renamed');
        ModData.Add('tableId', Database::Customer);
        ModData.Add('recordId', Codec.Encode(Customer.RecordId));
        ModData.Add('values', NewValues);
        LibraryAssert.IsTrue(OpModify.Run(ModData, Response, Fail, Cost), StrSubstNo('a new name must be written: %1', Helper.DetailOf(Fail)));
        Customer.Get('W-5');
        LibraryAssert.AreEqual('Lifted Echo Renamed', Customer.Name, 'the new name is stored');

        if Customer.Get('W-5') then Customer.Delete();
        Helper.ClearUserExceptions();
        Helper.UnexposeField(Database::Customer, Customer.FieldNo(Name));
        Helper.SetFieldPolicyMode("Bcmag Field Policy Mode"::AllFields);
        Helper.UnexposeTable(Database::Customer);
    end;

    [Test]
    procedure ModifyRefusesALowercasedMaskEchoOnACodeField()
    var
        Customer: Record Customer;
        Codec: Codeunit "Bcmag Record Id Codec";
        ModData, Response, Fail: JsonObject;
        EchoValues: JsonObject;
        Cost: Integer;
    begin
        // "Search Name" is a Code field: stored 'XYZWAB' renders '****AB'. A client that lowercases the
        // rendering sends '****ab'; Code assignment would uppercase it to '****AB' and overwrite the real
        // value with the mask. The echo guard must compare case-insensitively on Code fields.
        Prepare();
        Helper.SetFieldPolicyMode("Bcmag Field Policy Mode"::ByClassification);
        Helper.UpsertMaskProfile('T-KL2CODE', "Bcmag Mask Kind"::KeepLast, 0, 2, 4, false);
        Helper.SetFieldAccess(Database::Customer, Customer.FieldNo("Search Name"), "Bcmag Read Access"::Masked, 'T-KL2CODE', true);
        if Customer.Get('W-6') then Customer.Delete();
        Customer.Init();
        Customer."No." := 'W-6';
        Customer."Search Name" := 'XYZWAB';
        Customer.Insert();

        EchoValues.Add('Search Name', '****ab');
        ModData.Add('tableId', Database::Customer);
        ModData.Add('recordId', Codec.Encode(Customer.RecordId));
        ModData.Add('values', EchoValues);
        LibraryAssert.IsFalse(OpModify.Run(ModData, Response, Fail, Cost), 'a lowercased mask echo on a Code field must be refused');
        LibraryAssert.AreEqual(400, Helper.StatusOf(Fail), 'expected 400');
        LibraryAssert.IsTrue(StrPos(Helper.TypeOf(Fail), 'masked-value') > 0, 'expected the masked-value problem type, got ' + Helper.TypeOf(Fail));
        Customer.Get('W-6');
        LibraryAssert.AreEqual('XYZWAB', Customer."Search Name", 'the stored Search Name must be unchanged');

        if Customer.Get('W-6') then Customer.Delete();
        Helper.UnexposeField(Database::Customer, Customer.FieldNo("Search Name"));
        Helper.SetFieldPolicyMode("Bcmag Field Policy Mode"::AllFields);
        Helper.UnexposeTable(Database::Customer);
    end;
}
