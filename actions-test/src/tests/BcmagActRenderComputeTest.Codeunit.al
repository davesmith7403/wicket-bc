codeunit 94359 "Bcmag Act Render Compute Test"
{
    // document-pdf and item-availability, the two non-mutating verbs, through the dispatcher's `action`
    // operation: a real PDF comes back as base64, the numbers match what Business Central computes, both
    // run on a read-only endpoint without a key (they run inside the forced rollback), and a report that
    // stamps No. Printed leaves no trace.
    Subtype = Test;
    TestPermissions = Disabled;

    var
        LibraryAssert: Codeunit "Library Assert";
        Helper: Codeunit "Bcmag Act Test Helper";
        PdfMagicTok: Label 'JVBERi', Locked = true; // base64 of "%PDF"

    [Test]
    procedure PostedSalesInvoicePdfComesBackAndPrintsNothing()
    var
        SalesHeader: Record "Sales Header";
        SalesInvHeader: Record "Sales Invoice Header";
        Args, Response, Value : JsonObject;
        CustNo, GLAccNo : Code[20];
        PostedNo, Base64Text : Text;
        Status, PrintedBefore : Integer;
    begin
        Helper.Initialize();
        Helper.FindSalesFixture(CustNo, GLAccNo);
        Helper.CreateSalesDoc("Sales Document Type"::Invoice, CustNo, GLAccNo, SalesHeader);
        Response := Helper.RunAction(Helper.ActionData('post-sales', SalesHeader.SystemId, Args), Helper.NewIdemKey(), Status);
        Helper.AssertOk(Status, Response, 'post the invoice to print');
        PostedNo := Helper.Txt(Helper.ValueOf(Response), 'postedInvoiceNo');
        SalesInvHeader.Get(PostedNo);
        PrintedBefore := SalesInvHeader."No. Printed";

        Clear(Args);
        Args.Add('document', 'postedSalesInvoice');
        Args.Add('no', PostedNo);
        Response := Helper.RunAction(Helper.ActionData('document-pdf', NoTarget(), Args), '', Status);

        Helper.AssertCompleted(Status, Response, 'document-pdf');
        Value := Helper.ValueOf(Response);
        LibraryAssert.AreEqual('application/pdf', Helper.Txt(Value, 'contentType'), 'contentType');
        LibraryAssert.AreEqual(PostedNo, Helper.Txt(Value, 'no'), 'no');
        LibraryAssert.IsTrue(Helper.Int(Value, 'sizeBytes') > 0, 'a non-empty PDF');
        Base64Text := Helper.Txt(Value, 'base64');
        LibraryAssert.AreEqual(PdfMagicTok, CopyStr(Base64Text, 1, StrLen(PdfMagicTok)), 'the bytes are a PDF');
        LibraryAssert.IsTrue(StrPos(Helper.Txt(Value, 'fileName'), '.pdf') > 0, 'fileName');
        SalesInvHeader.Get(PostedNo);
        LibraryAssert.AreEqual(PrintedBefore, SalesInvHeader."No. Printed", 'rendering is not printing: No. Printed is untouched');
    end;

    [Test]
    procedure QuotePdfBySystemIdRunsReadOnlyWithoutAKey()
    var
        SalesHeader: Record "Sales Header";
        Setup: Record "Bcmag Setup";
        Args, Response : JsonObject;
        CustNo, GLAccNo : Code[20];
        Status: Integer;
    begin
        Helper.Initialize();
        Helper.FindSalesFixture(CustNo, GLAccNo);
        Helper.CreateSalesDoc("Sales Document Type"::Quote, CustNo, GLAccNo, SalesHeader);
        Setup.GetSingleton();
        Setup."Read-Only Mode" := true;
        Setup."Require Key For Actions" := true;
        Setup.Modify(true);

        Args.Add('document', 'salesQuote');
        Response := Helper.RunAction(Helper.ActionData('document-pdf', SalesHeader.SystemId, Args), '', Status);

        Setup.GetSingleton();
        Setup."Read-Only Mode" := false;
        Setup."Require Key For Actions" := false;
        Setup.Modify(true);
        Helper.AssertCompleted(Status, Response, 'a quote PDF on a read-only endpoint, no key');
        LibraryAssert.AreEqual(PdfMagicTok, CopyStr(Helper.Txt(Helper.ValueOf(Response), 'base64'), 1, StrLen(PdfMagicTok)), 'the bytes are a PDF');
    end;

    [Test]
    procedure PdfOfTheWrongKindIsRefused()
    var
        SalesHeader: Record "Sales Header";
        Args, Response : JsonObject;
        CustNo, GLAccNo : Code[20];
        Status: Integer;
    begin
        Helper.Initialize();
        Helper.FindSalesFixture(CustNo, GLAccNo);
        Helper.CreateSalesDoc("Sales Document Type"::Order, CustNo, GLAccNo, SalesHeader);
        Args.Add('document', 'salesQuote');
        Response := Helper.RunAction(Helper.ActionData('document-pdf', SalesHeader.SystemId, Args), '', Status);
        Helper.AssertProblem(Status, Response, 422, 'action-failed', 'an order id under salesQuote');
        LibraryAssert.IsTrue(StrPos(Helper.Txt(Response, 'detail'), 'is not a salesQuote') > 0, 'detail says why: ' + Helper.Describe(Response));

        Clear(Args);
        Args.Add('document', 'salesWhatever');
        Args.Add('no', SalesHeader."No.");
        Response := Helper.RunAction(Helper.ActionData('document-pdf', NoTarget(), Args), '', Status);
        Helper.AssertProblem(Status, Response, 422, 'action-failed', 'an unknown document kind');
        LibraryAssert.IsTrue(StrPos(Helper.Txt(Response, 'detail'), 'postedSalesInvoice') > 0, 'detail lists the kinds: ' + Helper.Describe(Response));
    end;

    [Test]
    procedure ItemAvailabilityMatchesBusinessCentral()
    var
        Item: Record Item;
        CompanyInfo: Record "Company Information";
        AvailableToPromise: Codeunit "Available to Promise";
        Args, Response, Value : JsonObject;
        LocationCode: Code[10];
        ItemNo: Code[20];
        GrossRequirement, ScheduledReceipt, Atp : Decimal;
        Status: Integer;
    begin
        Helper.Initialize();
        Helper.FindItemFixture(ItemNo, LocationCode);
        Args.Add('itemNo', ItemNo);
        Args.Add('locationCode', LocationCode);
        Args.Add('date', Format(WorkDate(), 0, 9));
        Args.Add('quantity', 1);

        Response := Helper.RunAction(Helper.ActionData('item-availability', NoTarget(), Args), '', Status);

        Helper.AssertCompleted(Status, Response, 'item-availability');
        Value := Helper.ValueOf(Response);
        Item.Get(ItemNo);
        Item.SetRange("Location Filter", LocationCode);
        Item.SetRange("Date Filter", 0D, WorkDate());
        Item.CalcFields(Inventory);
        CompanyInfo.Get();
        Atp := AvailableToPromise.CalcQtyAvailableToPromise(Item, GrossRequirement, ScheduledReceipt, WorkDate(),
            CompanyInfo."Check-Avail. Time Bucket", CompanyInfo."Check-Avail. Period Calc.");
        LibraryAssert.AreEqual(ItemNo, Helper.Txt(Value, 'itemNo'), 'itemNo');
        LibraryAssert.AreEqual(Item.Inventory, Helper.Dec(Value, 'inventory'), 'inventory: ' + Helper.Describe(Response));
        LibraryAssert.AreEqual(GrossRequirement, Helper.Dec(Value, 'grossRequirement'), 'grossRequirement');
        LibraryAssert.AreEqual(ScheduledReceipt, Helper.Dec(Value, 'scheduledReceipt'), 'scheduledReceipt');
        LibraryAssert.AreEqual(Atp, Helper.Dec(Value, 'availableToPromise'), 'availableToPromise');
        LibraryAssert.IsTrue(Value.Contains('earliestAvailableDate'), 'quantity asks for the earliest date: ' + Helper.Describe(Response));
    end;

    [Test]
    procedure ItemAvailabilityWithoutALocationCoversAllLocations()
    var
        Item: Record Item;
        Args, Response, Value : JsonObject;
        Tok: JsonToken;
        LocationCode: Code[10];
        ItemNo: Code[20];
        Status: Integer;
    begin
        Helper.Initialize();
        Helper.FindItemFixture(ItemNo, LocationCode);
        Args.Add('itemNo', ItemNo);

        Response := Helper.RunAction(Helper.ActionData('item-availability', NoTarget(), Args), '', Status);

        Helper.AssertCompleted(Status, Response, 'item-availability, no location');
        Value := Helper.ValueOf(Response);
        Item.Get(ItemNo);
        Item.SetRange("Date Filter", 0D, WorkDate());
        Item.CalcFields(Inventory);
        LibraryAssert.AreEqual(Item.Inventory, Helper.Dec(Value, 'inventory'), 'inventory over every location: ' + Helper.Describe(Response));
        LibraryAssert.IsTrue(Value.Get('locationCode', Tok), 'locationCode present');
        LibraryAssert.IsTrue(Tok.AsValue().IsNull(), 'locationCode null = all locations');
    end;

    [Test]
    procedure ItemAvailabilityOfAnUnknownItemIsRefused()
    var
        Args, Response : JsonObject;
        Status: Integer;
    begin
        Helper.Initialize();
        Args.Add('itemNo', 'BCMAGNOSUCHITEM');
        Response := Helper.RunAction(Helper.ActionData('item-availability', NoTarget(), Args), '', Status);
        Helper.AssertProblem(Status, Response, 422, 'action-failed', 'unknown item');
        LibraryAssert.IsTrue(StrPos(Helper.Txt(Response, 'detail'), 'BCMAGNOSUCHITEM') > 0, 'detail names the item: ' + Helper.Describe(Response));
    end;

    local procedure NoTarget(): Guid
    var
        Empty: Guid;
    begin
        exit(Empty);
    end;
}
