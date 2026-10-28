codeunit 94201 "Bcmag Act Install"
{
    // Enrols each action wrapper in Wicket's Procedure Catalog (so `invoke` can route to it), in the
    // Action Catalog (so agents can discover it), and adds its exposure row. Everything enrols
    // DISABLED — Allow Run and Allow Invoke start false — preserving the core's deny-by-default
    // posture: installing this companion opens nothing. An admin opts in per action and per company by
    // flipping Allow Run on the Wicket Action Catalog / Procedure Catalog pages and Allow Invoke on the
    // exposure row. Enrolment is insert-only: a re-run (reinstall, upgrade, new company) never touches
    // an existing row, so an admin's explicit enable/disable choices survive re-enrolment. The one
    // exception is RefreshAll (upgrade only): it rewrites the companion-owned fields of rows that
    // already exist — Description and Wrapper Codeunit Id everywhere, plus Category, Preview Supported and
    // Args Schema on Action Catalog rows, and Is Mutating only from false to true — so documentation,
    // routing and metadata fixes reach existing tenants. It never touches Allow Run / Allow Invoke and
    // never loosens Is Mutating (a security setting since it opens Read-Only Mode).
    // Revocation has ONE canonical form: flip the Allow flag back off. Deleting a catalog/exposure row
    // is NOT durable — the next re-enrolment re-inserts it (disabled), so a deletion only looks revoked.
    Subtype = Install;

    var
        PostCategoryTok: Label 'post', Locked = true;
        ReleaseCategoryTok: Label 'release', Locked = true;
        ConvertCategoryTok: Label 'convert', Locked = true;
        RenderCategoryTok: Label 'render', Locked = true;
        ComputeCategoryTok: Label 'compute', Locked = true;

    trigger OnInstallAppPerCompany()
    begin
        EnrolAll();
    end;

    // Shared by install (this trigger), upgrade (Bcmag Act Upgrade — enrols actions added in later
    // versions) and new-company seeding (Bcmag Act New Company). Enrols into the current company.
    procedure EnrolAll()
    begin
        EnrolAllForCompany(CompanyName());
    end;

    // Cross-company variant for the Company OnAfterInsertEvent subscriber, which fires in whatever
    // company the operator happens to be in when the new company row is inserted.
    procedure EnrolAllForCompany(TargetCompany: Text)
    begin
        Enrolment(TargetCompany, false);
    end;

    // Upgrade path: enrol what is missing AND refresh the companion-owned fields of existing rows.
    procedure RefreshAll()
    begin
        Enrolment(CompanyName(), true);
    end;

    local procedure Enrolment(TargetCompany: Text; Refresh: Boolean)
    begin
        // Low-level invoke enrolment (raw codeunit id) …
        Enrol(TargetCompany, Codeunit::"Bcmag Act Post Sales Doc", 'PostSalesDocument',
            'Post a sales document via Sales-Post. args: { systemId | documentType+no, ship?, invoice?, receive? }; return order defaults to receive+invoice. For credit memo/return order, postedInvoiceNo is the posted credit memo no.', Refresh);
        Enrol(TargetCompany, Codeunit::"Bcmag Act Post Purchase Doc", 'PostPurchaseDocument',
            'Post a purchase document via Purch.-Post. args: { systemId | documentType+no, receive?, invoice?, ship? }; return order defaults to ship+invoice. For credit memo/return order, postedInvoiceNo is the posted credit memo no.', Refresh);
        Enrol(TargetCompany, Codeunit::"Bcmag Act Post Gen Journal", 'PostGeneralJournal',
            'Post a general/payment/cash-receipt journal batch via Gen. Jnl.-Post Batch. args: { template, batch }', Refresh);
        Enrol(TargetCompany, Codeunit::"Bcmag Act Post Item Journal", 'PostItemJournal',
            'Post an item journal batch via Item Jnl.-Post Batch. args: { template, batch }', Refresh);
        Enrol(TargetCompany, Codeunit::"Bcmag Act Release Sales Doc", 'ReleaseSalesDocument',
            'Release a sales document (approval and prepayment rules apply). args: { systemId | documentType+no }', Refresh);
        Enrol(TargetCompany, Codeunit::"Bcmag Act Reopen Sales Doc", 'ReopenSalesDocument',
            'Reopen a released sales document. args: { systemId | documentType+no }', Refresh);
        Enrol(TargetCompany, Codeunit::"Bcmag Act Release Purch Doc", 'ReleasePurchaseDocument',
            'Release a purchase document (approval and prepayment rules apply). args: { systemId | documentType+no }', Refresh);
        Enrol(TargetCompany, Codeunit::"Bcmag Act Reopen Purch Doc", 'ReopenPurchaseDocument',
            'Reopen a released purchase document. args: { systemId | documentType+no }', Refresh);
        Enrol(TargetCompany, Codeunit::"Bcmag Act Sales Quote To Order", 'MakeOrderFromQuote',
            'Convert a sales quote into an order (the quote is deleted). args: { systemId | no }', Refresh);
        Enrol(TargetCompany, Codeunit::"Bcmag Act Sales Quote To Inv", 'MakeInvoiceFromQuote',
            'Convert a sales quote into an invoice (the quote is deleted). args: { systemId | no }', Refresh);
        Enrol(TargetCompany, Codeunit::"Bcmag Act Purch Quote To Order", 'MakePurchaseOrderFromQuote',
            'Convert a purchase quote into an order (the quote is deleted). args: { systemId | no }', Refresh);
        Enrol(TargetCompany, Codeunit::"Bcmag Act Document Pdf", 'DocumentPdf',
            'Render a document as the PDF its Print action produces (base64). Through invoke this runs outside the action rollback, so a report that stamps No. Printed does so; prefer the document-pdf action. args: { document, systemId | no }', Refresh);
        Enrol(TargetCompany, Codeunit::"Bcmag Act Item Availability", 'ItemAvailability',
            'Inventory, demand, supply and quantity available to promise for an item. args: { itemNo, locationCode?, variantCode?, date?, quantity? }', Refresh);

        // … and the high-level named actions an agent discovers via capabilities.actions and calls
        // through the `action` operation (target.systemId is merged into the wrapper args).
        EnrolAction(TargetCompany, 'post-sales', Codeunit::"Bcmag Act Post Sales Doc", PostCategoryTok, true, true,
            'Post a sales document; preview: true returns the entries it would create. target: { systemId } or args: { documentType, no }; args: { ship?, invoice?, receive? } (return order: receive+invoice). Credit memo/return order: postedInvoiceNo = posted credit memo no.',
            SalesDocArgsSchema(), Refresh);
        EnrolAction(TargetCompany, 'post-purchase', Codeunit::"Bcmag Act Post Purchase Doc", PostCategoryTok, true, true,
            'Post a purchase document; preview: true returns the entries it would create. target: { systemId } or args: { documentType, no }; args: { receive?, invoice?, ship? } (return order: ship+invoice). Credit memo/return order: postedInvoiceNo = posted credit memo no.',
            PurchaseDocArgsSchema(), Refresh);
        EnrolAction(TargetCompany, 'post-gen-journal', Codeunit::"Bcmag Act Post Gen Journal", PostCategoryTok, true, true,
            'Post a general/payment/cash-receipt journal batch; preview: true returns the entries it would create. args: { template, batch }',
            JournalBatchArgsSchema(), Refresh);
        EnrolAction(TargetCompany, 'post-item-journal', Codeunit::"Bcmag Act Post Item Journal", PostCategoryTok, true, true,
            'Post an item journal batch; preview: true returns the entries it would create. args: { template, batch }',
            JournalBatchArgsSchema(), Refresh);
        EnrolAction(TargetCompany, 'release-sales', Codeunit::"Bcmag Act Release Sales Doc", ReleaseCategoryTok, true, false,
            'Release a sales document, as the Release action on its page (approval and prepayment rules apply). target: { systemId } or args: { documentType, no }.',
            DocAddressArgsSchema('Sales Header'), Refresh);
        EnrolAction(TargetCompany, 'reopen-sales', Codeunit::"Bcmag Act Reopen Sales Doc", ReleaseCategoryTok, true, false,
            'Reopen a released sales document so it can be edited (refused while approval is pending). target: { systemId } or args: { documentType, no }.',
            DocAddressArgsSchema('Sales Header'), Refresh);
        EnrolAction(TargetCompany, 'release-purchase', Codeunit::"Bcmag Act Release Purch Doc", ReleaseCategoryTok, true, false,
            'Release a purchase document, as the Release action on its page (approval and prepayment rules apply). target: { systemId } or args: { documentType, no }.',
            DocAddressArgsSchema('Purchase Header'), Refresh);
        EnrolAction(TargetCompany, 'reopen-purchase', Codeunit::"Bcmag Act Reopen Purch Doc", ReleaseCategoryTok, true, false,
            'Reopen a released purchase document so it can be edited (refused while approval is pending). target: { systemId } or args: { documentType, no }.',
            DocAddressArgsSchema('Purchase Header'), Refresh);
        EnrolAction(TargetCompany, 'make-order-from-quote', Codeunit::"Bcmag Act Sales Quote To Order", ConvertCategoryTok, true, false,
            'Convert a sales quote into a sales order, as Make Order on the quote; the quote is deleted. Refused for a quote linked to an opportunity in progress. target: { systemId } or args: { no }.',
            QuoteArgsSchema('Sales Header'), Refresh);
        EnrolAction(TargetCompany, 'make-invoice-from-quote', Codeunit::"Bcmag Act Sales Quote To Inv", ConvertCategoryTok, true, false,
            'Convert a sales quote into a sales invoice, as Make Invoice on the quote; the quote is deleted. target: { systemId } or args: { no }.',
            QuoteArgsSchema('Sales Header'), Refresh);
        EnrolAction(TargetCompany, 'make-purchase-order-from-quote', Codeunit::"Bcmag Act Purch Quote To Order", ConvertCategoryTok, true, false,
            'Convert a purchase quote into a purchase order, as Make Order on the quote; the quote is deleted. target: { systemId } or args: { no }.',
            QuoteArgsSchema('Purchase Header'), Refresh);
        EnrolAction(TargetCompany, 'document-pdf', Codeunit::"Bcmag Act Document Pdf", RenderCategoryTok, false, false,
            'The PDF a person gets from the document''s Print action (report chosen by Report Selections), base64, up to 10 MB. Changes nothing. args: { document, systemId | no }.',
            DocumentPdfArgsSchema(), Refresh);
        EnrolAction(TargetCompany, 'item-availability', Codeunit::"Bcmag Act Item Availability", ComputeCategoryTok, false, false,
            'Inventory, gross requirement, scheduled receipt and quantity available to promise at a date, per location and variant; with quantity, the earliest date it is available. Changes nothing.',
            ItemAvailabilityArgsSchema(), Refresh);
    end;

    // ---- args schemas (JSON Schema subset, surfaced as capabilities.actions[].argsSchema) ----------

    local procedure SalesDocArgsSchema(): Text
    begin
        exit('{"type":"object","properties":{' +
            '"systemId":{"type":"string","format":"uuid","description":"The Sales Header SystemId; or send target.systemId"},' +
            '"documentType":{"type":"string","enum":["Order","Invoice","Credit Memo","Return Order"],"description":"With no, instead of systemId"},' +
            '"no":{"type":"string","maxLength":20},' +
            '"ship":{"type":"boolean","description":"Default true (false on a return order)"},' +
            '"invoice":{"type":"boolean","description":"Default true"},' +
            '"receive":{"type":"boolean","description":"Default true on a return order, else false"}},' +
            '"oneOf":[{"required":["systemId"]},{"required":["documentType","no"]}]}');
    end;

    local procedure PurchaseDocArgsSchema(): Text
    begin
        exit('{"type":"object","properties":{' +
            '"systemId":{"type":"string","format":"uuid","description":"The Purchase Header SystemId; or send target.systemId"},' +
            '"documentType":{"type":"string","enum":["Order","Invoice","Credit Memo","Return Order"],"description":"With no, instead of systemId"},' +
            '"no":{"type":"string","maxLength":20},' +
            '"receive":{"type":"boolean","description":"Default true (false on a return order)"},' +
            '"invoice":{"type":"boolean","description":"Default true"},' +
            '"ship":{"type":"boolean","description":"Default true on a return order, else false"}},' +
            '"oneOf":[{"required":["systemId"]},{"required":["documentType","no"]}]}');
    end;

    local procedure DocAddressArgsSchema(HeaderTable: Text): Text
    begin
        exit('{"type":"object","properties":{' +
            '"systemId":{"type":"string","format":"uuid","description":"The ' + HeaderTable + ' SystemId; or send target.systemId"},' +
            '"documentType":{"type":"string","enum":["Quote","Order","Invoice","Credit Memo","Blanket Order","Return Order"],"description":"With no, instead of systemId"},' +
            '"no":{"type":"string","maxLength":20}},' +
            '"oneOf":[{"required":["systemId"]},{"required":["documentType","no"]}]}');
    end;

    local procedure QuoteArgsSchema(HeaderTable: Text): Text
    begin
        exit('{"type":"object","properties":{' +
            '"systemId":{"type":"string","format":"uuid","description":"The quote''s ' + HeaderTable + ' SystemId; or send target.systemId"},' +
            '"no":{"type":"string","maxLength":20,"description":"The quote no., instead of systemId"}},' +
            '"oneOf":[{"required":["systemId"]},{"required":["no"]}]}');
    end;

    local procedure DocumentPdfArgsSchema(): Text
    begin
        exit('{"type":"object","properties":{' +
            '"document":{"type":"string","enum":["salesQuote","salesOrder","salesInvoice","postedSalesInvoice","postedSalesCreditMemo","postedSalesShipment","purchaseQuote","purchaseOrder","postedPurchaseInvoice","postedPurchaseCreditMemo"]},' +
            '"systemId":{"type":"string","format":"uuid","description":"The document''s SystemId; or send target.systemId"},' +
            '"no":{"type":"string","maxLength":20,"description":"The document no., instead of systemId"}},' +
            '"required":["document"],"oneOf":[{"required":["systemId"]},{"required":["no"]}]}');
    end;

    local procedure ItemAvailabilityArgsSchema(): Text
    begin
        exit('{"type":"object","properties":{' +
            '"itemNo":{"type":"string","maxLength":20},' +
            '"locationCode":{"type":"string","maxLength":10,"description":"Omit for all locations; \"\" for the blank location"},' +
            '"variantCode":{"type":"string","maxLength":10,"description":"Omit for all variants; \"\" for the blank variant"},' +
            '"date":{"type":"string","format":"date","description":"Availability date; default the work date"},' +
            '"quantity":{"type":"number","description":"Also return the earliest date this quantity is available"}},' +
            '"required":["itemNo"]}');
    end;

    local procedure JournalBatchArgsSchema(): Text
    begin
        exit('{"type":"object","properties":{' +
            '"template":{"type":"string","maxLength":10,"description":"Journal Template Name"},' +
            '"batch":{"type":"string","maxLength":10,"description":"Journal Batch Name"}},' +
            '"required":["template","batch"]}');
    end;

    local procedure EnrolAction(TargetCompany: Text; ActionCode: Code[50]; WrapperId: Integer; Category: Text[50]; NewIsMutating: Boolean; PreviewSupported: Boolean; Description: Text; ArgsSchema: Text; Refresh: Boolean)
    var
        Catalog: Record "Bcmag Action Catalog";
        IsMutating: Boolean;
    begin
        IsMutating := NewIsMutating;
        Catalog.ChangeCompany(TargetCompany);
        if Catalog.Get(ActionCode) then begin
            // Existing row: the admin's Allow Run is never touched. On upgrade only, the companion-owned
            // routing, documentation and metadata are brought up to date — except that Is Mutating may only
            // be tightened: Is Mutating = false lets a verb through Read-Only Mode without a key, so an
            // administrator who set it to true (to keep, say, document-pdf off a read-only endpoint) keeps
            // that choice across upgrades.
            IsMutating := IsMutating or Catalog."Is Mutating";
            if Refresh then
                if StaleAction(Catalog, WrapperId, Category, IsMutating, PreviewSupported, Description, ArgsSchema) then begin
                    SetActionFields(Catalog, WrapperId, Category, IsMutating, PreviewSupported, Description, ArgsSchema);
                    Catalog.Modify();
                end;
            exit;
        end;
        Catalog.Init();
        Catalog."Action Code" := ActionCode;
        SetActionFields(Catalog, WrapperId, Category, IsMutating, PreviewSupported, Description, ArgsSchema);
        Catalog."Allow Run" := false; // deny-by-default: an admin enables per action on the Action Catalog page
        Catalog.Insert();
    end;

    local procedure StaleAction(var Catalog: Record "Bcmag Action Catalog"; WrapperId: Integer; Category: Text[50]; IsMutating: Boolean; PreviewSupported: Boolean; Description: Text; ArgsSchema: Text): Boolean
    begin
        exit((Catalog."Wrapper Codeunit Id" <> WrapperId) or
            (Catalog.Category <> Category) or
            (Catalog."Is Mutating" <> IsMutating) or
            (Catalog."Preview Supported" <> PreviewSupported) or
            (Catalog.Description <> CopyStr(Description, 1, MaxStrLen(Catalog.Description))) or
            (Catalog.GetArgsSchema() <> ArgsSchema));
    end;

    local procedure SetActionFields(var Catalog: Record "Bcmag Action Catalog"; WrapperId: Integer; Category: Text[50]; IsMutating: Boolean; PreviewSupported: Boolean; Description: Text; ArgsSchema: Text)
    begin
        Catalog."Wrapper Codeunit Id" := WrapperId;
        Catalog.Category := Category;
        Catalog."Is Mutating" := IsMutating;
        Catalog."Preview Supported" := PreviewSupported;
        Catalog.Description := CopyStr(Description, 1, MaxStrLen(Catalog.Description));
        Catalog.SetArgsSchema(ArgsSchema);
    end;

    local procedure Enrol(TargetCompany: Text; WrapperId: Integer; ProcedureName: Text; Description: Text; Refresh: Boolean)
    var
        Catalog: Record "Bcmag Procedure Catalog";
        Exposure: Record "Bcmag Exposure";
    begin
        Catalog.ChangeCompany(TargetCompany);
        Exposure.ChangeCompany(TargetCompany);
        // The wrapper is addressed directly, so Logical Codeunit Id = Wrapper Codeunit Id.
        // Both inserts are insert-only: an existing row — and the admin's Allow flags on it — is kept.
        if not Catalog.Get(WrapperId, ProcedureName) then begin
            Catalog.Init();
            Catalog."Logical Codeunit Id" := WrapperId;
            Catalog."Procedure Name" := CopyStr(ProcedureName, 1, MaxStrLen(Catalog."Procedure Name"));
            Catalog."Wrapper Codeunit Id" := WrapperId;
            Catalog."Return Shape" := Catalog."Return Shape"::json;
            Catalog."Allow Run" := false; // deny-by-default: an admin enables per procedure and company
            Catalog.Description := CopyStr(Description, 1, MaxStrLen(Catalog.Description));
            Catalog.Insert();
        end else
            // Existing row: Allow Run stays the admin's; on upgrade the companion-owned fields refresh.
            if Refresh then
                if (Catalog."Wrapper Codeunit Id" <> WrapperId) or (Catalog.Description <> CopyStr(Description, 1, MaxStrLen(Catalog.Description))) then begin
                    Catalog."Wrapper Codeunit Id" := WrapperId;
                    Catalog.Description := CopyStr(Description, 1, MaxStrLen(Catalog.Description));
                    Catalog.Modify();
                end;

        if not Exposure.Get(Exposure."Object Type"::Codeunit, WrapperId) then begin
            Exposure.Init();
            Exposure."Object Type" := Exposure."Object Type"::Codeunit;
            Exposure."Object Id" := WrapperId;
            Exposure."Allow Read" := false; // Init() picks up InitValue=true; read is meaningless on a codeunit row
            Exposure."Allow Invoke" := false; // deny-by-default: an admin opens the wrapper explicitly
            Exposure.Description := CopyStr('Wicket Actions companion', 1, MaxStrLen(Exposure.Description));
            Exposure.Insert();
        end;
    end;
}
