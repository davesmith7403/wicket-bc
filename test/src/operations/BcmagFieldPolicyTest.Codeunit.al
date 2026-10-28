codeunit 94321 "Bcmag Field Policy Test"
{
    Subtype = Test;
    TestPermissions = Disabled;

    // Field-level security: the per-field read/write policy must hold at every surface —
    // select/selectFieldNo, "*" expansion, filter, orderBy, describe, readBlob, and the write
    // plane — while AllFields mode stays behavior-identical to v1.1 (override rows ignored).

    var
        OpQuery: Codeunit "Bcmag Op Query";
        OpDescribe: Codeunit "Bcmag Op Describe";
        OpInsert: Codeunit "Bcmag Op Insert";
        OpModify: Codeunit "Bcmag Op Modify";
        OpReadBlob: Codeunit "Bcmag Op Read Blob";
        Codec: Codeunit "Bcmag Record Id Codec";
        Problem: Codeunit "Bcmag Problem";
        Helper: Codeunit "Bcmag Test Helper";
        LibraryAssert: Codeunit "Library Assert";

    local procedure SeedCustomers()
    var
        Customer: Record Customer;
    begin
        if not Customer.IsEmpty() then Customer.DeleteAll();
        Customer.Init(); Customer."No." := 'FP-1'; Customer.Name := 'Policy One'; Customer.Insert();
        Customer.Init(); Customer."No." := 'FP-2'; Customer.Name := 'Policy Two'; Customer.Insert();
    end;

    local procedure CustomerFieldNo(TargetName: Text): Integer
    var
        FieldRec: Record Field;
    begin
        FieldRec.SetRange(TableNo, Database::Customer);
        FieldRec.SetRange(FieldName, TargetName);
        LibraryAssert.IsTrue(FieldRec.FindFirst(), StrSubstNo('Customer must have a "%1" field', TargetName));
        exit(FieldRec."No.");
    end;

    local procedure RunQuerySelect(SelectName: Text; var Response: JsonObject; var Fail: JsonObject): Boolean
    var
        Data: JsonObject;
        Select: JsonArray;
        Cost: Integer;
    begin
        Select.Add(SelectName);
        Data.Add('tableId', Database::Customer);
        Data.Add('select', Select);
        Data.Add('top', 10);
        exit(OpQuery.Run(Data, Response, Fail, Cost));
    end;

    local procedure RunQueryDefault(var Response: JsonObject; var Fail: JsonObject): Boolean
    var
        Data: JsonObject;
        Cost: Integer;
    begin
        Data.Add('tableId', Database::Customer);
        Data.Add('top', 10);
        exit(OpQuery.Run(Data, Response, Fail, Cost));
    end;

    local procedure AssertFieldRestricted(Fail: JsonObject)
    begin
        LibraryAssert.AreEqual(403, Helper.StatusOf(Fail), 'expected 403');
        LibraryAssert.AreEqual(Problem.TypeUri('field-restricted'), Problem.ProblemTypeOf(Fail),
            'expected the field-restricted problem type');
    end;

    local procedure DescribeCustomerFields(var FieldsArr: JsonArray)
    var
        Data, Response, Fail, Value: JsonObject;
        Tok: JsonToken;
        Cost: Integer;
    begin
        Data.Add('kind', 'table');
        Data.Add('tableId', Database::Customer);
        LibraryAssert.IsTrue(OpDescribe.Run(Data, Response, Fail, Cost), 'describe should succeed');
        Value := Helper.ValueObject(Response);
        LibraryAssert.IsTrue(Value.Get('fields', Tok), 'fields missing');
        FieldsArr := Tok.AsArray();
    end;

    local procedure FindFieldObj(FieldsArr: JsonArray; TargetName: Text; var FieldObj: JsonObject): Boolean
    var
        Tok, NameTok: JsonToken;
        i: Integer;
    begin
        for i := 0 to FieldsArr.Count() - 1 do begin
            FieldsArr.Get(i, Tok);
            FieldObj := Tok.AsObject();
            if FieldObj.Get('name', NameTok) then
                if NameTok.AsValue().AsText() = TargetName then
                    exit(true);
        end;
        exit(false);
    end;

    local procedure BoolOf(Obj: JsonObject; Name: Text): Boolean
    var
        Tok: JsonToken;
    begin
        LibraryAssert.IsTrue(Obj.Get(Name, Tok), StrSubstNo('"%1" missing', Name));
        exit(Tok.AsValue().AsBoolean());
    end;

    [Test]
    procedure AllFieldsModeIgnoresDenyRow()
    var
        Response, Fail, Row: JsonObject;
        Value: JsonArray;
        Tok: JsonToken;
        Data: JsonObject;
        Select: JsonArray;
        Cost: Integer;
    begin
        // Back-compat proof: in AllFields mode an explicit deny row has no effect anywhere —
        // select succeeds and "*" still expands to the denied field.
        Helper.ConfigureOpenMode(); // pins Field Policy Mode = AllFields
        SeedCustomers();
        Helper.ExposeField(Database::Customer, CustomerFieldNo('Name'), false, false);

        LibraryAssert.IsTrue(RunQuerySelect('Name', Response, Fail), 'AllFields must ignore the deny row');

        Clear(Response);
        Select.Add('*');
        Data.Add('tableId', Database::Customer);
        Data.Add('select', Select);
        Data.Add('top', 1);
        LibraryAssert.IsTrue(OpQuery.Run(Data, Response, Fail, Cost), 'star select should succeed');
        Value := Helper.ValueArray(Response);
        Value.Get(0, Tok);
        Row := Tok.AsObject();
        LibraryAssert.IsTrue(Row.Get('Name', Tok), 'AllFields "*" must still include the denied field');

        Helper.UnexposeField(Database::Customer, CustomerFieldNo('Name'));
    end;

    [Test]
    procedure DenyRowBlocksSelectByName()
    var
        Response, Fail: JsonObject;
    begin
        Helper.ConfigureOpenMode();
        SeedCustomers();
        Helper.SetFieldPolicyMode(Enum::"Bcmag Field Policy Mode"::ByClassification);
        Helper.ExposeField(Database::Customer, CustomerFieldNo('Name'), false, false);

        LibraryAssert.IsFalse(RunQuerySelect('Name', Response, Fail), 'denied field must not be selectable');
        AssertFieldRestricted(Fail);

        // The default PK projection stays available — PK fields bypass the policy.
        Clear(Response);
        LibraryAssert.IsTrue(RunQueryDefault(Response, Fail), 'default PK select must still work');

        Helper.UnexposeField(Database::Customer, CustomerFieldNo('Name'));
    end;

    [Test]
    procedure DenyRowBlocksSelectByFieldNo()
    var
        Data, Response, Fail: JsonObject;
        SelNo: JsonArray;
        Cost: Integer;
    begin
        // The numeric path must be as closed as the name path.
        Helper.ConfigureOpenMode();
        SeedCustomers();
        Helper.SetFieldPolicyMode(Enum::"Bcmag Field Policy Mode"::ByClassification);
        Helper.ExposeField(Database::Customer, CustomerFieldNo('Name'), false, false);

        SelNo.Add(CustomerFieldNo('Name'));
        Data.Add('tableId', Database::Customer);
        Data.Add('selectFieldNo', SelNo);
        LibraryAssert.IsFalse(OpQuery.Run(Data, Response, Fail, Cost), 'denied field number must not be selectable');
        AssertFieldRestricted(Fail);

        Helper.UnexposeField(Database::Customer, CustomerFieldNo('Name'));
    end;

    [Test]
    procedure StarSelectSilentlyExcludesDeniedField()
    var
        Data, Response, Fail, Row: JsonObject;
        Select, Value: JsonArray;
        Tok: JsonToken;
        Cost: Integer;
    begin
        Helper.ConfigureOpenMode();
        SeedCustomers();
        Helper.SetFieldPolicyMode(Enum::"Bcmag Field Policy Mode"::ByClassification);
        Helper.ExposeField(Database::Customer, CustomerFieldNo('Name'), false, false);

        Select.Add('*');
        Data.Add('tableId', Database::Customer);
        Data.Add('select', Select);
        Data.Add('top', 1);
        LibraryAssert.IsTrue(OpQuery.Run(Data, Response, Fail, Cost), '"*" must succeed and narrow silently');
        Value := Helper.ValueArray(Response);
        LibraryAssert.IsTrue(Value.Count() >= 1, 'expected at least 1 row');
        Value.Get(0, Tok);
        Row := Tok.AsObject();
        LibraryAssert.IsFalse(Row.Get('Name', Tok), 'denied field must be excluded from "*"');
        LibraryAssert.IsTrue(Row.Get('No.', Tok), 'PK must survive "*"');

        Helper.UnexposeField(Database::Customer, CustomerFieldNo('Name'));
    end;

    [Test]
    procedure FilterOnDeniedFieldIs403NotInvalidFilter()
    var
        Data, Response, Fail: JsonObject;
        Cost: Integer;
    begin
        // The row-membership oracle: `Name eq X` on a denied field must be a 403 policy
        // denial, not a 400 invalid-filter and never a silently ignored condition.
        Helper.ConfigureOpenMode();
        SeedCustomers();
        Helper.SetFieldPolicyMode(Enum::"Bcmag Field Policy Mode"::ByClassification);
        Helper.ExposeField(Database::Customer, CustomerFieldNo('Name'), false, false);

        Data.Add('tableId', Database::Customer);
        Data.Add('filter', 'Name eq ''Policy One''');
        LibraryAssert.IsFalse(OpQuery.Run(Data, Response, Fail, Cost), 'filter on a denied field must fail');
        AssertFieldRestricted(Fail);

        Helper.UnexposeField(Database::Customer, CustomerFieldNo('Name'));
    end;

    [Test]
    procedure OrderByDeniedFieldIs403()
    var
        Data, Response, Fail: JsonObject;
        OrderBy: JsonArray;
        Cost: Integer;
    begin
        Helper.ConfigureOpenMode();
        SeedCustomers();
        Helper.SetFieldPolicyMode(Enum::"Bcmag Field Policy Mode"::ByClassification);
        Helper.ExposeField(Database::Customer, CustomerFieldNo('Name'), false, false);

        OrderBy.Add('Name asc');
        Data.Add('tableId', Database::Customer);
        Data.Add('orderBy', OrderBy);
        LibraryAssert.IsFalse(OpQuery.Run(Data, Response, Fail, Cost), 'orderBy on a denied field must fail');
        AssertFieldRestricted(Fail);

        Helper.UnexposeField(Database::Customer, CustomerFieldNo('Name'));
    end;

    [Test]
    procedure DescribeOmitsAndFlagsRestrictedFields()
    var
        FieldsArr: JsonArray;
        FieldObj: JsonObject;
        Tok: JsonToken;
        i: Integer;
    begin
        Helper.ConfigureOpenMode();
        Helper.SetFieldPolicyMode(Enum::"Bcmag Field Policy Mode"::ByClassification);
        Helper.SetDescribeRestrictedFields(false);
        Helper.ExposeField(Database::Customer, CustomerFieldNo('Name'), false, false);

        // Default: a restricted field is absent entirely; PK is present and readable; every
        // emitted field carries the readable/writable flags.
        DescribeCustomerFields(FieldsArr);
        LibraryAssert.IsFalse(FindFieldObj(FieldsArr, 'Name', FieldObj), 'restricted field must be omitted from describe');
        LibraryAssert.IsTrue(FindFieldObj(FieldsArr, 'No.', FieldObj), 'PK field must always be described');
        LibraryAssert.IsTrue(BoolOf(FieldObj, 'readable'), 'PK must be readable');
        for i := 0 to FieldsArr.Count() - 1 do begin
            FieldsArr.Get(i, Tok);
            FieldObj := Tok.AsObject();
            LibraryAssert.IsTrue(FieldObj.Get('readable', Tok), 'every field must carry readable');
            LibraryAssert.IsTrue(FieldObj.Get('writable', Tok), 'every field must carry writable');
        end;

        // Opt-in: the restricted field appears, flagged readable=false.
        Helper.SetDescribeRestrictedFields(true);
        Clear(FieldsArr);
        DescribeCustomerFields(FieldsArr);
        LibraryAssert.IsTrue(FindFieldObj(FieldsArr, 'Name', FieldObj), 'restricted field must appear when opted in');
        LibraryAssert.IsFalse(BoolOf(FieldObj, 'readable'), 'restricted field must be flagged readable=false');

        Helper.SetDescribeRestrictedFields(false);
        Helper.UnexposeField(Database::Customer, CustomerFieldNo('Name'));
    end;

    [Test]
    procedure WriteDeniedFieldIs403BeforeAnyWrite()
    var
        Customer: Record Customer;
        InsData, ModData, Response, Fail: JsonObject;
        InsValues, InsValuesByNo, ModValues, OkValues: JsonObject;
        Cost: Integer;
        RecordId: Text;
    begin
        Helper.ConfigureAllowlistedMode();
        Helper.EnsureManualCustomerNos();
        Helper.ExposeTable(Database::Customer, true, true, true, true);
        SeedCustomers();
        Helper.SetFieldPolicyMode(Enum::"Bcmag Field Policy Mode"::ByClassification);
        // Readable but not writable — read paths keep working while writes are denied.
        Helper.ExposeField(Database::Customer, CustomerFieldNo('Name'), true, false);
        if Customer.Get('FPW-1') then Customer.Delete();

        // insert via values: denied before any Validate — nothing may be persisted.
        InsValues.Add('No.', 'FPW-1');
        InsValues.Add('Name', 'Blocked');
        InsData.Add('tableId', Database::Customer);
        InsData.Add('values', InsValues);
        LibraryAssert.IsFalse(OpInsert.Run(InsData, Response, Fail, Cost), 'insert writing a denied field must fail');
        AssertFieldRestricted(Fail);
        LibraryAssert.IsFalse(Customer.Get('FPW-1'), 'denied insert must not persist a row');

        // insert via valuesByFieldNo: the numeric path is equally closed.
        Clear(InsData);
        InsValuesByNo.Add(Format(CustomerFieldNo('Name')), 'Blocked');
        InsData.Add('tableId', Database::Customer);
        InsData.Add('valuesByFieldNo', InsValuesByNo);
        LibraryAssert.IsFalse(OpInsert.Run(InsData, Response, Fail, Cost), 'valuesByFieldNo on a denied field must fail');
        AssertFieldRestricted(Fail);

        // insert touching only the PK succeeds — PK fields are always writable.
        Clear(InsData);
        Clear(InsValues);
        InsValues.Add('No.', 'FPW-1');
        InsData.Add('tableId', Database::Customer);
        InsData.Add('values', InsValues);
        LibraryAssert.IsTrue(OpInsert.Run(InsData, Response, Fail, Cost), 'PK-only insert must succeed');
        LibraryAssert.IsTrue(Customer.Get('FPW-1'), 'PK-only insert must persist');

        // modify the denied field: 403, value unchanged.
        RecordId := Codec.Encode(Customer.RecordId);
        ModValues.Add('Name', 'Blocked');
        ModData.Add('tableId', Database::Customer);
        ModData.Add('recordId', RecordId);
        ModData.Add('values', ModValues);
        LibraryAssert.IsFalse(OpModify.Run(ModData, Response, Fail, Cost), 'modify writing a denied field must fail');
        AssertFieldRestricted(Fail);
        Customer.Get('FPW-1');
        LibraryAssert.AreEqual('', Customer.Name, 'denied modify must not change the field');

        // a normal (classification-allowed) field stays writable.
        Clear(ModData);
        OkValues.Add('Address', 'Policy Street 1');
        ModData.Add('tableId', Database::Customer);
        ModData.Add('recordId', RecordId);
        ModData.Add('values', OkValues);
        LibraryAssert.IsTrue(OpModify.Run(ModData, Response, Fail, Cost), 'an allowed field must remain writable');
        Customer.Get('FPW-1');
        LibraryAssert.AreEqual('Policy Street 1', Customer.Address, 'allowed modify must persist');

        Customer.Delete();
        Helper.UnexposeField(Database::Customer, CustomerFieldNo('Name'));
        Helper.UnexposeTable(Database::Customer);
    end;

    [Test]
    procedure ExplicitModeRequiresOverrideRows()
    var
        Response, Fail: JsonObject;
    begin
        Helper.ConfigureOpenMode();
        SeedCustomers();
        Helper.SetFieldPolicyMode(Enum::"Bcmag Field Policy Mode"::Explicit);
        Helper.UnexposeField(Database::Customer, CustomerFieldNo('Name'));

        // No row: everything but the PK is dark.
        LibraryAssert.IsFalse(RunQuerySelect('Name', Response, Fail), 'Explicit mode must deny fields without a row');
        AssertFieldRestricted(Fail);
        Clear(Response);
        LibraryAssert.IsTrue(RunQueryDefault(Response, Fail), 'default PK select must work in Explicit mode');

        // An Allow-Read row opens exactly that field.
        Helper.ExposeField(Database::Customer, CustomerFieldNo('Name'), true, false);
        Clear(Response);
        LibraryAssert.IsTrue(RunQuerySelect('Name', Response, Fail), 'an Allow-Read row must grant the field');

        Helper.UnexposeField(Database::Customer, CustomerFieldNo('Name'));
    end;

    [Test]
    procedure ClassificationSwitchGovernsWithoutRows()
    var
        Response, Fail: JsonObject;
    begin
        // Pure classification path — no override rows: Customer.Name is CustomerContent, so the
        // CustomerContent classification rule alone decides, while the PK survives either way.
        Helper.ConfigureOpenMode();
        SeedCustomers();
        Helper.SetFieldPolicyMode(Enum::"Bcmag Field Policy Mode"::ByClassification);
        Helper.UnexposeField(Database::Customer, CustomerFieldNo('Name'));

        Helper.SetExposeCustomerContent(false);
        LibraryAssert.IsFalse(RunQuerySelect('Name', Response, Fail), 'CustomerContent off must hide Name');
        AssertFieldRestricted(Fail);
        Clear(Response);
        LibraryAssert.IsTrue(RunQueryDefault(Response, Fail), 'PK must survive a dark classification');

        Helper.SetExposeCustomerContent(true);
        Clear(Response);
        LibraryAssert.IsTrue(RunQuerySelect('Name', Response, Fail), 'CustomerContent on must restore Name');
    end;

    [Test]
    procedure MaskedFieldStaysSelectable()
    var
        Response, Fail: JsonObject;
    begin
        // Masked is a READABLE verdict: the field is selected and emitted (as its mask rendering), so a
        // select naming it must not be refused the way a Hidden field is.
        Helper.ConfigureOpenMode(); // Unmask tier off: SUPER would otherwise lift the mask
        SeedCustomers();
        Helper.SetFieldPolicyMode(Enum::"Bcmag Field Policy Mode"::ByClassification);
        Helper.SetFieldAccess(Database::Customer, CustomerFieldNo('Name'), "Bcmag Read Access"::Masked, 'PARTIAL', false);

        LibraryAssert.IsTrue(RunQuerySelect('Name', Response, Fail), 'a Masked field must stay selectable');

        Helper.UnexposeField(Database::Customer, CustomerFieldNo('Name'));
    end;

    [Test]
    procedure ReusedHandlerSeesPolicyChanges()
    var
        Response, Fail: JsonObject;
    begin
        // The field policy caches verdicts per instance, and this codeunit holds ONE Op Query (with its
        // policy instances) across every call. A policy write in the session must invalidate those
        // caches: hide, open, hide again — each call answers from the policy as it is now.
        Helper.ConfigureOpenMode();
        SeedCustomers();
        Helper.SetFieldPolicyMode(Enum::"Bcmag Field Policy Mode"::ByClassification);

        Helper.ExposeField(Database::Customer, CustomerFieldNo('Name'), false, false);
        LibraryAssert.IsFalse(RunQuerySelect('Name', Response, Fail), 'hidden: select must fail');
        AssertFieldRestricted(Fail);

        Helper.ExposeField(Database::Customer, CustomerFieldNo('Name'), true, false);
        Clear(Response);
        Clear(Fail);
        LibraryAssert.IsTrue(RunQuerySelect('Name', Response, Fail), 'opened: the same handler must see the new row');

        Helper.ExposeField(Database::Customer, CustomerFieldNo('Name'), false, false);
        Clear(Response);
        Clear(Fail);
        LibraryAssert.IsFalse(RunQuerySelect('Name', Response, Fail), 'hidden again: no stale Clear verdict');
        AssertFieldRestricted(Fail);

        Helper.UnexposeField(Database::Customer, CustomerFieldNo('Name'));
    end;

    [Test]
    procedure ReadBlobOnDeniedBinaryFieldIs403()
    var
        Customer: Record Customer;
        Data, Response, Fail: JsonObject;
        Cost: Integer;
    begin
        // Binaries never travel in query projections, so readBlob is their only route and must
        // honor the same 403. Customer.Image (Media) resolved via the Field table, not hardcoded.
        Helper.ConfigureOpenMode();
        SeedCustomers();
        Helper.SetFieldPolicyMode(Enum::"Bcmag Field Policy Mode"::ByClassification);
        Helper.ExposeField(Database::Customer, CustomerFieldNo('Image'), false, false);
        Customer.Get('FP-1');

        Data.Add('tableId', Database::Customer);
        Data.Add('recordId', Codec.Encode(Customer.RecordId));
        Data.Add('fieldNo', CustomerFieldNo('Image'));
        LibraryAssert.IsFalse(OpReadBlob.Run(Data, Response, Fail, Cost), 'readBlob on a denied field must fail');
        AssertFieldRestricted(Fail);

        Helper.UnexposeField(Database::Customer, CustomerFieldNo('Image'));
    end;

    [Test]
    procedure ReadBlobOnMaskedBinaryFieldIs403FieldMasked()
    var
        Customer: Record Customer;
        Data, Response, Fail: JsonObject;
        Cost: Integer;
    begin
        // Masked is readable, but only as a rendering, and bytes have no partial form: readBlob must
        // refuse a masked binary (403 field-masked) instead of returning its content in clear.
        Helper.ConfigureOpenMode(); // Unmask tier off: SUPER would otherwise lift the mask
        SeedCustomers();
        Helper.SetFieldPolicyMode(Enum::"Bcmag Field Policy Mode"::ByClassification);
        Helper.SetFieldAccess(Database::Customer, CustomerFieldNo('Image'), "Bcmag Read Access"::Masked, '', false);
        Customer.Get('FP-1');

        Data.Add('tableId', Database::Customer);
        Data.Add('recordId', Codec.Encode(Customer.RecordId));
        Data.Add('fieldNo', CustomerFieldNo('Image'));
        LibraryAssert.IsFalse(OpReadBlob.Run(Data, Response, Fail, Cost), 'readBlob on a masked binary must fail');
        LibraryAssert.AreEqual(403, Helper.StatusOf(Fail), 'expected 403');
        LibraryAssert.AreEqual(Problem.TypeUri('field-masked'), Problem.ProblemTypeOf(Fail), 'expected the field-masked problem type');

        Helper.UnexposeField(Database::Customer, CustomerFieldNo('Image'));
    end;

    [Test]
    procedure SuggestionNeverNamesRestrictedField()
    var
        Response, Fail: JsonObject;
    begin
        // A "did you mean" suggestion must not disclose a restricted field's name. In AllFields the
        // typo suggests the real field; once the field is denied under a policy mode, the suggestion
        // must drop it so the name is never echoed back.
        SeedCustomers();
        Helper.ConfigureOpenMode(); // AllFields
        LibraryAssert.IsFalse(RunQuerySelect('Naem', Response, Fail), 'typo must not resolve');
        LibraryAssert.IsTrue(StrPos(Helper.DetailOf(Fail), 'Name') > 0, 'AllFields should suggest the real field');

        Clear(Fail);
        Helper.SetFieldPolicyMode(Enum::"Bcmag Field Policy Mode"::ByClassification);
        Helper.ExposeField(Database::Customer, CustomerFieldNo('Name'), false, false);
        LibraryAssert.IsFalse(RunQuerySelect('Naem', Response, Fail), 'typo must still not resolve');
        LibraryAssert.IsTrue(StrPos(Helper.DetailOf(Fail), 'Name') = 0, 'a restricted field name must never leak via a suggestion');

        Helper.UnexposeField(Database::Customer, CustomerFieldNo('Name'));
    end;

    [Test]
    procedure RestrictedFieldNumberDetailOmitsName()
    var
        Data, Response, Fail: JsonObject;
        SelectNo: JsonArray;
        Cost: Integer;
    begin
        // selectFieldNo denial must name the field by NUMBER only — resolving the name would hand a
        // restricted field's name to a caller who supplied a bare number.
        SeedCustomers();
        Helper.ConfigureOpenMode();
        Helper.SetFieldPolicyMode(Enum::"Bcmag Field Policy Mode"::ByClassification);
        Helper.ExposeField(Database::Customer, CustomerFieldNo('Name'), false, false);

        SelectNo.Add(CustomerFieldNo('Name'));
        Data.Add('tableId', Database::Customer);
        Data.Add('selectFieldNo', SelectNo);
        Data.Add('top', 10);
        LibraryAssert.IsFalse(OpQuery.Run(Data, Response, Fail, Cost), 'denied selectFieldNo must fail');
        AssertFieldRestricted(Fail);
        LibraryAssert.IsTrue(StrPos(Helper.DetailOf(Fail), 'Name') = 0, 'the field name must not appear in the detail');

        Helper.UnexposeField(Database::Customer, CustomerFieldNo('Name'));
    end;

    [Test]
    procedure DescribeOmitsKeysOverRestrictedField()
    begin
        // A secondary key over a restricted field leaks that field's name (in the key string) and
        // existence (the index itself); it is omitted unless the admin opts into showing restricted
        // fields. The primary key is always readable, so addressing is never affected.
        SeedCustomers();
        Helper.ConfigureOpenMode();
        Helper.SetFieldPolicyMode(Enum::"Bcmag Field Policy Mode"::ByClassification);
        Helper.ExposeField(Database::Customer, CustomerFieldNo('Name'), false, false);
        Helper.SetDescribeRestrictedFields(false);

        LibraryAssert.IsFalse(DescribeHasKeyOverName(), 'a key over the denied Name field must be hidden');
        LibraryAssert.IsTrue(DescribeHasPrimaryKey(), 'the primary key must always be present');

        Helper.SetDescribeRestrictedFields(true);
        LibraryAssert.IsTrue(DescribeHasKeyOverName(), 'opting in must surface the key again');

        Helper.SetDescribeRestrictedFields(false);
        Helper.UnexposeField(Database::Customer, CustomerFieldNo('Name'));
    end;

    local procedure DescribeKeys(var KeysArr: JsonArray)
    var
        Data, Response, Fail, Value: JsonObject;
        Tok: JsonToken;
        Cost: Integer;
    begin
        Data.Add('kind', 'table');
        Data.Add('tableId', Database::Customer);
        LibraryAssert.IsTrue(OpDescribe.Run(Data, Response, Fail, Cost), 'describe should succeed');
        Value := Helper.ValueObject(Response);
        LibraryAssert.IsTrue(Value.Get('keys', Tok), 'keys missing');
        KeysArr := Tok.AsArray();
    end;

    local procedure DescribeHasKeyOverName(): Boolean
    var
        KeysArr: JsonArray;
        KeyTok, FieldsTok, FieldTok: JsonToken;
        KeyObj: JsonObject;
        NameFieldNo, i: Integer;
    begin
        // Match on the key's field NUMBERS, not a substring of its name: "Search Name" is a different,
        // readable field whose key must stay visible, and the first CI run showed the old StrPos check
        // tripping on exactly that key.
        NameFieldNo := CustomerFieldNo('Name');
        DescribeKeys(KeysArr);
        for i := 0 to KeysArr.Count() - 1 do begin
            KeysArr.Get(i, KeyTok);
            KeyObj := KeyTok.AsObject();
            if KeyObj.Get('fields', FieldsTok) then
                foreach FieldTok in FieldsTok.AsArray() do
                    if FieldTok.AsValue().AsInteger() = NameFieldNo then
                        exit(true);
        end;
        exit(false);
    end;

    local procedure DescribeHasPrimaryKey(): Boolean
    var
        KeysArr: JsonArray;
        KeyTok: JsonToken;
        KeyObj: JsonObject;
        PrimaryTok: JsonToken;
        i: Integer;
    begin
        DescribeKeys(KeysArr);
        for i := 0 to KeysArr.Count() - 1 do begin
            KeysArr.Get(i, KeyTok);
            KeyObj := KeyTok.AsObject();
            if KeyObj.Get('isPrimary', PrimaryTok) then
                if PrimaryTok.AsValue().AsBoolean() then
                    exit(true);
        end;
        exit(false);
    end;

    local procedure MaskName()
    begin
        Helper.ConfigureOpenMode(); // Unmask tier off: SUPER would otherwise lift the mask
        SeedCustomers();
        Helper.SetFieldPolicyMode(Enum::"Bcmag Field Policy Mode"::ByClassification);
        Helper.SetFieldAccess(Database::Customer, CustomerFieldNo('Name'), "Bcmag Read Access"::Masked, 'PARTIAL', false);
    end;

    local procedure AssertFieldMasked(Fail: JsonObject)
    begin
        LibraryAssert.AreEqual(403, Helper.StatusOf(Fail), 'expected 403');
        LibraryAssert.AreEqual(Problem.TypeUri('field-masked'), Problem.ProblemTypeOf(Fail),
            'expected the field-masked problem type');
        LibraryAssert.IsFalse(Helper.DetailOf(Fail).Contains('[field-masked]'), 'the marker must not leak into the detail');
    end;

    [Test]
    procedure FilterOnMaskedFieldIs403FieldMasked()
    var
        Data, Response, Fail: JsonObject;
        Cost: Integer;
    begin
        // A masked value must not be reconstructable by probing row membership.
        MaskName();
        Data.Add('tableId', Database::Customer);
        Data.Add('filter', 'Name eq ''Policy One''');
        LibraryAssert.IsFalse(OpQuery.Run(Data, Response, Fail, Cost), 'filter on a masked field must fail');
        AssertFieldMasked(Fail);
        Helper.UnexposeField(Database::Customer, CustomerFieldNo('Name'));
    end;

    [Test]
    procedure StartsWithOnMaskedFieldIs403FieldMasked()
    var
        Data, Response, Fail: JsonObject;
        Cost: Integer;
    begin
        MaskName();
        Data.Add('tableId', Database::Customer);
        Data.Add('filter', 'startswith(Name, ''P'')');
        LibraryAssert.IsFalse(OpQuery.Run(Data, Response, Fail, Cost), 'startswith on a masked field must fail');
        AssertFieldMasked(Fail);
        Helper.UnexposeField(Database::Customer, CustomerFieldNo('Name'));
    end;

    [Test]
    procedure OrderByMaskedFieldIs403FieldMasked()
    var
        Data, Response, Fail: JsonObject;
        OrderBy: JsonArray;
        Cost: Integer;
    begin
        MaskName();
        OrderBy.Add('Name');
        Data.Add('tableId', Database::Customer);
        Data.Add('orderBy', OrderBy);
        LibraryAssert.IsFalse(OpQuery.Run(Data, Response, Fail, Cost), 'orderBy on a masked field must fail');
        AssertFieldMasked(Fail);
        Helper.UnexposeField(Database::Customer, CustomerFieldNo('Name'));
    end;

    [Test]
    procedure FilterOnClearFieldStillWorksWhileAnotherIsMasked()
    var
        Data, Response, Fail: JsonObject;
        Cost: Integer;
    begin
        MaskName();
        Data.Add('tableId', Database::Customer);
        Data.Add('filter', '#1 eq ''FP-1''');
        LibraryAssert.IsTrue(OpQuery.Run(Data, Response, Fail, Cost), StrSubstNo('a Clear field must still filter: %1', Helper.DetailOf(Fail)));
        Helper.UnexposeField(Database::Customer, CustomerFieldNo('Name'));
    end;

    [Test]
    procedure ReplayShapeCheckSurfacesAMaskedFilterAs403()
    var
        Data, Fail: JsonObject;
    begin
        // The idempotency replay authorizer refuses a stored response when ValidateShape returns 403;
        // a filter that now targets a masked field must surface as one.
        MaskName();
        Data.Add('tableId', Database::Customer);
        Data.Add('filter', 'Name eq ''Policy One''');
        LibraryAssert.IsFalse(OpQuery.ValidateShape(Data, Fail), 'a masked filter must fail the shape check');
        AssertFieldMasked(Fail);
        Helper.UnexposeField(Database::Customer, CustomerFieldNo('Name'));
    end;
}
