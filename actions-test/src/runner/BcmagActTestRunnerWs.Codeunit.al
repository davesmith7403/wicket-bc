codeunit 94390 "Bcmag Act Test Runner WS"
{
    // Headless test execution for a cloud SANDBOX (same design as the core test app's
    // "Bcmag Test Runner WS"): drives the Test Runner app's "Test Suite Mgt." over every test codeunit
    // in the actions-test range and returns one JSON document. Registered as the ODataV4 service
    // "AutoTestRunnerActions" by Bcmag Act Test WS Install / Upgrade; invoked as
    // POST .../ODataV4/AutoTestRunnerActions_RunAllTests. Inert in the AL-Go CI container.

    procedure RunAllTests(): Text
    begin
        exit(RunSuite('94350..94389'));
    end;

    // Iteration loop: only the affected test codeunits, e.g. {"codeunitFilter":"94350|94351"} on
    // POST .../ODataV4/AutoTestRunnerActions_RunTests. Refuses an empty filter (that would be the whole suite by accident).
    procedure RunTests(codeunitFilter: Text): Text
    begin
        if codeunitFilter = '' then
            Error('codeunitFilter is required; use RunAllTests for the whole suite');
        exit(RunSuite(codeunitFilter));
    end;

    local procedure RunSuite(CodeunitFilter: Text): Text
    var
        ALTestSuite: Record "AL Test Suite";
        TestMethodLine: Record "Test Method Line";
        TestSuiteMgt: Codeunit "Test Suite Mgt.";
        LineObject: JsonObject;
        ResultRoot: JsonObject;
        ResultLines: JsonArray;
        ResultText: Text;
        SuiteName: Code[10];
        Passed: Integer;
        Failed: Integer;
        Skipped: Integer;
    begin
        SuiteName := 'BCMAGACT';
        if ALTestSuite.Get(SuiteName) then
            ALTestSuite.Delete(true);
        TestSuiteMgt.CreateTestSuite(SuiteName);
        ALTestSuite.Get(SuiteName);
        TestSuiteMgt.SelectTestMethodsByRange(ALTestSuite, CodeunitFilter);

        TestMethodLine.SetRange("Test Suite", SuiteName);
        if TestMethodLine.FindFirst() then
            TestSuiteMgt.RunAllTests(TestMethodLine);

        // Build the JSON here: TestSuiteMgt.TestResultsToJSON serializes only the FIRST codeunit's group.
        TestMethodLine.Reset();
        TestMethodLine.SetRange("Test Suite", SuiteName);
        TestMethodLine.SetRange("Line Type", TestMethodLine."Line Type"::"Function");
        if TestMethodLine.FindSet() then
            repeat
                Clear(LineObject);
                LineObject.Add('codeunit', TestMethodLine."Test Codeunit");
                LineObject.Add('function', TestMethodLine."Function");
                LineObject.Add('result', Format(TestMethodLine.Result));
                case TestMethodLine.Result of
                    TestMethodLine.Result::Success:
                        Passed += 1;
                    TestMethodLine.Result::Failure:
                        begin
                            Failed += 1;
                            LineObject.Add('error', TestSuiteMgt.GetFullErrorMessage(TestMethodLine));
                        end;
                    TestMethodLine.Result::Skipped:
                        Skipped += 1;
                end;
                ResultLines.Add(LineObject);
            until TestMethodLine.Next() = 0;

        ResultRoot.Add('passed', Passed);
        ResultRoot.Add('failed', Failed);
        ResultRoot.Add('skipped', Skipped);
        ResultRoot.Add('tests', ResultLines);
        ResultRoot.WriteTo(ResultText);
        exit(ResultText);
    end;
}
