codeunit 94328 "Bcmag Test Runner WS"
{
    // Headless test execution for a cloud SANDBOX: BC online has no API for running AL tests, so this
    // web-service codeunit drives the Test Runner app's "Test Suite Mgt." over every test codeunit in the
    // Wicket test range and returns one JSON document. Registered as the ODataV4 service
    // "AutoTestRunner" by Bcmag Test WS Install; invoked as POST .../ODataV4/AutoTestRunner_RunAllTests.
    // Compile → dev-endpoint publish → this call is the whole loop, with no VS Code needed.
    // In the AL-Go CI container the test app is executed by AL-Go's own runner; this codeunit is inert.

    procedure RunAllTests(): Text
    begin
        exit(RunSuite('94300..94349'));
    end;

    // Iteration loop: only the affected test codeunits, e.g. {"codeunitFilter":"94300|94301"} on
    // POST .../ODataV4/AutoTestRunner_RunTests. Refuses an empty filter (that would be the whole suite by accident).
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
        SuiteName := 'BCMAGAUTO';
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
                            // SaaS replaces some errors with a generic "transaction is stopped" text; the
                            // call stack is then the only pointer to where it was raised.
                            LineObject.Add('callstack', TestSuiteMgt.GetErrorCallStack(TestMethodLine));
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
