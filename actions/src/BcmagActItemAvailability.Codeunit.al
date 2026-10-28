codeunit 94219 "Bcmag Act Item Availability"
{
    // Action wrapper for `item-availability` (non-mutating, category compute): the numbers order promising
    // works from, which no query can give because Business Central computes them — inventory, gross
    // requirement (open demand), scheduled receipt (open supply) and the quantity available to promise at
    // a date, per location and variant, through Base Application's Available to Promise (5790) with the
    // company's Check-Avail. period and time bucket (as Capable to Promise calls it). With a quantity it
    // also answers the earliest date that quantity is available. Enrolled non-mutating: runs inside the
    // action op's forced rollback.
    // args:   { itemNo, locationCode?, variantCode?, date? (yyyy-mm-dd, default today's work date), quantity? }
    //         An omitted location or variant means all of them (no filter); "" means the blank one.
    // result: { itemNo, description, baseUnitOfMeasure, locationCode, variantCode, date, inventory,
    //           grossRequirement, scheduledReceipt, availableToPromise, quantity?, earliestAvailableDate? }
    //         locationCode / variantCode are null when the call covered all of them.
    //         earliestAvailableDate is null when the quantity is not available within the look-ahead period.

    trigger OnRun()
    var
        Item: Record Item;
        CompanyInfo: Record "Company Information";
        Ctx: Codeunit "Bcmag Invoke Context";
        Helper: Codeunit "Bcmag Act Helper";
        AvailableToPromise: Codeunit "Available to Promise";
        Args, Result : JsonObject;
        ItemNo, LocationCode, VariantCode, DateTxt, QtyTxt : Text;
        HasLocation, HasVariant : Boolean;
        AvailabilityDate, EarliestDate : Date;
        GrossRequirement, ScheduledReceipt, Atp, Quantity, AvailableQty : Decimal;
    begin
        Args := Ctx.GetArgs();
        ItemNo := Helper.RequireText(Args, 'itemNo');
        HasLocation := IsPresent(Args, 'locationCode', LocationCode);
        HasVariant := IsPresent(Args, 'variantCode', VariantCode);
        if StrLen(ItemNo) > MaxStrLen(Item."No.") then
            Error('args.itemNo must be at most %1 characters', MaxStrLen(Item."No."));
        if StrLen(LocationCode) > 10 then
            Error('args.locationCode must be at most 10 characters');
        if StrLen(VariantCode) > 10 then
            Error('args.variantCode must be at most 10 characters');
        if not Item.Get(ItemNo) then
            Error('no item "%1"', ItemNo);
        AvailabilityDate := WorkDate();
        if Helper.GetText(Args, 'date', DateTxt) then
            if not Evaluate(AvailabilityDate, DateTxt, 9) then
                Error('args.date "%1" is not a date (yyyy-mm-dd)', DateTxt);

        CompanyInfo.Get();
        if HasLocation then
            Item.SetRange("Location Filter", LocationCode);
        if HasVariant then
            Item.SetRange("Variant Filter", VariantCode);
        Item.SetRange("Date Filter", 0D, AvailabilityDate);
        Item.CalcFields(Inventory);
        Atp := AvailableToPromise.CalcQtyAvailableToPromise(Item, GrossRequirement, ScheduledReceipt, AvailabilityDate,
            CompanyInfo."Check-Avail. Time Bucket", CompanyInfo."Check-Avail. Period Calc.");

        Result.Add('itemNo', Item."No.");
        Result.Add('description', Item.Description);
        Result.Add('baseUnitOfMeasure', Item."Base Unit of Measure");
        if HasLocation then
            Result.Add('locationCode', LocationCode)
        else
            Result.Add('locationCode', NullValue());
        if HasVariant then
            Result.Add('variantCode', VariantCode)
        else
            Result.Add('variantCode', NullValue());
        Result.Add('date', Format(AvailabilityDate, 0, 9));
        Result.Add('inventory', Item.Inventory);
        Result.Add('grossRequirement', GrossRequirement);
        Result.Add('scheduledReceipt', ScheduledReceipt);
        Result.Add('availableToPromise', Atp);

        if Helper.GetText(Args, 'quantity', QtyTxt) then begin
            if not Evaluate(Quantity, QtyTxt, 9) then
                Error('args.quantity "%1" is not a number', QtyTxt);
            EarliestDate := AvailableToPromise.CalcEarliestAvailabilityDate(Item, Quantity, AvailabilityDate, 0, 0D, AvailableQty,
                CompanyInfo."Check-Avail. Time Bucket", CompanyInfo."Check-Avail. Period Calc.");
            Result.Add('quantity', Quantity);
            if EarliestDate = 0D then
                Result.Add('earliestAvailableDate', NullValue())
            else
                Result.Add('earliestAvailableDate', Format(EarliestDate, 0, 9));
        end;
        Ctx.SetResult(Result);
    end;

    // Present = the member exists with a non-null scalar, including "" (the blank location or variant).
    local procedure IsPresent(Args: JsonObject; Name: Text; var Value: Text): Boolean
    var
        Tok: JsonToken;
    begin
        Value := '';
        if not Args.Get(Name, Tok) then
            exit(false);
        if not Tok.IsValue() then
            exit(false);
        if Tok.AsValue().IsNull() then
            exit(false);
        Value := Tok.AsValue().AsText();
        exit(true);
    end;

    local procedure NullValue() Value: JsonValue
    begin
        Value.SetValueToNull();
    end;
}
