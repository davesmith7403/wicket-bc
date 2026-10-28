codeunit 94216 "Bcmag Act Sales Quote To Inv"
{
    // Action wrapper for `make-invoice-from-quote`: convert a sales quote into an invoice through Base
    // Application's Sales-Quote to Invoice (1305), the engine behind the quote page's Make Invoice action.
    // It checks the customer, copies the lines, archives the quote when the setup says so and DELETES the
    // quote.
    // args:   { systemId | no }  (documentType is implied: Quote)
    // result: { converted: true, sourceDocumentType: "Quote", sourceNo, quoteDeleted, createdDocumentType: "Invoice",
    //           createdNo, createdSystemId }

    trigger OnRun()
    var
        QuoteHeader, InvoiceHeader : Record "Sales Header";
        Ctx: Codeunit "Bcmag Invoke Context";
        Resolver: Codeunit "Bcmag Act Doc Resolver";
        SalesQuoteToInvoice: Codeunit "Sales-Quote to Invoice";
        Args, Result : JsonObject;
        QuoteNo: Code[20];
    begin
        Args := Ctx.GetArgs();
        Resolver.ResolveQuote(Args, QuoteHeader);
        QuoteNo := QuoteHeader."No.";

        SalesQuoteToInvoice.Run(QuoteHeader);
        SalesQuoteToInvoice.GetSalesInvoiceHeader(InvoiceHeader);

        Result.Add('converted', true);
        Result.Add('sourceDocumentType', 'Quote');
        Result.Add('sourceNo', QuoteNo);
        Result.Add('quoteDeleted', not QuoteHeader.Get(QuoteHeader."Document Type"::Quote, QuoteNo));
        Result.Add('createdDocumentType', 'Invoice');
        Result.Add('createdNo', InvoiceHeader."No.");
        Result.Add('createdSystemId', Resolver.GuidText(InvoiceHeader.SystemId));
        Ctx.SetResult(Result);
    end;
}
