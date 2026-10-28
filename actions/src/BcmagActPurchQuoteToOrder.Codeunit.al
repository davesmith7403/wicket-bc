codeunit 94217 "Bcmag Act Purch Quote To Order"
{
    // Action wrapper for `make-purchase-order-from-quote`: convert a purchase quote into an order through
    // Base Application's Purch.-Quote to Order (96), the engine behind the quote page's Make Order action.
    // It checks the vendor, copies the lines, archives the quote when the setup says so and DELETES the
    // quote.
    // args:   { systemId | no }  (documentType is implied: Quote)
    // result: { converted: true, sourceDocumentType: "Quote", sourceNo, quoteDeleted, createdDocumentType: "Order",
    //           createdNo, createdSystemId }

    trigger OnRun()
    var
        QuoteHeader, OrderHeader : Record "Purchase Header";
        Ctx: Codeunit "Bcmag Invoke Context";
        Resolver: Codeunit "Bcmag Act Doc Resolver";
        PurchQuoteToOrder: Codeunit "Purch.-Quote to Order";
        Args, Result : JsonObject;
        QuoteNo: Code[20];
    begin
        Args := Ctx.GetArgs();
        Resolver.ResolvePurchaseQuote(Args, QuoteHeader);
        QuoteNo := QuoteHeader."No.";

        PurchQuoteToOrder.Run(QuoteHeader);
        PurchQuoteToOrder.GetPurchOrderHeader(OrderHeader);

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
