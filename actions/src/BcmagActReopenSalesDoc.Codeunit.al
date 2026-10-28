codeunit 94212 "Bcmag Act Reopen Sales Doc"
{
    // Action wrapper for `reopen-sales`: reopen a released sales document through Base Application's
    // Release Sales Document (414), PerformManualReopen — the same path as the Reopen action on the
    // document page. A document pending approval is refused: cancel or complete the approval first.
    // args:   { systemId | documentType + no }
    // result: { reopened: true, sourceDocumentType, sourceNo, status, changed } — status is the invariant name
    //         after the call; changed is false when the document was already open.

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
        ReleaseSalesDoc.PerformManualReopen(SalesHeader);
        SalesHeader.Get(SalesHeader."Document Type", SalesHeader."No.");
        Result.Add('reopened', true);
        Result.Add('sourceDocumentType', Resolver.SalesDocTypeName(SalesHeader."Document Type"));
        Result.Add('sourceNo', SalesHeader."No.");
        Result.Add('status', Resolver.SalesStatusName(SalesHeader.Status));
        Result.Add('changed', SalesHeader.Status <> Before);
        Ctx.SetResult(Result);
    end;
}
