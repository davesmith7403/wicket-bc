codeunit 94209 "Bcmag Act Doc Resolver"
{
    // Shared document addressing for the release/reopen, quote-conversion and document-PDF wrappers: a header by
    // args.systemId (preferred; target.systemId arrives here) or by documentType + no, with invariant
    // document type names. Sales and purchase keep separate typed procedures: the two document type enums
    // share no interface, so one signature would have to trade in raw ordinals. The posting wrappers keep
    // their own copies, which predate this codeunit.

    var
        Helper: Codeunit "Bcmag Act Helper";

    procedure ResolveSalesHeader(Args: JsonObject; var SalesHeader: Record "Sales Header")
    var
        SysIdTxt, NoTxt, DocTypeTxt : Text;
        SysId: Guid;
    begin
        if Helper.GetText(Args, 'systemId', SysIdTxt) then begin
            if not Evaluate(SysId, SysIdTxt) then
                Error('args.systemId "%1" is not a valid GUID', SysIdTxt);
            if not SalesHeader.GetBySystemId(SysId) then
                Error('no sales header with systemId %1', SysIdTxt);
            exit;
        end;
        if Helper.GetText(Args, 'no', NoTxt) then begin
            // Never default the type: "no." series can collide across document types.
            if not Helper.GetText(Args, 'documentType', DocTypeTxt) then
                Error('documentType is required when addressing by no.');
            if StrLen(NoTxt) > MaxStrLen(SalesHeader."No.") then
                Error('args.no must be at most %1 characters', MaxStrLen(SalesHeader."No."));
            if not SalesHeader.Get(ParseSalesDocType(DocTypeTxt), NoTxt) then
                Error('no sales header %1 "%2"', DocTypeTxt, NoTxt);
            exit;
        end;
        Error('provide args.systemId, or args.documentType + args.no');
    end;

    procedure ResolvePurchaseHeader(Args: JsonObject; var PurchHeader: Record "Purchase Header")
    var
        SysIdTxt, NoTxt, DocTypeTxt : Text;
        SysId: Guid;
    begin
        if Helper.GetText(Args, 'systemId', SysIdTxt) then begin
            if not Evaluate(SysId, SysIdTxt) then
                Error('args.systemId "%1" is not a valid GUID', SysIdTxt);
            if not PurchHeader.GetBySystemId(SysId) then
                Error('no purchase header with systemId %1', SysIdTxt);
            exit;
        end;
        if Helper.GetText(Args, 'no', NoTxt) then begin
            if not Helper.GetText(Args, 'documentType', DocTypeTxt) then
                Error('documentType is required when addressing by no.');
            if StrLen(NoTxt) > MaxStrLen(PurchHeader."No.") then
                Error('args.no must be at most %1 characters', MaxStrLen(PurchHeader."No."));
            if not PurchHeader.Get(ParsePurchaseDocType(DocTypeTxt), NoTxt) then
                Error('no purchase header %1 "%2"', DocTypeTxt, NoTxt);
            exit;
        end;
        Error('provide args.systemId, or args.documentType + args.no');
    end;

    // A sales quote by systemId or by no (the type is implied). A systemId naming another document type
    // is refused rather than converted.
    procedure ResolveQuote(Args: JsonObject; var SalesHeader: Record "Sales Header")
    var
        NoTxt: Text;
    begin
        if not Helper.GetText(Args, 'systemId', NoTxt) then
            if Helper.GetText(Args, 'no', NoTxt) then
                if not Args.Contains('documentType') then
                    Args.Add('documentType', 'Quote');
        ResolveSalesHeader(Args, SalesHeader);
        if SalesHeader."Document Type" <> SalesHeader."Document Type"::Quote then
            Error('sales document %1 %2 is not a quote', SalesDocTypeName(SalesHeader."Document Type"), SalesHeader."No.");
    end;

    procedure ResolvePurchaseQuote(Args: JsonObject; var PurchHeader: Record "Purchase Header")
    var
        NoTxt: Text;
    begin
        if not Helper.GetText(Args, 'systemId', NoTxt) then
            if Helper.GetText(Args, 'no', NoTxt) then
                if not Args.Contains('documentType') then
                    Args.Add('documentType', 'Quote');
        ResolvePurchaseHeader(Args, PurchHeader);
        if PurchHeader."Document Type" <> PurchHeader."Document Type"::Quote then
            Error('purchase document %1 %2 is not a quote', PurchaseDocTypeName(PurchHeader."Document Type"), PurchHeader."No.");
    end;

    // Lower-case, braceless: the spelling query rows carry in @systemId.
    procedure GuidText(Value: Guid): Text
    begin
        exit(LowerCase(DelChr(Format(Value, 0, 4), '=', '{}')));
    end;

    procedure ParseSalesDocType(Input: Text): Enum "Sales Document Type"
    begin
        case NormalizeDocType(Input) of
            'quote':
                exit(Enum::"Sales Document Type"::Quote);
            'order':
                exit(Enum::"Sales Document Type"::Order);
            'invoice':
                exit(Enum::"Sales Document Type"::Invoice);
            'creditmemo':
                exit(Enum::"Sales Document Type"::"Credit Memo");
            'blanketorder':
                exit(Enum::"Sales Document Type"::"Blanket Order");
            'returnorder':
                exit(Enum::"Sales Document Type"::"Return Order");
        end;
        Error('unknown documentType "%1" (use Quote/Order/Invoice/Credit Memo/Blanket Order/Return Order)', Input);
    end;

    procedure ParsePurchaseDocType(Input: Text): Enum "Purchase Document Type"
    begin
        case NormalizeDocType(Input) of
            'quote':
                exit(Enum::"Purchase Document Type"::Quote);
            'order':
                exit(Enum::"Purchase Document Type"::Order);
            'invoice':
                exit(Enum::"Purchase Document Type"::Invoice);
            'creditmemo':
                exit(Enum::"Purchase Document Type"::"Credit Memo");
            'blanketorder':
                exit(Enum::"Purchase Document Type"::"Blanket Order");
            'returnorder':
                exit(Enum::"Purchase Document Type"::"Return Order");
        end;
        Error('unknown documentType "%1" (use Quote/Order/Invoice/Credit Memo/Blanket Order/Return Order)', Input);
    end;

    // Invariant enum names — never Format() an enum into a machine identifier (locale-dependent).
    procedure SalesDocTypeName(DocType: Enum "Sales Document Type"): Text
    begin
        exit(DocType.Names().Get(DocType.Ordinals().IndexOf(DocType.AsInteger())));
    end;

    procedure PurchaseDocTypeName(DocType: Enum "Purchase Document Type"): Text
    begin
        exit(DocType.Names().Get(DocType.Ordinals().IndexOf(DocType.AsInteger())));
    end;

    procedure SalesStatusName(Status: Enum "Sales Document Status"): Text
    begin
        exit(Status.Names().Get(Status.Ordinals().IndexOf(Status.AsInteger())));
    end;

    procedure PurchaseStatusName(Status: Enum "Purchase Document Status"): Text
    begin
        exit(Status.Names().Get(Status.Ordinals().IndexOf(Status.AsInteger())));
    end;

    local procedure NormalizeDocType(Input: Text): Text
    begin
        exit(DelChr(LowerCase(Input), '=', ' '));
    end;
}
