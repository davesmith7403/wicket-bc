codeunit 94213 "Bcmag Act Release Purch Doc"
{
    // Action wrapper for `release-purchase`: release a purchase document through Base Application's
    // Release Purchase Document (415), PerformManualRelease — the same path as the Release action on the
    // document page. It enforces the approval workflow and prepayments, as on the page.
    // args:   { systemId | documentType + no }
    // result: { released: true, sourceDocumentType, sourceNo, status, changed } — status is the invariant name
    //         after the call; changed is false when the document was already released.

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
        ReleasePurchDoc.PerformManualRelease(PurchHeader);
        PurchHeader.Get(PurchHeader."Document Type", PurchHeader."No.");
        Result.Add('released', true);
        Result.Add('sourceDocumentType', Resolver.PurchaseDocTypeName(PurchHeader."Document Type"));
        Result.Add('sourceNo', PurchHeader."No.");
        Result.Add('status', Resolver.PurchaseStatusName(PurchHeader.Status));
        Result.Add('changed', PurchHeader.Status <> Before);
        Ctx.SetResult(Result);
    end;
}
