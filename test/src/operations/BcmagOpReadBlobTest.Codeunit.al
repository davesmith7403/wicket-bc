codeunit 94313 "Bcmag Op Read Blob Test"
{
    Subtype = Test;
    TestPermissions = Disabled;

    var
        Op: Codeunit "Bcmag Op Read Blob";
        Codec: Codeunit "Bcmag Record Id Codec";
        Helper: Codeunit "Bcmag Test Helper";
        LibraryAssert: Codeunit "Library Assert";

    [Test]
    procedure ReadBlobReturnsContentTypeAndBase64()
    var
        Catalog: Record "Bcmag Procedure Catalog";
        Data, Response, Value: JsonObject;
        Tok: JsonToken;
        Token: Text;
        Cost: Integer;
        Fail: JsonObject;
    begin
        // A true BLOB field reliably returns content (empty or not), unlike an unpopulated Media.
        Helper.ConfigureOpenMode();
        if Catalog.Get(94313, 'BlobProbe') then Catalog.Delete();
        Catalog.Init();
        Catalog."Logical Codeunit Id" := 94313;
        Catalog."Procedure Name" := 'BlobProbe';
        Catalog."Wrapper Codeunit Id" := 94190;
        Catalog.SetArgsSchema('{"type":"object"}');
        Catalog.Insert();
        Token := Codec.Encode(Catalog.RecordId);

        Data.Add('tableId', Database::"Bcmag Procedure Catalog");
        Data.Add('recordId', Token);
        Data.Add('fieldNo', Catalog.FieldNo("Args Schema"));
        LibraryAssert.IsTrue(Op.Run(Data, Response, Fail, Cost), 'readBlob should succeed');
        Value := Helper.ValueObject(Response);
        LibraryAssert.IsTrue(Value.Get('contentType', Tok), 'contentType missing');
        LibraryAssert.IsTrue(Value.Get('bytesBase64', Tok), 'bytesBase64 missing');

        Catalog.Delete();
    end;

    [Test]
    procedure ReadBlobRejectsNonBinaryField()
    var
        Customer: Record Customer;
        Data, Response, Fail: JsonObject;
        Token: Text;
        Cost: Integer;
    begin
        Helper.ConfigureOpenMode();
        if not Customer.Get('B-2') then begin
            Customer.Init();
            Customer."No." := 'B-2';
            Customer.Insert();
        end;
        Token := Codec.Encode(Customer.RecordId);
        Data.Add('tableId', Database::Customer);
        Data.Add('recordId', Token);
        Data.Add('fieldNo', Customer.FieldNo(Name));
        LibraryAssert.IsFalse(Op.Run(Data, Response, Fail, Cost), 'should reject text field');
        LibraryAssert.AreEqual(400, Helper.StatusOf(Fail), 'expected 400 not-binary');
    end;

    [Test]
    procedure ReadBlobRejectsUnexposedTable()
    var
        Customer: Record Customer;
        Data, Response, Fail: JsonObject;
        Token: Text;
        Cost: Integer;
    begin
        Helper.ConfigureAllowlistedMode();
        Helper.UnexposeTable(Database::Customer);
        if not Customer.Get('B-3') then begin
            Customer.Init();
            Customer."No." := 'B-3';
            Customer.Insert();
        end;
        Token := Codec.Encode(Customer.RecordId);
        Data.Add('tableId', Database::Customer);
        Data.Add('recordId', Token);
        Data.Add('fieldNo', Customer.FieldNo(Image));
        LibraryAssert.IsFalse(Op.Run(Data, Response, Fail, Cost), 'unexposed table should be denied');
        LibraryAssert.AreEqual(403, Helper.StatusOf(Fail), 'expected 403');
    end;
}
