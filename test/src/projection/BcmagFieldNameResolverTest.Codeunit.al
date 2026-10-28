codeunit 94304 "Bcmag Field Name Resolver Test"
{
    Subtype = Test;
    TestPermissions = Disabled;

    var
        Resolver: Codeunit "Bcmag Field Name Resolver";
        LibraryAssert: Codeunit "Library Assert";

    [Test]
    procedure ResolvesCustomerNoToOne()
    var
        FieldNo: Integer;
        Suggestion: Text;
    begin
        LibraryAssert.IsTrue(Resolver.ResolveByName(Database::Customer, 'No.', FieldNo, Suggestion), 'should resolve');
        LibraryAssert.AreEqual(1, FieldNo, 'field number');
    end;

    [Test]
    procedure SuggestsClosestOnTypo()
    var
        FieldNo: Integer;
        Suggestion: Text;
    begin
        LibraryAssert.IsFalse(Resolver.ResolveByName(Database::Customer, 'Nme', FieldNo, Suggestion), 'should miss');
        LibraryAssert.AreEqual('Name', Suggestion, 'should suggest "Name"');
    end;

    [Test]
    procedure NoSuggestionWhenDistanceTooHigh()
    var
        FieldNo: Integer;
        Suggestion: Text;
    begin
        LibraryAssert.IsFalse(Resolver.ResolveByName(Database::Customer, 'CompletelyUnrelatedFieldName', FieldNo, Suggestion), 'should miss');
        LibraryAssert.AreEqual('', Suggestion, 'no suggestion');
    end;
}
