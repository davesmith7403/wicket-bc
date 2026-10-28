codeunit 94358 "Bcmag Act Convert Test"
{
    // make-order-from-quote / make-invoice-from-quote / make-purchase-order-from-quote through the
    // dispatcher's `action` operation: the new document exists with the quote's lines and the quote is
    // gone; a document that is not a quote, and a quote tied to an opportunity in progress, are refused
    // with nothing changed.
    Subtype = Test;
    TestPermissions = Disabled;

    var
        LibraryAssert: Codeunit "Library Assert";
        Helper: Codeunit "Bcmag Act Test Helper";

    [Test]
    procedure SalesQuoteBecomesAnOrder()
    var
        QuoteHeader, OrderHeader : Record "Sales Header";
        SalesLine: Record "Sales Line";
        Args, Response, Value : JsonObject;
        CustNo, GLAccNo, QuoteNo : Code[20];
        Status: Integer;
    begin
        Helper.Initialize();
        Helper.FindSalesFixture(CustNo, GLAccNo);
        Helper.CreateSalesDoc("Sales Document Type"::Quote, CustNo, GLAccNo, QuoteHeader);
        QuoteNo := QuoteHeader."No.";

        Response := Helper.RunAction(Helper.ActionData('make-order-from-quote', QuoteHeader.SystemId, Args), Helper.NewIdemKey(), Status);

        Helper.AssertCompleted(Status, Response, 'quote to order');
        Value := Helper.ValueOf(Response);
        LibraryAssert.IsTrue(Helper.Bool(Value, 'converted'), 'converted: ' + Helper.Describe(Response));
        LibraryAssert.AreEqual(QuoteNo, Helper.Txt(Value, 'sourceNo'), 'sourceNo');
        LibraryAssert.AreEqual('Order', Helper.Txt(Value, 'createdDocumentType'), 'createdDocumentType');
        LibraryAssert.IsTrue(OrderHeader.Get(OrderHeader."Document Type"::Order, Helper.Txt(Value, 'createdNo')), 'createdNo names an order: ' + Helper.Describe(Response));
        LibraryAssert.AreEqual(LowerCase(DelChr(Format(OrderHeader.SystemId, 0, 4), '=', '{}')), Helper.Txt(Value, 'createdSystemId'), 'createdSystemId in @systemId spelling');
        LibraryAssert.AreEqual(CustNo, OrderHeader."Sell-to Customer No.", 'same customer');
        SalesLine.SetRange("Document Type", OrderHeader."Document Type");
        SalesLine.SetRange("Document No.", OrderHeader."No.");
        LibraryAssert.AreEqual(1, SalesLine.Count(), 'the quote line came across');
        LibraryAssert.IsTrue(Helper.Bool(Value, 'quoteDeleted'), 'quoteDeleted');
        LibraryAssert.IsFalse(QuoteHeader.Get(QuoteHeader."Document Type"::Quote, QuoteNo), 'the quote is gone');
    end;

    [Test]
    procedure SalesQuoteBecomesAnInvoiceByNo()
    var
        QuoteHeader, InvoiceHeader : Record "Sales Header";
        Args, Response, Value : JsonObject;
        CustNo, GLAccNo, QuoteNo : Code[20];
        Status: Integer;
    begin
        Helper.Initialize();
        Helper.FindSalesFixture(CustNo, GLAccNo);
        Helper.CreateSalesDoc("Sales Document Type"::Quote, CustNo, GLAccNo, QuoteHeader);
        QuoteNo := QuoteHeader."No.";
        Args.Add('no', QuoteNo);

        Response := Helper.RunAction(Helper.ActionData('make-invoice-from-quote', NoTarget(), Args), Helper.NewIdemKey(), Status);

        Helper.AssertCompleted(Status, Response, 'quote to invoice');
        Value := Helper.ValueOf(Response);
        LibraryAssert.AreEqual('Invoice', Helper.Txt(Value, 'createdDocumentType'), 'createdDocumentType');
        LibraryAssert.IsTrue(InvoiceHeader.Get(InvoiceHeader."Document Type"::Invoice, Helper.Txt(Value, 'createdNo')), 'createdNo names an invoice: ' + Helper.Describe(Response));
        LibraryAssert.IsFalse(QuoteHeader.Get(QuoteHeader."Document Type"::Quote, QuoteNo), 'the quote is gone');
    end;

    [Test]
    procedure PurchaseQuoteBecomesAnOrder()
    var
        QuoteHeader, OrderHeader : Record "Purchase Header";
        Args, Response, Value : JsonObject;
        VendNo, GLAccNo, QuoteNo : Code[20];
        Status: Integer;
    begin
        Helper.Initialize();
        Helper.FindPurchaseFixture(VendNo, GLAccNo);
        Helper.CreatePurchaseDoc("Purchase Document Type"::Quote, VendNo, GLAccNo, QuoteHeader);
        QuoteNo := QuoteHeader."No.";

        Response := Helper.RunAction(Helper.ActionData('make-purchase-order-from-quote', QuoteHeader.SystemId, Args), Helper.NewIdemKey(), Status);

        Helper.AssertCompleted(Status, Response, 'purchase quote to order');
        Value := Helper.ValueOf(Response);
        LibraryAssert.IsTrue(OrderHeader.Get(OrderHeader."Document Type"::Order, Helper.Txt(Value, 'createdNo')), 'createdNo names a purchase order: ' + Helper.Describe(Response));
        LibraryAssert.AreEqual(VendNo, OrderHeader."Buy-from Vendor No.", 'same vendor');
        LibraryAssert.IsFalse(QuoteHeader.Get(QuoteHeader."Document Type"::Quote, QuoteNo), 'the quote is gone');
    end;

    [Test]
    procedure ADocumentThatIsNotAQuoteIsRefused()
    var
        OrderHeader: Record "Sales Header";
        Args, Response : JsonObject;
        CustNo, GLAccNo : Code[20];
        Status: Integer;
    begin
        Helper.Initialize();
        Helper.FindSalesFixture(CustNo, GLAccNo);
        Helper.CreateSalesDoc("Sales Document Type"::Order, CustNo, GLAccNo, OrderHeader);

        Response := Helper.RunAction(Helper.ActionData('make-order-from-quote', OrderHeader.SystemId, Args), Helper.NewIdemKey(), Status);

        Helper.AssertProblem(Status, Response, 422, 'action-failed', 'an order is not a quote');
        LibraryAssert.IsTrue(StrPos(Helper.Txt(Response, 'detail'), 'is not a quote') > 0, 'detail says why: ' + Helper.Describe(Response));
        LibraryAssert.IsTrue(OrderHeader.Get(OrderHeader."Document Type", OrderHeader."No."), 'the order is untouched');
    end;

    [Test]
    procedure AQuoteTiedToAnOpportunityInProgressIsRefused()
    var
        QuoteHeader: Record "Sales Header";
        Opportunity: Record Opportunity;
        Args, Response : JsonObject;
        CustNo, GLAccNo : Code[20];
        Status: Integer;
    begin
        Helper.Initialize();
        Helper.FindSalesFixture(CustNo, GLAccNo);
        Helper.CreateSalesDoc("Sales Document Type"::Quote, CustNo, GLAccNo, QuoteHeader);
        Opportunity.Init();
        Opportunity."No." := CopyStr('BCMAG' + Helper.UniqueSuffix(), 1, MaxStrLen(Opportunity."No."));
        Opportunity."Sales Document Type" := Opportunity."Sales Document Type"::Quote;
        Opportunity."Sales Document No." := QuoteHeader."No.";
        Opportunity.Status := Opportunity.Status::"In Progress";
        Opportunity.Insert();

        Response := Helper.RunAction(Helper.ActionData('make-order-from-quote', QuoteHeader.SystemId, Args), Helper.NewIdemKey(), Status);

        Helper.AssertProblem(Status, Response, 422, 'action-failed', 'quote with an opportunity in progress');
        LibraryAssert.IsTrue(StrPos(Helper.Txt(Response, 'detail'), 'opportunity') > 0, 'detail names the opportunity: ' + Helper.Describe(Response));
        LibraryAssert.IsTrue(QuoteHeader.Get(QuoteHeader."Document Type", QuoteHeader."No."), 'the quote is untouched');
    end;

    local procedure NoTarget(): Guid
    var
        Empty: Guid;
    begin
        exit(Empty);
    end;
}
