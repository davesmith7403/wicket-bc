codeunit 94211 "Bcmag Act Release Sales Doc"
{
    // Action wrapper for `release-sales`: release a sales document through Base Application's Release
    // Sales Document (414), PerformManualRelease — the same path as the Release action on the document
    // page. It enforces the approval workflow (pending approval is refused) and prepayments (an order with
    // an unpaid prepayment becomes Pending Prepayment and is refused).
    // args:   { systemId | documentType + no }
    // result: { released: true, sourceDocumentType, sourceNo, status, changed } — status is the invariant name
    //         after the call; changed is false when the document was already released.

    trigger OnRun()
    var
        SalesHeader: Record "Sales Header";
        Ctx: Codeunit "Bcmag Invoke Context";
        Resolver: Codeunit "Bcmag Act Doc Resolver";
        ReleaseSalesDoc: Codeunit "Release Sales Document";
        Result: JsonObject;
        Before: Enum "Sales Document Status";
    begin
        Resolver.ResolveSalesHeader(Ctx.GetArgs(), SalesHeader);
        Before := SalesHeader.Status;
        ReleaseSalesDoc.PerformManualRelease(SalesHeader);
        SalesHeader.Get(SalesHeader."Document Type", SalesHeader."No.");
        Result.Add('released', true);
        Result.Add('sourceDocumentType', Resolver.SalesDocTypeName(SalesHeader."Document Type"));
        Result.Add('sourceNo', SalesHeader."No.");
        Result.Add('status', Resolver.SalesStatusName(SalesHeader.Status));
        Result.Add('changed', SalesHeader.Status <> Before);
        Ctx.SetResult(Result);
    end;
}
