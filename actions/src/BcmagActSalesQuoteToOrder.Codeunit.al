codeunit 94215 "Bcmag Act Sales Quote To Order"
{
    // Action wrapper for `make-order-from-quote`: convert a sales quote into an order through Base
    // Application's Sales-Quote to Order (86), the engine behind the quote page's Make Order action. It
    // checks the customer (blocked, credit limit), copies the lines, archives the quote when the setup
    // says so and DELETES the quote. A quote linked to an in-progress opportunity is refused up front:
    // 86 would open the Close Opportunity page there, which a headless session cannot show.
    // args:   { systemId | no }  (documentType is implied: Quote)
    // result: { converted: true, sourceDocumentType: "Quote", sourceNo, quoteDeleted, createdDocumentType: "Order",
    //           createdNo, createdSystemId }

    trigger OnRun()
    var
        QuoteHeader, OrderHeader : Record "Sales Header";
        Opportunity: Record Opportunity;
        Ctx: Codeunit "Bcmag Invoke Context";
        Resolver: Codeunit "Bcmag Act Doc Resolver";
        SalesQuoteToOrder: Codeunit "Sales-Quote to Order";
        Args, Result : JsonObject;
        QuoteNo: Code[20];
    begin
        Args := Ctx.GetArgs();
        Resolver.ResolveQuote(Args, QuoteHeader);
        QuoteNo := QuoteHeader."No.";
        // The same filter 86 applies before it opens the Close Opportunity page (FilterOpportunityForQuote,
        // local to 86 in 28.x).
        Opportunity.SetCurrentKey("Sales Document Type", "Sales Document No.");
        Opportunity.SetRange("Sales Document Type", Opportunity."Sales Document Type"::Quote);
        Opportunity.SetRange("Sales Document No.", QuoteNo);
        Opportunity.SetRange(Status, Opportunity.Status::"In Progress");
        if not Opportunity.IsEmpty() then
            Error('sales quote %1 is linked to an opportunity in progress; close or update the opportunity in Business Central first', QuoteNo);

        SalesQuoteToOrder.Run(QuoteHeader);
        SalesQuoteToOrder.GetSalesOrderHeader(OrderHeader);

        Result.Add('converted', true);
        Result.Add('sourceDocumentType', 'Quote');
        Result.Add('sourceNo', QuoteNo);
        Result.Add('quoteDeleted', not QuoteHeader.Get(QuoteHeader."Document Type"::Quote, QuoteNo));
        Result.Add('createdDocumentType', 'Order');
        Result.Add('createdNo', OrderHeader."No.");
        Result.Add('createdSystemId', Resolver.GuidText(OrderHeader.SystemId));
        Ctx.SetResult(Result);
    end;
}
