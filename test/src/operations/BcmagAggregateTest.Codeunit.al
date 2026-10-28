codeunit 94322 "Bcmag Aggregate Test"
{
    Subtype = Test;
    TestPermissions = Disabled;

    // Aggregate mode of the query operation: count/sum/avg/min/max over the filtered set,
    // mutual exclusivity with the row-plane keys, the numeric/FlowField type rules, and the
    // field-policy 403 (an aggregate over a hidden field is an inference oracle).

    var
        Op: Codeunit "Bcmag Op Query";
        Problem: Codeunit "Bcmag Problem";
        Helper: Codeunit "Bcmag Test Helper";
        LibraryAssert: Codeunit "Library Assert";

    local procedure SeedCustomers()
    var
        Customer: Record Customer;
    begin
        if not Customer.IsEmpty() then Customer.DeleteAll();
        Customer.Init(); Customer."No." := 'AG-1'; Customer.Name := 'Agg One';     Customer."Credit Limit (LCY)" := 100.5; Customer.Insert();
        Customer.Init(); Customer."No." := 'AG-2'; Customer.Name := 'Agg Two';     Customer."Credit Limit (LCY)" := 200.5; Customer.Insert();
        Customer.Init(); Customer."No." := 'AG-3'; Customer.Name := 'Other Three'; Customer."Credit Limit (LCY)" := 300.5; Customer.Insert();
    end;

    local procedure CustomerFieldNo(TargetName: Text): Integer
    var
        FieldRec: Record Field;
    begin
        FieldRec.SetRange(TableNo, Database::Customer);
        FieldRec.SetRange(FieldName, TargetName);
        LibraryAssert.IsTrue(FieldRec.FindFirst(), StrSubstNo('Customer must have a "%1" field', TargetName));
        exit(FieldRec."No.");
    end;

    local procedure RunAggregate(Agg: JsonObject; FilterText: Text; var Response: JsonObject; var Fail: JsonObject; var Cost: Integer): Boolean
    var
        Data: JsonObject;
    begin
        Data.Add('tableId', Database::Customer);
        if FilterText <> '' then
            Data.Add('filter', FilterText);
        Data.Add('aggregate', Agg);
        exit(Op.Run(Data, Response, Fail, Cost));
    end;

    local procedure AggWithList(KeyName: Text; FieldName: Text) Agg: JsonObject
    var
        Arr: JsonArray;
    begin
        Arr.Add(FieldName);
        Agg.Add(KeyName, Arr);
    end;

    local procedure SectionToken(Response: JsonObject; Section: Text; FieldName: Text) Tok: JsonToken
    var
        Value: JsonObject;
        SectionTok: JsonToken;
    begin
        Value := Helper.ValueObject(Response);
        LibraryAssert.IsTrue(Value.Get(Section, SectionTok), StrSubstNo('"%1" missing from aggregate result', Section));
        LibraryAssert.IsTrue(SectionTok.AsObject().Get(FieldName, Tok), StrSubstNo('"%1.%2" missing from aggregate result', Section, FieldName));
    end;

    local procedure CountOf(Response: JsonObject): Integer
    var
        Value: JsonObject;
        Tok: JsonToken;
    begin
        Value := Helper.ValueObject(Response);
        LibraryAssert.IsTrue(Value.Get('count', Tok), '"count" missing from aggregate result');
        exit(Tok.AsValue().AsInteger());
    end;

    [Test]
    procedure AggregateCountWithFilter()
    var
        Agg, Response, Fail: JsonObject;
        Tok: JsonToken;
        Cost: Integer;
    begin
        Helper.ConfigureOpenMode();
        SeedCustomers();
        Agg.Add('count', true);
        LibraryAssert.IsTrue(RunAggregate(Agg, 'startswith(Name, ''Agg'')', Response, Fail, Cost), StrSubstNo('aggregate count should succeed: %1', Helper.DetailOf(Fail)));
        LibraryAssert.AreEqual(2, CountOf(Response), 'expected 2 Agg rows');
        // Cost = 1 base + 1 computation (count).
        LibraryAssert.AreEqual(2, Cost, 'aggregate cost should be 1 + computations');
        // Aggregate replies carry no row-plane metadata.
        LibraryAssert.IsFalse(Response.Get('@pagingMode', Tok), '@pagingMode must be absent');
        LibraryAssert.IsFalse(Response.Get('@nextLink', Tok), '@nextLink must be absent');
        LibraryAssert.IsFalse(Response.Get('@count', Tok), '@count must be absent');
    end;

    [Test]
    procedure AggregateSumMatchesHandTotal()
    var
        Agg, Response, Fail: JsonObject;
        Cost: Integer;
    begin
        Helper.ConfigureOpenMode();
        SeedCustomers();
        Agg := AggWithList('sum', 'Credit Limit (LCY)');
        LibraryAssert.IsTrue(RunAggregate(Agg, '', Response, Fail, Cost), 'sum should succeed');
        // 100.5 + 200.5 + 300.5, hand-computed against the seed.
        LibraryAssert.AreEqual(601.5, SectionToken(Response, 'sum', 'Credit Limit (LCY)').AsValue().AsDecimal(), 'sum mismatch');
    end;

    [Test]
    procedure AggregateAvgIsSumOverCount()
    var
        Agg, Response, Fail: JsonObject;
        Cost: Integer;
    begin
        Helper.ConfigureOpenMode();
        SeedCustomers();
        Agg := AggWithList('avg', 'Credit Limit (LCY)');
        LibraryAssert.IsTrue(RunAggregate(Agg, '', Response, Fail, Cost), 'avg should succeed');
        LibraryAssert.AreEqual(200.5, SectionToken(Response, 'avg', 'Credit Limit (LCY)').AsValue().AsDecimal(), 'avg mismatch');
    end;

    [Test]
    procedure AggregateMinMaxOnNumericAndText()
    var
        Agg, Response, Fail: JsonObject;
        MinArr, MaxArr: JsonArray;
        Cost: Integer;
    begin
        Helper.ConfigureOpenMode();
        SeedCustomers();
        MinArr.Add('Credit Limit (LCY)'); MinArr.Add('Name');
        MaxArr.Add('Credit Limit (LCY)'); MaxArr.Add('Name');
        Agg.Add('min', MinArr);
        Agg.Add('max', MaxArr);
        LibraryAssert.IsTrue(RunAggregate(Agg, '', Response, Fail, Cost), 'min/max should succeed');
        LibraryAssert.AreEqual(100.5, SectionToken(Response, 'min', 'Credit Limit (LCY)').AsValue().AsDecimal(), 'numeric min mismatch');
        LibraryAssert.AreEqual(300.5, SectionToken(Response, 'max', 'Credit Limit (LCY)').AsValue().AsDecimal(), 'numeric max mismatch');
        LibraryAssert.AreEqual('Agg One', SectionToken(Response, 'min', 'Name').AsValue().AsText(), 'text min mismatch');
        LibraryAssert.AreEqual('Other Three', SectionToken(Response, 'max', 'Name').AsValue().AsText(), 'text max mismatch');
        // Cost = 1 base + 4 computations (2 min + 2 max).
        LibraryAssert.AreEqual(5, Cost, 'min/max cost should be 1 + computations');
    end;

    [Test]
    procedure AggregateEmptySetYieldsZeroCountZeroSumNullAvgNullMin()
    var
        Agg, Response, Fail: JsonObject;
        SumArr, AvgArr, MinArr: JsonArray;
        Cost: Integer;
    begin
        Helper.ConfigureOpenMode();
        SeedCustomers();
        Agg.Add('count', true);
        SumArr.Add('Credit Limit (LCY)'); Agg.Add('sum', SumArr);
        AvgArr.Add('Credit Limit (LCY)'); Agg.Add('avg', AvgArr);
        MinArr.Add('Credit Limit (LCY)'); Agg.Add('min', MinArr);
        LibraryAssert.IsTrue(RunAggregate(Agg, 'startswith(Name, ''ZZZ'')', Response, Fail, Cost), StrSubstNo('empty-set aggregate should succeed: %1', Helper.DetailOf(Fail)));
        LibraryAssert.AreEqual(0, CountOf(Response), 'count of an empty set must be 0');
        LibraryAssert.AreEqual(0.0, SectionToken(Response, 'sum', 'Credit Limit (LCY)').AsValue().AsDecimal(), 'sum of an empty set must be numeric 0');
        LibraryAssert.IsTrue(SectionToken(Response, 'avg', 'Credit Limit (LCY)').AsValue().IsNull(), 'avg of an empty set must be null');
        LibraryAssert.IsTrue(SectionToken(Response, 'min', 'Credit Limit (LCY)').AsValue().IsNull(), 'min of an empty set must be null');
    end;

    [Test]
    procedure AggregateSumOnTextFieldRejected()
    var
        Agg, Response, Fail: JsonObject;
        Cost: Integer;
    begin
        Helper.ConfigureOpenMode();
        SeedCustomers();
        Agg := AggWithList('sum', 'Name');
        LibraryAssert.IsFalse(RunAggregate(Agg, '', Response, Fail, Cost), 'sum on a Text field must fail');
        LibraryAssert.AreEqual(400, Helper.StatusOf(Fail), 'expected 400');
        LibraryAssert.AreEqual(Problem.TypeUri('invalid-aggregate'), Problem.ProblemTypeOf(Fail), 'expected invalid-aggregate');
    end;

    [Test]
    procedure AggregateSumOnFlowFieldRejected()
    var
        Agg, Response, Fail: JsonObject;
        Cost: Integer;
    begin
        // "Balance (LCY)" is a Decimal FlowField — right type, wrong class: CalcSums cannot
        // compute FlowFields, so the request must be rejected with an explanation.
        Helper.ConfigureOpenMode();
        SeedCustomers();
        Agg := AggWithList('sum', 'Balance (LCY)');
        LibraryAssert.IsFalse(RunAggregate(Agg, '', Response, Fail, Cost), 'sum on a FlowField must fail');
        LibraryAssert.AreEqual(400, Helper.StatusOf(Fail), 'expected 400');
        LibraryAssert.AreEqual(Problem.TypeUri('invalid-aggregate'), Problem.ProblemTypeOf(Fail), 'expected invalid-aggregate');
        LibraryAssert.IsTrue(StrPos(Helper.DetailOf(Fail), 'FlowField') > 0, 'detail must explain the FlowField limitation');
    end;

    [Test]
    procedure AggregateWithSelectRejected()
    var
        Data, Agg, Response, Fail: JsonObject;
        Select: JsonArray;
        Cost: Integer;
    begin
        Helper.ConfigureOpenMode();
        SeedCustomers();
        Select.Add('Name');
        Agg.Add('count', true);
        Data.Add('tableId', Database::Customer);
        Data.Add('select', Select);
        Data.Add('aggregate', Agg);
        LibraryAssert.IsFalse(Op.Run(Data, Response, Fail, Cost), 'aggregate + select must fail');
        LibraryAssert.AreEqual(400, Helper.StatusOf(Fail), 'expected 400');
        LibraryAssert.AreEqual(Problem.TypeUri('invalid-aggregate'), Problem.ProblemTypeOf(Fail), 'expected invalid-aggregate');
        LibraryAssert.IsTrue(StrPos(Helper.DetailOf(Fail), 'select') > 0, 'detail must name the conflicting key');
    end;

    [Test]
    procedure AggregateWithTopRejected()
    var
        Data, Agg, Response, Fail: JsonObject;
        Cost: Integer;
    begin
        Helper.ConfigureOpenMode();
        SeedCustomers();
        Agg.Add('count', true);
        Data.Add('tableId', Database::Customer);
        Data.Add('top', 5);
        Data.Add('aggregate', Agg);
        LibraryAssert.IsFalse(Op.Run(Data, Response, Fail, Cost), 'aggregate + top must fail');
        LibraryAssert.AreEqual(400, Helper.StatusOf(Fail), 'expected 400');
        LibraryAssert.AreEqual(Problem.TypeUri('invalid-aggregate'), Problem.ProblemTypeOf(Fail), 'expected invalid-aggregate');
        LibraryAssert.IsTrue(StrPos(Helper.DetailOf(Fail), 'top') > 0, 'detail must name the conflicting key');
    end;

    [Test]
    procedure AggregateUnknownFieldSuggests()
    var
        Agg, Response, Fail: JsonObject;
        Tok: JsonToken;
        Cost: Integer;
    begin
        Helper.ConfigureOpenMode();
        SeedCustomers();
        Agg := AggWithList('sum', 'Nam');
        LibraryAssert.IsFalse(RunAggregate(Agg, '', Response, Fail, Cost), 'unknown field must fail');
        LibraryAssert.AreEqual(400, Helper.StatusOf(Fail), 'expected 400');
        LibraryAssert.AreEqual(Problem.TypeUri('unknown-field'), Problem.ProblemTypeOf(Fail), 'expected unknown-field');
        LibraryAssert.IsTrue(Fail.Get('suggest', Tok), 'a Levenshtein suggestion is expected');
        LibraryAssert.AreEqual('Name', Helper.TextField(Tok.AsObject(), 'field'), 'expected "Name" as the suggestion');
    end;

    [Test]
    procedure AggregateOnDeniedFieldIs403()
    var
        Agg, Response, Fail: JsonObject;
        Cost: Integer;
    begin
        // The inference oracle: sum over a policy-denied field would disclose it as surely as
        // selecting it, so the aggregate path must return the same 403 as select.
        Helper.ConfigureOpenMode();
        SeedCustomers();
        Helper.SetFieldPolicyMode(Enum::"Bcmag Field Policy Mode"::ByClassification);
        Helper.ExposeField(Database::Customer, CustomerFieldNo('Credit Limit (LCY)'), false, false);

        Agg := AggWithList('sum', 'Credit Limit (LCY)');
        LibraryAssert.IsFalse(RunAggregate(Agg, '', Response, Fail, Cost), 'aggregate over a denied field must fail');
        LibraryAssert.AreEqual(403, Helper.StatusOf(Fail), 'expected 403');
        LibraryAssert.AreEqual(Problem.TypeUri('field-restricted'), Problem.ProblemTypeOf(Fail), 'expected field-restricted');

        Helper.UnexposeField(Database::Customer, CustomerFieldNo('Credit Limit (LCY)'));
    end;

    [Test]
    procedure AggregateComposesWithFilter()
    var
        Agg, Response, Fail: JsonObject;
        SumArr: JsonArray;
        Cost: Integer;
    begin
        // Only the filtered rows may enter the computation: AG-3 ('Other Three', 300.5) must
        // stay outside both the count and the sum.
        Helper.ConfigureOpenMode();
        SeedCustomers();
        Agg.Add('count', true);
        SumArr.Add('Credit Limit (LCY)');
        Agg.Add('sum', SumArr);
        LibraryAssert.IsTrue(RunAggregate(Agg, 'startswith(Name, ''Agg'')', Response, Fail, Cost), StrSubstNo('filter + aggregate should succeed: %1', Helper.DetailOf(Fail)));
        LibraryAssert.AreEqual(2, CountOf(Response), 'only filtered rows may be counted');
        LibraryAssert.AreEqual(301.0, SectionToken(Response, 'sum', 'Credit Limit (LCY)').AsValue().AsDecimal(), 'only filtered rows may be summed');
    end;

    [Test]
    procedure AggregateMinOnMaskedFieldIs403FieldMasked()
    var
        Agg, Response, Fail: JsonObject;
        Cost: Integer;
    begin
        // min/max over a masked text field would disclose the hidden value outright.
        Helper.ConfigureOpenMode();
        SeedCustomers();
        Helper.SetFieldPolicyMode(Enum::"Bcmag Field Policy Mode"::ByClassification);
        Helper.SetFieldAccess(Database::Customer, CustomerFieldNo('Name'), "Bcmag Read Access"::Masked, 'PARTIAL', false);

        Agg := AggWithList('min', 'Name');
        LibraryAssert.IsFalse(RunAggregate(Agg, '', Response, Fail, Cost), 'aggregate over a masked field must fail');
        LibraryAssert.AreEqual(403, Helper.StatusOf(Fail), 'expected 403');
        LibraryAssert.AreEqual(Problem.TypeUri('field-masked'), Problem.ProblemTypeOf(Fail), 'expected field-masked');

        Helper.UnexposeField(Database::Customer, CustomerFieldNo('Name'));
    end;
}
