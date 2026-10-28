codeunit 94214 "Bcmag Act Reopen Purch Doc"
{
    // Action wrapper for `reopen-purchase`: reopen a released purchase document through Base Application's
    // Release Purchase Document (415), PerformManualReopen — the same path as the Reopen action on the
    // document page. A document pending approval is refused: cancel or complete the approval first.
    // args:   { systemId | documentType + no }
    // result: { reopened: true, sourceDocumentType, sourceNo, status, changed } — status is the invariant name
    //         after the call; changed is false when the document was already open.

    trigger OnRun()
    var
        PurchHeader: Record "Purchase Header";
        Ctx: Codeunit "Bcmag Invoke Context";
        Resolver: Codeunit "Bcmag Act Doc Resolver";
        ReleasePurchDoc: Codeunit "Release Purchase Document";
        Result: JsonObject;
        Before: Enum "Purchase Document Status";
    begin
        Resolver.ResolvePurchaseHeader(Ctx.GetArgs(), PurchHeader);
        Before := PurchHeader.Status;
        ReleasePurchDoc.PerformManualReopen(PurchHeader);
        PurchHeader.Get(PurchHeader."Document Type", PurchHeader."No.");
        Result.Add('reopened', true);
        Result.Add('sourceDocumentType', Resolver.PurchaseDocTypeName(PurchHeader."Document Type"));
        Result.Add('sourceNo', PurchHeader."No.");
        Result.Add('status', Resolver.PurchaseStatusName(PurchHeader.Status));
        Result.Add('changed', PurchHeader.Status <> Before);
        Ctx.SetResult(Result);
    end;
}
