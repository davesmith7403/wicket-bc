codeunit 94160 "Bcmag Op Batch"
{
    // "batch" operation: many inserts, modifies and deletes in one call and one transaction. data.items is
    // an array of the single-write shapes with an "op" ("insert", "modify" or "delete"); each item runs
    // through the existing handler, so exposure, the field policy, validation, the etag check and the
    // change history behave exactly as for one write. The first failing item stops the batch: the handler's
    // problem comes back with "item" (its index) and "itemOp", its detail prefixed "items[i] (op, table n): ",
    // and the runner's rollback leaves nothing written. Explicit commits in table triggers are ignored for
    // the duration, so no trigger can split the transaction.
    //
    // data.preview = true runs every item inside Bcmag Batch Rollback and rolls everything back: the answer
    // is the per-item result, or the failing item, and nothing is written.
    //
    // A value, or a recordId, may reference an earlier item: { "fromItem": n } is the record item n created
    // or changed (as recordId); { "fromItem": n, "field": "No." } (or "fieldNo") is that field's value, read
    // back after item n ran — an order header's number for its lines. The field must be readable in clear
    // under the field policy: a hidden or masked value is never copied into another field.

    Access = Public;

    var
        OpInsert: Codeunit "Bcmag Op Insert";
        OpModify: Codeunit "Bcmag Op Modify";
        OpDelete: Codeunit "Bcmag Op Delete";
        Problem: Codeunit "Bcmag Problem";
        JsonRead: Codeunit "Bcmag Json Read";
        Codec: Codeunit "Bcmag Record Id Codec";
        MaxItemsTok: Label '100', Locked = true;

    procedure MaxItems(): Integer
    var
        Max: Integer;
    begin
        Evaluate(Max, MaxItemsTok);
        exit(Max);
    end;

    procedure Run(Data: JsonObject; var Response: JsonObject; var Fail: JsonObject; var Cost: Integer): Boolean
    var
        Ctx: Codeunit "Bcmag Batch Context";
        Items, Results : JsonArray;
        Tok: JsonToken;
        Value: JsonObject;
        Preview: Boolean;
    begin
        if not ReadItems(Data, Items, Fail) then
            exit(false);
        if Data.Get('preview', Tok) then
            if JsonRead.IsNonNullValue(Tok) then
                if not JsonRead.ReadBoolean(Tok, 'preview', Preview, Fail) then exit(false);
        Cost := Items.Count();

        if Preview then begin
            Ctx.Arm(Items);
            if Codeunit.Run(Codeunit::"Bcmag Batch Rollback") then;
            if Ctx.IsFailed() then begin
                Fail := Ctx.GetFail();
                exit(false);
            end;
            if not Ctx.IsCompleted() then begin
                Fail := Problem.NewFailure(422, 'batch-failed', 'Batch preview failed', GetLastErrorText());
                exit(false);
            end;
            Results := Ctx.GetResults();
        end else
            if not RunItems(Items, Results, Fail) then
                exit(false);

        Value.Add('items', Results);
        Value.Add('count', Results.Count());
        if Preview then
            Value.Add('preview', true);
        Clear(Response);
        Response.Add('value', Value);
        exit(true);
    end;

    procedure RunItems(Items: JsonArray; var Results: JsonArray; var Fail: JsonObject): Boolean
    begin
        exit(RunItemsUncommitted(Items, Results, Fail));
    end;

    [CommitBehavior(CommitBehavior::Ignore)]
    local procedure RunItemsUncommitted(Items: JsonArray; var Results: JsonArray; var Fail: JsonObject): Boolean
    var
        Produced: Dictionary of [Integer, Text];
        Deleted: List of [Integer];
        ItemTok: JsonToken;
        Item, ItemData, Response, Result : JsonObject;
        Op: Text;
        Index, TableId, ItemCost : Integer;
        Ok: Boolean;
    begin
        Clear(Results);
        foreach ItemTok in Items do begin
            Item := ItemTok.AsObject();
            Op := '';
            TableId := 0;
            if not ReadOp(Item, Op, Fail) then
                exit(ItemFailed(Fail, Index, Op, TableId));
            if ReadTableId(Item, TableId) then;
            if not ResolveItem(Item, Index, Produced, Deleted, ItemData, Fail) then
                exit(ItemFailed(Fail, Index, Op, TableId));
            Clear(Response);
            case Op of
                'insert':
                    Ok := OpInsert.Run(ItemData, Response, Fail, ItemCost);
                'modify':
                    Ok := OpModify.Run(ItemData, Response, Fail, ItemCost);
                'delete':
                    Ok := OpDelete.Run(ItemData, Response, Fail, ItemCost);
            end;
            if not Ok then
                exit(ItemFailed(Fail, Index, Op, TableId));

            Result := ItemResult(Response, Index, Op);
            if Op = 'delete' then
                Deleted.Add(Index)
            else
                Produced.Set(Index, RecordIdOf(Result));
            Results.Add(Result);
            Index += 1;
        end;
        exit(true);
    end;

    local procedure ReadItems(Data: JsonObject; var Items: JsonArray; var Fail: JsonObject): Boolean
    var
        Tok, ItemTok : JsonToken;
        Index: Integer;
    begin
        if not Data.Get('items', Tok) then begin
            Fail := Problem.NewFailure(400, 'missing-field', 'Missing items', 'data.items is required: an array of { op, tableId, ... } write items');
            exit(false);
        end;
        if not JsonRead.ReadArray(Tok, 'items', Items, Fail) then exit(false);
        if Items.Count() = 0 then begin
            Fail := Problem.NewFailure(400, 'invalid-field', 'Empty batch', 'data.items must hold at least one item');
            exit(false);
        end;
        if Items.Count() > MaxItems() then begin
            Fail := Problem.NewFailure(400, 'batch-too-large', 'Batch too large',
                StrSubstNo('a batch holds at most %1 items (this one has %2); split it into several batches', MaxItems(), Items.Count()));
            exit(false);
        end;
        foreach ItemTok in Items do begin
            if not ItemTok.IsObject() then begin
                Fail := Problem.NewFailure(400, 'invalid-field', 'Invalid item', 'each item must be an object { op, tableId, ... }');
                exit(ItemFailed(Fail, Index, '', 0));
            end;
            Index += 1;
        end;
        exit(true);
    end;

    local procedure ReadOp(Item: JsonObject; var Op: Text; var Fail: JsonObject): Boolean
    var
        Tok: JsonToken;
    begin
        if not Item.Get('op', Tok) then begin
            Fail := Problem.NewFailure(400, 'missing-field', 'Missing op', 'the item needs "op": insert, modify or delete');
            exit(false);
        end;
        if not JsonRead.ReadText(Tok, 'op', Op, Fail) then exit(false);
        Op := LowerCase(Op);
        if not (Op in ['insert', 'modify', 'delete']) then begin
            Fail := Problem.NewFailure(400, 'invalid-field', 'Invalid op',
                StrSubstNo('"op" is "%1"; it must be insert, modify or delete', Op));
            exit(false);
        end;
        exit(true);
    end;

    local procedure ReadTableId(Item: JsonObject; var TableId: Integer): Boolean
    var
        Tok: JsonToken;
    begin
        if not Item.Get('tableId', Tok) then
            exit(false);
        if not Tok.IsValue() then
            exit(false);
        if not TryAsInteger(Tok, TableId) then
            exit(false);
        exit(true);
    end;

    [TryFunction]
    local procedure TryAsInteger(Tok: JsonToken; var Value: Integer)
    begin
        Value := Tok.AsValue().AsInteger();
    end;

    // The item as its handler takes it: "op" dropped, references resolved against earlier items.
    local procedure ResolveItem(Item: JsonObject; Index: Integer; Produced: Dictionary of [Integer, Text]; Deleted: List of [Integer]; var ItemData: JsonObject; var Fail: JsonObject): Boolean
    var
        Tok, ValueTok : JsonToken;
        Member, ValueName : Text;
        Values, Resolved : JsonObject;
        RecordToken: Text;
        ResolvedValue: JsonValue;
    begin
        Clear(ItemData);
        foreach Member in Item.Keys() do begin
            Item.Get(Member, Tok);
            case Member of
                'op':
                    ;
                'recordId':
                    if IsReference(Tok) then begin
                        if not RecordOf(Tok.AsObject(), Index, Produced, Deleted, RecordToken, Fail) then exit(false);
                        ItemData.Add('recordId', RecordToken);
                    end else
                        ItemData.Add('recordId', Tok);
                'values', 'valuesByFieldNo':
                    if Tok.IsObject() then begin
                        Values := Tok.AsObject();
                        Clear(Resolved);
                        foreach ValueName in Values.Keys() do begin
                            Values.Get(ValueName, ValueTok);
                            if IsReference(ValueTok) then begin
                                if not FieldValueOf(ValueTok.AsObject(), Index, Produced, Deleted, ResolvedValue, Fail) then exit(false);
                                Resolved.Add(ValueName, ResolvedValue);
                            end else
                                Resolved.Add(ValueName, ValueTok);
                        end;
                        ItemData.Add(Member, Resolved);
                    end else
                        ItemData.Add(Member, Tok);
                else
                    ItemData.Add(Member, Tok);
            end;
        end;
        exit(true);
    end;

    local procedure IsReference(Tok: JsonToken): Boolean
    begin
        if not Tok.IsObject() then
            exit(false);
        exit(Tok.AsObject().Contains('fromItem'));
    end;

    local procedure RecordOf(Ref: JsonObject; Index: Integer; Produced: Dictionary of [Integer, Text]; Deleted: List of [Integer]; var RecordToken: Text; var Fail: JsonObject): Boolean
    var
        Tok: JsonToken;
        From: Integer;
    begin
        Ref.Get('fromItem', Tok);
        if not TryAsInteger(Tok, From) then
            exit(InvalidReference('"fromItem" must be the index of an earlier item', Fail));
        if (From < 0) or (From >= Index) then
            exit(InvalidReference(StrSubstNo('"fromItem": %1 is not an earlier item; an item can only reference items before it', From), Fail));
        if Deleted.Contains(From) then
            exit(InvalidReference(StrSubstNo('item %1 deleted its record, so there is nothing to reference', From), Fail));
        RecordToken := Produced.Get(From);
        exit(true);
    end;

    local procedure FieldValueOf(Ref: JsonObject; Index: Integer; Produced: Dictionary of [Integer, Text]; Deleted: List of [Integer]; var Value: JsonValue; var Fail: JsonObject): Boolean
    var
        Policy: Codeunit "Bcmag Field Policy";
        RecRef: RecordRef;
        FldRef: FieldRef;
        Tok: JsonToken;
        RecordToken, FieldName, ErrorMsg : Text;
        FieldNo: Integer;
    begin
        if not RecordOf(Ref, Index, Produced, Deleted, RecordToken, Fail) then
            exit(false);
        if not Codec.Decode(RecordToken, RecRef, ErrorMsg) then
            exit(InvalidReference('the referenced record can no longer be read: ' + ErrorMsg, Fail));
        if Ref.Get('fieldNo', Tok) then begin
            if not TryAsInteger(Tok, FieldNo) then
                exit(InvalidReference('"fieldNo" must be a field number', Fail));
            if not RecRef.FieldExist(FieldNo) then
                exit(InvalidReference(StrSubstNo('table %1 has no field %2', RecRef.Number(), FieldNo), Fail));
        end else begin
            if not Ref.Get('field', Tok) then
                exit(InvalidReference('a value reference needs "field" (a field name) or "fieldNo"; { "fromItem": n } alone is only valid as a recordId', Fail));
            FieldName := Tok.AsValue().AsText();
            FieldNo := FieldNoByName(RecRef, FieldName);
            if FieldNo = 0 then
                exit(InvalidReference(StrSubstNo('table %1 has no field "%2"', RecRef.Number(), FieldName), Fail));
        end;
        if not Policy.IsReadable(RecRef.Number(), FieldNo) then begin
            Fail := Problem.NewFailure(403, 'field-restricted', 'Field access restricted',
                StrSubstNo('the referenced field %1 on table %2 is not readable under the current field policy, so its value cannot be copied', FieldNo, RecRef.Number()));
            exit(false);
        end;
        if not Policy.IsClear(RecRef.Number(), FieldNo) then begin
            Fail := Problem.NewFailure(403, 'field-masked', 'Field is masked',
                StrSubstNo('the referenced field %1 on table %2 is masked under the current field policy, so its value cannot be copied', FieldNo, RecRef.Number()));
            exit(false);
        end;
        FldRef := RecRef.Field(FieldNo);
        Value := ValueOf(FldRef);
        exit(true);
    end;

    local procedure FieldNoByName(var RecRef: RecordRef; FieldName: Text): Integer
    var
        FldRef: FieldRef;
        i: Integer;
    begin
        for i := 1 to RecRef.FieldCount() do begin
            FldRef := RecRef.FieldIndex(i);
            if LowerCase(FldRef.Name()) = LowerCase(FieldName) then
                exit(FldRef.Number());
        end;
        exit(0);
    end;

    // The field's value in the JSON shape the write handlers accept: numbers and booleans as such,
    // everything else in XML format (locale-independent), options by ordinal.
    local procedure ValueOf(var FldRef: FieldRef) Value: JsonValue
    var
        IntValue: Integer;
        BigValue: BigInteger;
        DecValue: Decimal;
        BoolValue: Boolean;
    begin
        case FldRef.Type() of
            FieldType::Integer, FieldType::Option:
                begin
                    IntValue := FldRef.Value();
                    Value.SetValue(IntValue);
                end;
            FieldType::BigInteger:
                begin
                    BigValue := FldRef.Value();
                    Value.SetValue(BigValue);
                end;
            FieldType::Decimal:
                begin
                    DecValue := FldRef.Value();
                    Value.SetValue(DecValue);
                end;
            FieldType::Boolean:
                begin
                    BoolValue := FldRef.Value();
                    Value.SetValue(BoolValue);
                end;
            else
                Value.SetValue(Format(FldRef.Value(), 0, 9));
        end;
    end;

    local procedure RecordIdOf(Result: JsonObject): Text
    var
        Tok: JsonToken;
    begin
        if Result.Get('recordId', Tok) then
            if Tok.IsValue() then
                exit(Tok.AsValue().AsText());
        exit('');
    end;

    local procedure InvalidReference(Detail: Text; var Fail: JsonObject): Boolean
    begin
        Fail := Problem.NewFailure(400, 'invalid-reference', 'Invalid reference', Detail);
        exit(false);
    end;

    local procedure ItemResult(Response: JsonObject; Index: Integer; Op: Text) Result: JsonObject
    var
        Tok, MemberTok : JsonToken;
        Member: Text;
    begin
        Result.Add('index', Index);
        Result.Add('op', Op);
        if Response.Get('value', Tok) then
            if Tok.IsObject() then
                foreach Member in Tok.AsObject().Keys() do begin
                    Tok.AsObject().Get(Member, MemberTok);
                    Result.Add(Member, MemberTok);
                end;
    end;

    // The item's problem, told which item it is: "item" and "itemOp" as extension members, and the detail
    // prefixed so an agent reading only the detail still knows what to fix.
    local procedure ItemFailed(var Fail: JsonObject; Index: Integer; Op: Text; TableId: Integer): Boolean
    var
        Tok: JsonToken;
        Detail, Prefix : Text;
    begin
        if Fail.Get('detail', Tok) then
            Detail := Tok.AsValue().AsText();
        Prefix := StrSubstNo('items[%1]', Index);
        if Op <> '' then
            if TableId <> 0 then
                Prefix += StrSubstNo(' (%1, table %2)', Op, TableId)
            else
                Prefix += StrSubstNo(' (%1)', Op);
        if Fail.Contains('detail') then
            Fail.Replace('detail', Prefix + ': ' + Detail)
        else
            Fail.Add('detail', Prefix + ': ' + Detail);
        if not Fail.Contains('item') then
            Fail.Add('item', Index);
        if (Op <> '') and not Fail.Contains('itemOp') then
            Fail.Add('itemOp', Op);
        exit(false);
    end;
}
