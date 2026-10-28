codeunit 94332 "Bcmag Api Catalog Test"
{
    // The API catalog: discover kind "apis", describe kind "api", the apiRoutes a table describe carries,
    // the catalogVersion fingerprint a client caches against, and the routable/readable governance
    // answers. Fixture: Microsoft's standard v2.0 customers API (page "APIV2 - Customers" over table 18),
    // present in every environment the suite runs in.
    Subtype = Test;
    TestPermissions = Disabled;

    var
        Discover: Codeunit "Bcmag Op Discover";
        Describe: Codeunit "Bcmag Op Describe";
        Capabilities: Codeunit "Bcmag Op Capabilities";
        Helper: Codeunit "Bcmag Test Helper";
        LibraryAssert: Codeunit "Library Assert";

    [Test]
    procedure DiscoverApisFindsTheCustomersApiForTable18()
    var
        Response: JsonObject;
        Row: JsonObject;
    begin
        Helper.ConfigureOpenMode();
        Response := DiscoverApis(Database::Customer, '', 0);
        LibraryAssert.IsTrue(FindRoute(Helper.ValueArray(Response), 'v2.0/customers', Row), 'v2.0/customers should be listed for table 18');
        LibraryAssert.AreEqual('page', Helper.TextField(Row, 'apiKind'), 'apiKind');
        LibraryAssert.AreEqual('customers', Helper.TextField(Row, 'entitySetName'), 'entitySetName');
        LibraryAssert.AreEqual(Database::Customer, IntField(Row, 'sourceTableId'), 'sourceTableId');
        LibraryAssert.AreNotEqual('', Helper.TextField(Response, 'catalogVersion'), 'catalogVersion');
        LibraryAssert.AreEqual('Off', Helper.TextField(Response, 'apiRouting'), 'routing starts off');
    end;

    [Test]
    procedure DiscoverApisNeverListsTheBcmagEndpoint()
    var
        Response: JsonObject;
    begin
        Helper.ConfigureOpenMode();
        Response := DiscoverApis(0, 'wicketEndpoint', 0);
        LibraryAssert.AreEqual(0, Helper.ValueArray(Response).Count(), 'Wicket''s own endpoint is transport, not data');
        LibraryAssert.AreEqual(0, IntField(Response, '@count'), '@count');
    end;

    [Test]
    procedure DiscoverApisPagesWithSkip()
    var
        First, Second: JsonObject;
        Tok: JsonToken;
        FirstId, SecondId: Integer;
    begin
        Helper.ConfigureOpenMode();
        First := DiscoverApis(0, '', 0);
        LibraryAssert.IsTrue(IntField(First, '@count') > 5, 'the standard catalog holds more than five APIs');
        First := DiscoverApis(0, '', 0, 5);
        LibraryAssert.AreEqual(5, Helper.ValueArray(First).Count(), 'top 5');
        LibraryAssert.AreEqual(5, IntField(First, '@nextSkip'), '@nextSkip');
        Second := DiscoverApis(0, '', 5, 5);
        Helper.ValueArray(First).Get(0, Tok);
        FirstId := IntField(Tok.AsObject(), 'id');
        Helper.ValueArray(Second).Get(0, Tok);
        SecondId := IntField(Tok.AsObject(), 'id');
        LibraryAssert.AreNotEqual(FirstId, SecondId, 'skip moves the window');
    end;

    [Test]
    procedure DiscoverApisIfNoneMatchAnswersNotModified()
    var
        Data, Response, Fail: JsonObject;
        Cost: Integer;
        Version: Text;
    begin
        Helper.ConfigureOpenMode();
        Version := Helper.TextField(DiscoverApis(0, '', 0), 'catalogVersion');

        Data.Add('kind', 'apis');
        Data.Add('ifNoneMatch', Version);
        LibraryAssert.IsTrue(Discover.Run(Data, Response, Fail, Cost), 'revalidation should succeed');
        LibraryAssert.IsTrue(BoolField(Response, 'notModified'), 'an unchanged catalog is notModified');
        LibraryAssert.AreEqual(0, Helper.ValueArray(Response).Count(), 'no rows when notModified');
        LibraryAssert.AreEqual(Version, Helper.TextField(Response, 'catalogVersion'), 'same version echoed');

        Clear(Data);
        Clear(Response);
        Data.Add('kind', 'apis');
        Data.Add('ifNoneMatch', 'stale');
        LibraryAssert.IsTrue(Discover.Run(Data, Response, Fail, Cost), 'a stale version lists again');
        LibraryAssert.IsFalse(BoolField(Response, 'notModified'), 'a stale version is not notModified');
        LibraryAssert.IsTrue(Helper.ValueArray(Response).Count() > 0, 'rows listed');
    end;

    [Test]
    procedure CatalogVersionIgnoresTheRoutingSwitch()
    var
        Before, After: Text;
    begin
        // The fingerprint is about the catalog's content; governance changes must not invalidate caches.
        Helper.ConfigureOpenMode();
        Before := Helper.TextField(DiscoverApis(0, '', 0), 'catalogVersion');
        Helper.SetApiRouting("Bcmag Api Routing"::Prefer);
        After := Helper.TextField(DiscoverApis(0, '', 0), 'catalogVersion');
        LibraryAssert.AreEqual(Before, After, 'catalogVersion is stable across a routing change');
    end;

    [Test]
    procedure DiscoverApisRejectsAMalformedFilter()
    var
        Data, Response, Fail: JsonObject;
        Cost: Integer;
    begin
        Helper.ConfigureOpenMode();
        Data.Add('kind', 'apis');
        Data.Add('filter', '((');
        LibraryAssert.IsFalse(Discover.Run(Data, Response, Fail, Cost), 'malformed filter');
        LibraryAssert.AreEqual(400, Helper.StatusOf(Fail), '400');
        LibraryAssert.IsTrue(StrPos(Helper.TypeOf(Fail), 'invalid-filter') > 0, 'invalid-filter');
    end;

    [Test]
    procedure DescribeTableListsItsApiRoutes()
    var
        Data, Response, Fail: JsonObject;
        Tok: JsonToken;
        Route: JsonObject;
        Cost: Integer;
        Found: Boolean;
    begin
        Helper.ConfigureOpenMode();
        Data.Add('kind', 'table');
        Data.Add('tableId', Database::Customer);
        LibraryAssert.IsTrue(Describe.Run(Data, Response, Fail, Cost), 'describe table');
        LibraryAssert.IsTrue(Helper.ValueObject(Response).Get('apiRoutes', Tok), 'apiRoutes present');
        foreach Tok in Tok.AsArray() do begin
            Route := Tok.AsObject();
            if Helper.TextField(Route, 'route') = 'v2.0/customers' then
                Found := true;
        end;
        LibraryAssert.IsTrue(Found, 'apiRoutes names v2.0/customers');
    end;

    [Test]
    procedure DescribeApiMapsFieldsAndIsNotRoutableWhileRoutingIsOff()
    var
        Api, FieldObj: JsonObject;
    begin
        Helper.ConfigureOpenMode();
        Api := DescribeCustomersApi();
        LibraryAssert.IsFalse(BoolField(Api, 'routable'), 'routing off → not routable');
        LibraryAssert.AreEqual('routing-off', Helper.TextField(Api, 'notRoutableReason'), 'reason');
        LibraryAssert.IsTrue(FindField(Api, 'displayName', FieldObj), 'displayName field');
        LibraryAssert.IsTrue(BoolField(FieldObj, 'mapped'), 'displayName is bound to a table field');
        LibraryAssert.AreEqual(2, IntField(FieldObj, 'fieldNo'), 'displayName → Customer.Name (field 2)');
        LibraryAssert.AreNotEqual('', Helper.TextField(Api, 'catalogVersion'), 'catalogVersion');
    end;

    [Test]
    procedure DescribeApiIsRoutableWhenPreferredAndTheTableIsExposed()
    var
        Api, FieldObj: JsonObject;
    begin
        Helper.ConfigureAllowlistedMode();
        Helper.ExposeTable(Database::Customer, true, false, false, false);
        Helper.SetApiRouting("Bcmag Api Routing"::Prefer);
        Api := DescribeCustomersApi();
        LibraryAssert.IsTrue(BoolField(Api, 'routable'), 'Prefer + exposed → routable');
        LibraryAssert.IsTrue(FindField(Api, 'displayName', FieldObj), 'displayName field');
        LibraryAssert.IsTrue(BoolField(FieldObj, 'readable'), 'displayName readable under AllFields');
    end;

    [Test]
    procedure DescribeApiIsNotRoutableForAnUnexposedTable()
    var
        Api, FieldObj: JsonObject;
    begin
        Helper.ConfigureAllowlistedMode();
        Helper.UnexposeTable(Database::Customer);
        Helper.SetApiRouting("Bcmag Api Routing"::Prefer);
        Api := DescribeCustomersApi();
        LibraryAssert.IsFalse(BoolField(Api, 'routable'), 'unexposed → not routable');
        LibraryAssert.AreEqual('not-exposed', Helper.TextField(Api, 'notRoutableReason'), 'reason');
        LibraryAssert.IsTrue(FindField(Api, 'number', FieldObj), 'number field');
        LibraryAssert.IsFalse(BoolField(FieldObj, 'readable'), 'no field of an unexposed table is readable');
    end;

    [Test]
    procedure DescribeApiAppliesTheFieldPolicy()
    var
        Api, FieldObj: JsonObject;
    begin
        // Explicit mode with no allow rows: only primary-key fields stay readable.
        Helper.ConfigureOpenMode();
        Helper.SetApiRouting("Bcmag Api Routing"::Prefer);
        Helper.SetFieldPolicyMode("Bcmag Field Policy Mode"::Explicit);
        Api := DescribeCustomersApi();
        LibraryAssert.IsTrue(BoolField(Api, 'routable'), 'the table itself stays readable');
        LibraryAssert.IsTrue(FindField(Api, 'number', FieldObj), 'number field');
        LibraryAssert.IsTrue(BoolField(FieldObj, 'readable'), 'number → Customer."No." (primary key) is always readable');
        LibraryAssert.IsTrue(FindField(Api, 'displayName', FieldObj), 'displayName field');
        LibraryAssert.IsFalse(BoolField(FieldObj, 'readable'), 'displayName → Customer.Name is restricted');
    end;

    [Test]
    procedure DescribeApiRefusesAPageThatIsNotAnApi()
    var
        Data, Response, Fail: JsonObject;
        Cost: Integer;
    begin
        Helper.ConfigureOpenMode();
        Data.Add('kind', 'api');
        Data.Add('pageId', Page::"Bcmag Setup Card");
        LibraryAssert.IsFalse(Describe.Run(Data, Response, Fail, Cost), 'a card page is not an API');
        LibraryAssert.AreEqual(404, Helper.StatusOf(Fail), '404');
        LibraryAssert.IsTrue(StrPos(Helper.TypeOf(Fail), 'unknown-api') > 0, 'unknown-api');
    end;

    [Test]
    procedure DescribeApiRefusesTheBcmagEndpoint()
    var
        Data, Response, Fail: JsonObject;
        Cost: Integer;
    begin
        Helper.ConfigureOpenMode();
        Data.Add('kind', 'api');
        Data.Add('pageId', Page::"Bcmag Rpc Endpoint");
        LibraryAssert.IsFalse(Describe.Run(Data, Response, Fail, Cost), 'the endpoint is not in the catalog');
        LibraryAssert.AreEqual(404, Helper.StatusOf(Fail), '404');
    end;

    [Test]
    procedure DescribeApiNeedsAPageOrQueryId()
    var
        Data, Response, Fail: JsonObject;
        Cost: Integer;
    begin
        Helper.ConfigureOpenMode();
        Data.Add('kind', 'api');
        LibraryAssert.IsFalse(Describe.Run(Data, Response, Fail, Cost), 'no id');
        LibraryAssert.AreEqual(400, Helper.StatusOf(Fail), '400');
        LibraryAssert.IsTrue(StrPos(Helper.TypeOf(Fail), 'missing-field') > 0, 'missing-field');
    end;

    [Test]
    procedure CapabilitiesAdvertiseApiRouting()
    var
        Data, Response, Fail, ApiObj: JsonObject;
        Tok: JsonToken;
        Cost: Integer;
    begin
        Helper.ConfigureOpenMode();
        Helper.SetApiRouting("Bcmag Api Routing"::Prefer);
        LibraryAssert.IsTrue(Capabilities.Run(Data, Response, Fail, Cost), 'capabilities');
        LibraryAssert.IsTrue(Helper.ValueObject(Response).Get('apiRouting', Tok), 'apiRouting block');
        ApiObj := Tok.AsObject();
        LibraryAssert.AreEqual('Prefer', Helper.TextField(ApiObj, 'mode'), 'mode');
        LibraryAssert.AreEqual(Helper.TextField(DiscoverApis(0, '', 0), 'catalogVersion'), Helper.TextField(ApiObj, 'catalogVersion'), 'same fingerprint as discover');
    end;

    // ---- helpers ----------------------------------------------------------------------------------

    local procedure DiscoverApis(TableId: Integer; FilterText: Text; Skip: Integer): JsonObject
    begin
        exit(DiscoverApis(TableId, FilterText, Skip, 1000));
    end;

    local procedure DiscoverApis(TableId: Integer; FilterText: Text; Skip: Integer; Top: Integer) Response: JsonObject
    var
        Data, Fail: JsonObject;
        Cost: Integer;
    begin
        Data.Add('kind', 'apis');
        if TableId <> 0 then
            Data.Add('tableId', TableId);
        if FilterText <> '' then
            Data.Add('filter', FilterText);
        if Skip <> 0 then
            Data.Add('skip', Skip);
        Data.Add('top', Top);
        LibraryAssert.IsTrue(Discover.Run(Data, Response, Fail, Cost), 'discover apis should succeed');
    end;

    local procedure DescribeCustomersApi(): JsonObject
    var
        Data, Response, Fail, Row: JsonObject;
        Cost: Integer;
    begin
        LibraryAssert.IsTrue(FindRoute(Helper.ValueArray(DiscoverApis(Database::Customer, '', 0)), 'v2.0/customers', Row), 'customers API');
        Data.Add('kind', 'api');
        Data.Add('pageId', IntField(Row, 'id'));
        LibraryAssert.IsTrue(Describe.Run(Data, Response, Fail, Cost), 'describe api should succeed');
        exit(Helper.ValueObject(Response));
    end;

    local procedure FindRoute(Rows: JsonArray; Route: Text; var Row: JsonObject): Boolean
    var
        Tok: JsonToken;
    begin
        foreach Tok in Rows do
            if Helper.TextField(Tok.AsObject(), 'route') = Route then begin
                Row := Tok.AsObject();
                exit(true);
            end;
        exit(false);
    end;

    local procedure FindField(Api: JsonObject; Name: Text; var FieldObj: JsonObject): Boolean
    var
        Tok: JsonToken;
    begin
        if not Api.Get('fields', Tok) then
            exit(false);
        foreach Tok in Tok.AsArray() do
            if Helper.TextField(Tok.AsObject(), 'name') = Name then begin
                FieldObj := Tok.AsObject();
                exit(true);
            end;
        exit(false);
    end;

    local procedure IntField(Obj: JsonObject; Name: Text): Integer
    var
        Tok: JsonToken;
    begin
        if Obj.Get(Name, Tok) then
            exit(Tok.AsValue().AsInteger());
        exit(0);
    end;

    local procedure BoolField(Obj: JsonObject; Name: Text): Boolean
    var
        Tok: JsonToken;
    begin
        if Obj.Get(Name, Tok) then
            exit(Tok.AsValue().AsBoolean());
        exit(false);
    end;

    [Test]
    procedure DescribeApiMarksAMaskedFieldUnreadableWithAccessMasked()
    var
        Api, FieldObj: JsonObject;
        FieldRec: Record Field;
        Tok: JsonToken;
    begin
        // A masked field is never routable to the tenant API (it would return the value in clear),
        // so it is readable:false, and access:'masked' tells the client why.
        Helper.ConfigureOpenMode();
        Helper.SetApiRouting("Bcmag Api Routing"::Prefer);
        Helper.SetFieldPolicyMode("Bcmag Field Policy Mode"::ByClassification);
        FieldRec.SetRange(TableNo, Database::Customer);
        FieldRec.SetRange(FieldName, 'Name');
        FieldRec.FindFirst();
        Helper.SetFieldAccess(Database::Customer, FieldRec."No.", "Bcmag Read Access"::Masked, 'PARTIAL', false);
        Api := DescribeCustomersApi();
        LibraryAssert.IsTrue(FindField(Api, 'displayName', FieldObj), 'displayName field');
        LibraryAssert.IsFalse(BoolField(FieldObj, 'readable'), 'a masked field is not readable through the API');
        LibraryAssert.IsTrue(FieldObj.Get('access', Tok), 'access must be present');
        LibraryAssert.AreEqual('masked', Tok.AsValue().AsText(), 'access');
        LibraryAssert.IsTrue(FindField(Api, 'number', FieldObj), 'number field');
        LibraryAssert.IsTrue(BoolField(FieldObj, 'readable'), 'a Clear field stays readable');
        Helper.UnexposeField(Database::Customer, FieldRec."No.");
    end;
}
