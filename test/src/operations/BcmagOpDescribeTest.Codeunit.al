codeunit 94311 "Bcmag Op Describe Test"
{
    Subtype = Test;
    TestPermissions = Disabled;

    var
        Op: Codeunit "Bcmag Op Describe";
        Helper: Codeunit "Bcmag Test Helper";
        LibraryAssert: Codeunit "Library Assert";

    [Test]
    procedure DescribeCustomerReturnsFieldsAndSchema()
    var
        Data, Response, Value: JsonObject;
        Tok: JsonToken;
        Fields: JsonArray;
        Cost: Integer;
        Fail: JsonObject;
    begin
        Helper.ConfigureAllowlistedMode();
        Helper.ExposeTable(Database::Customer, true, false, false, false);
        Data.Add('kind', 'table');
        Data.Add('tableId', Database::Customer);
        LibraryAssert.IsTrue(Op.Run(Data, Response, Fail, Cost), 'describe should succeed');
        LibraryAssert.IsTrue(Response.Get('value', Tok), 'value missing');
        Value := Tok.AsObject();

        LibraryAssert.IsTrue(Value.Get('fields', Tok), 'fields missing');
        Fields := Tok.AsArray();
        LibraryAssert.IsTrue(Fields.Count() > 5, 'expected several fields');
        LibraryAssert.IsTrue(Value.Get('keys', Tok), 'keys missing');
        LibraryAssert.IsTrue(Value.Get('primaryKey', Tok), 'primaryKey missing');
        LibraryAssert.IsTrue(Value.Get('schemaVersion', Tok), 'schemaVersion missing');
        LibraryAssert.IsTrue(Value.Get('hasSystemFields', Tok), 'hasSystemFields missing');
    end;

    [Test]
    procedure DescribeOptionFieldCarriesMembers()
    var
        Data, Response, Value, FieldObj, Member, CaptionML: JsonObject;
        Tok: JsonToken;
        Fields, Members, LangArr: JsonArray;
        Cost, i: Integer;
        Fail: JsonObject;
        FoundOption: Boolean;
    begin
        // Option/Enum fields must expose per-member {ord, name, captionML} so an agent can
        // join a query row's option {ord} to a localized label. Customer always has at least
        // one Option field (e.g. "Blocked"), so scan for one rather than hard-coding a field no.
        Helper.ConfigureAllowlistedMode();
        Helper.ExposeTable(Database::Customer, true, false, false, false);
        Data.Add('kind', 'table');
        Data.Add('tableId', Database::Customer);
        LangArr.Add('ENU');
        Data.Add('languages', LangArr);
        LibraryAssert.IsTrue(Op.Run(Data, Response, Fail, Cost), 'describe should succeed');
        Response.Get('value', Tok);
        Value := Tok.AsObject();
        Value.Get('fields', Tok);
        Fields := Tok.AsArray();

        for i := 0 to Fields.Count() - 1 do begin
            Fields.Get(i, Tok);
            FieldObj := Tok.AsObject();
            if FieldObj.Get('type', Tok) and (Tok.AsValue().AsText() = 'Option') then begin
                FoundOption := true;
                LibraryAssert.IsTrue(FieldObj.Get('optionMembers', Tok), 'option field must carry optionMembers');
                Members := Tok.AsArray();
                LibraryAssert.IsTrue(Members.Count() > 0, 'optionMembers must be non-empty');
                Members.Get(0, Tok);
                Member := Tok.AsObject();
                LibraryAssert.IsTrue(Member.Get('ord', Tok), 'member.ord missing');
                LibraryAssert.IsTrue(Member.Get('name', Tok), 'member.name missing');
                LibraryAssert.IsTrue(Member.Get('captionML', Tok), 'member.captionML missing');
                // Caption resolution must actually run: the requested language key must be present
                // (a silent TryReadEnumCaption failure would leave an empty object and fail here).
                CaptionML := Tok.AsObject();
                LibraryAssert.IsTrue(CaptionML.Contains('ENU'), 'member.captionML should carry the requested ENU key');
            end;
        end;
        LibraryAssert.IsTrue(FoundOption, 'Customer should expose at least one Option field');
    end;

    [Test]
    procedure DescribeFieldsCarryDataClassification()
    var
        Data, Response, Value, FieldObj: JsonObject;
        Tok, NameTok: JsonToken;
        Fields: JsonArray;
        Cost, i: Integer;
        Fail: JsonObject;
        Classification: Text;
        FoundName: Boolean;
    begin
        // Every field must expose dataClassification as an invariant identifier (never a
        // locale-dependent caption). Customer is table-level CustomerContent, so fields
        // without an explicit override — including Name — inherit that classification.
        Helper.ConfigureAllowlistedMode();
        Helper.ExposeTable(Database::Customer, true, false, false, false);
        Data.Add('kind', 'table');
        Data.Add('tableId', Database::Customer);
        LibraryAssert.IsTrue(Op.Run(Data, Response, Fail, Cost), 'describe should succeed');
        Response.Get('value', Tok);
        Value := Tok.AsObject();
        Value.Get('fields', Tok);
        Fields := Tok.AsArray();

        for i := 0 to Fields.Count() - 1 do begin
            Fields.Get(i, Tok);
            FieldObj := Tok.AsObject();
            LibraryAssert.IsTrue(FieldObj.Get('dataClassification', Tok), 'dataClassification missing on field');
            Classification := Tok.AsValue().AsText();
            LibraryAssert.IsTrue(IsKnownDataClassification(Classification),
                StrSubstNo('unexpected dataClassification "%1"', Classification));
            if FieldObj.Get('name', NameTok) and (NameTok.AsValue().AsText() = 'Name') then begin
                FoundName := true;
                LibraryAssert.AreEqual('CustomerContent', Classification, 'Customer.Name should carry CustomerContent');
            end;
        end;
        LibraryAssert.IsTrue(FoundName, 'Customer should expose a Name field');
    end;

    local procedure IsKnownDataClassification(Classification: Text): Boolean
    begin
        exit(Classification in ['CustomerContent', 'ToBeClassified', 'EndUserIdentifiableInformation',
            'AccountData', 'EndUserPseudonymousIdentifiers', 'OrganizationIdentifiableInformation', 'SystemMetadata']);
    end;

    [Test]
    procedure DescribeUnexposedTableIsDenied()
    var
        Data, Response, Fail: JsonObject;
        Cost: Integer;
    begin
        Helper.ConfigureAllowlistedMode();
        Helper.UnexposeTable(Database::Customer);
        Data.Add('kind', 'table');
        Data.Add('tableId', Database::Customer);
        LibraryAssert.IsFalse(Op.Run(Data, Response, Fail, Cost), 'unexposed table should be denied');
        LibraryAssert.AreEqual(403, Helper.StatusOf(Fail), 'expected 403');
    end;

    [Test]
    procedure DescribeEnrolledCodeunitListsProcedures()
    var
        Data, Response, Value: JsonObject;
        Tok: JsonToken;
        Procedures: JsonArray;
        Cost: Integer;
        Fail: JsonObject;
    begin
        Helper.ConfigureAllowlistedMode();
        Helper.ExposeCodeunitInvoke(94190);
        Helper.EnrolProcedure(94190, 'Ping', 94190, "Bcmag Return Shape"::json);

        Data.Add('kind', 'codeunit');
        Data.Add('codeunitId', 94190);
        LibraryAssert.IsTrue(Op.Run(Data, Response, Fail, Cost), 'describe codeunit should succeed');
        LibraryAssert.IsTrue(Response.Get('value', Tok), 'value missing');
        Value := Tok.AsObject();
        LibraryAssert.IsTrue(Value.Get('procedures', Tok), 'procedures missing');
        Procedures := Tok.AsArray();
        LibraryAssert.IsTrue(Procedures.Count() >= 1, 'expected the enrolled Ping procedure');

        Helper.RemoveProcedure(94190, 'Ping');
        Helper.UnexposeCodeunit(94190);
    end;

    [Test]
    procedure DescribeReportsMaskedAndClearAccess()
    var
        Customer: Record Customer;
        Fields: JsonArray;
        FieldObj, MaskObj: JsonObject;
        Tok: JsonToken;
    begin
        // A readable field says how it reads. Masked: access "masked", mask { profile, kind }, and
        // filterable/sortable false (a filter or sort on it would reveal the hidden value). Its type is
        // the rendering's: a Hash mask turns a Decimal into a string, a keep-last mask leaves Text as
        // Text. Clear: access "clear" and nothing else added.
        Helper.ConfigureAllowlistedMode(); // Unmask tier off: SUPER would otherwise lift the masks
        Helper.ExposeTable(Database::Customer, true, false, false, false);
        Helper.SetFieldPolicyMode("Bcmag Field Policy Mode"::ByClassification);
        Helper.UpsertMaskProfile('T-LAST2', "Bcmag Mask Kind"::KeepLast, 0, 2, 4, false);
        Helper.UpsertMaskProfile('T-HASH', "Bcmag Mask Kind"::Hash, 0, 0, 4, false);
        Helper.SetFieldAccess(Database::Customer, Customer.FieldNo(Name), "Bcmag Read Access"::Masked, 'T-LAST2', false);
        Helper.SetFieldAccess(Database::Customer, Customer.FieldNo("Credit Limit (LCY)"), "Bcmag Read Access"::Masked, 'T-HASH', false);
        // The Clear control, pinned by a row so its classification cannot change the test.
        Helper.SetFieldAccess(Database::Customer, Customer.FieldNo(Address), "Bcmag Read Access"::Clear, '', false);

        DescribeCustomerFields(Fields);

        LibraryAssert.IsTrue(FindField(Fields, 'Name', FieldObj), 'Name must be described (Masked is readable)');
        LibraryAssert.AreEqual('masked', Helper.TextField(FieldObj, 'access'), 'Name access');
        LibraryAssert.AreEqual('Text', Helper.TextField(FieldObj, 'type'), 'a keep-last mask keeps the Text type');
        LibraryAssert.IsFalse(BoolMember(FieldObj, 'filterable'), 'a masked field is not filterable');
        LibraryAssert.IsFalse(BoolMember(FieldObj, 'sortable'), 'a masked field is not sortable');
        LibraryAssert.IsTrue(BoolMember(FieldObj, 'readable'), 'a masked field is readable');
        LibraryAssert.IsTrue(FieldObj.Get('mask', Tok), 'mask missing on a masked field');
        MaskObj := Tok.AsObject();
        LibraryAssert.AreEqual('T-LAST2', Helper.TextField(MaskObj, 'profile'), 'mask.profile');
        LibraryAssert.AreEqual('keepLast', Helper.TextField(MaskObj, 'kind'), 'mask.kind');

        LibraryAssert.IsTrue(FindField(Fields, 'Credit Limit (LCY)', FieldObj), 'Credit Limit (LCY) must be described');
        LibraryAssert.AreEqual('masked', Helper.TextField(FieldObj, 'access'), 'Credit Limit access');
        LibraryAssert.AreEqual('string', Helper.TextField(FieldObj, 'type'), 'a hash mask emits a string');
        FieldObj.Get('mask', Tok);
        LibraryAssert.AreEqual('hash', Helper.TextField(Tok.AsObject(), 'kind'), 'mask.kind for a hash profile');

        LibraryAssert.IsTrue(FindField(Fields, 'Address', FieldObj), 'Address must be described');
        LibraryAssert.AreEqual('clear', Helper.TextField(FieldObj, 'access'), 'a Clear field says so');
        LibraryAssert.IsFalse(FieldObj.Contains('mask'), 'a Clear field carries no mask');
        LibraryAssert.IsFalse(FieldObj.Contains('filterable'), 'a Clear field keeps its v1.1 shape');
        LibraryAssert.IsFalse(FieldObj.Contains('sortable'), 'a Clear field keeps its v1.1 shape');

        Helper.UnexposeField(Database::Customer, Customer.FieldNo(Name));
        Helper.UnexposeField(Database::Customer, Customer.FieldNo("Credit Limit (LCY)"));
        Helper.UnexposeField(Database::Customer, Customer.FieldNo(Address));
        Helper.SetFieldPolicyMode("Bcmag Field Policy Mode"::AllFields);
    end;

    [Test]
    procedure DescribeRestrictedFieldKeepsItsShape()
    var
        Customer: Record Customer;
        Fields: JsonArray;
        FieldObj: JsonObject;
    begin
        // A Hidden field advertised under "Describe Restricted Fields" is unchanged by masking:
        // readable=false and no access/mask members.
        Helper.ConfigureAllowlistedMode();
        Helper.ExposeTable(Database::Customer, true, false, false, false);
        Helper.SetFieldPolicyMode("Bcmag Field Policy Mode"::ByClassification);
        Helper.SetDescribeRestrictedFields(true);
        Helper.SetFieldAccess(Database::Customer, Customer.FieldNo(Name), "Bcmag Read Access"::Hidden, '', false);

        DescribeCustomerFields(Fields);
        LibraryAssert.IsTrue(FindField(Fields, 'Name', FieldObj), 'the restricted field is advertised when opted in');
        LibraryAssert.IsFalse(BoolMember(FieldObj, 'readable'), 'readable=false');
        LibraryAssert.IsFalse(FieldObj.Contains('access'), 'a Hidden field carries no access member');
        LibraryAssert.IsFalse(FieldObj.Contains('mask'), 'a Hidden field carries no mask member');

        Helper.SetDescribeRestrictedFields(false);
        Helper.UnexposeField(Database::Customer, Customer.FieldNo(Name));
        Helper.SetFieldPolicyMode("Bcmag Field Policy Mode"::AllFields);
    end;

    local procedure DescribeCustomerFields(var Fields: JsonArray)
    var
        Data, Response, Fail, Value: JsonObject;
        Tok: JsonToken;
        Cost: Integer;
    begin
        Data.Add('kind', 'table');
        Data.Add('tableId', Database::Customer);
        LibraryAssert.IsTrue(Op.Run(Data, Response, Fail, Cost), StrSubstNo('describe should succeed: %1', Helper.DetailOf(Fail)));
        Value := Helper.ValueObject(Response);
        LibraryAssert.IsTrue(Value.Get('fields', Tok), 'fields missing');
        Fields := Tok.AsArray();
    end;

    local procedure FindField(Fields: JsonArray; TargetName: Text; var FieldObj: JsonObject): Boolean
    var
        Tok: JsonToken;
    begin
        foreach Tok in Fields do begin
            FieldObj := Tok.AsObject();
            if Helper.TextField(FieldObj, 'name') = TargetName then
                exit(true);
        end;
        exit(false);
    end;

    local procedure BoolMember(Obj: JsonObject; Name: Text): Boolean
    var
        Tok: JsonToken;
    begin
        LibraryAssert.IsTrue(Obj.Get(Name, Tok), StrSubstNo('"%1" missing', Name));
        exit(Tok.AsValue().AsBoolean());
    end;
}
