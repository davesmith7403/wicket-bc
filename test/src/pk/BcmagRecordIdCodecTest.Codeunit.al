codeunit 94302 "Bcmag Record Id Codec Test"
{
    Subtype = Test;
    TestPermissions = Disabled;

    var
        Codec: Codeunit "Bcmag Record Id Codec";
        LibraryAssert: Codeunit "Library Assert";

    [Test]
    procedure RoundTripCustomerNo()
    var
        Customer: Record Customer;
        RecRef: RecordRef;
        Token: Text;
        Err: Text;
    begin
        if not Customer.Get('TEST-1') then begin
            Customer."No." := 'TEST-1';
            Customer.Insert();
        end;
        Token := Codec.Encode(Customer.RecordId);
        LibraryAssert.AreNotEqual('', Token, 'empty token');
        LibraryAssert.IsTrue(Codec.Decode(Token, RecRef, Err), Err);
        LibraryAssert.AreEqual(Database::Customer, RecRef.Number, 'wrong table');
    end;

    [Test]
    procedure DecodeRejectsGarbage()
    var
        RecRef: RecordRef;
        Err: Text;
    begin
        LibraryAssert.IsFalse(Codec.Decode('not-a-token', RecRef, Err), 'should fail');
        LibraryAssert.AreNotEqual('', Err, 'expected error message');
    end;
}
