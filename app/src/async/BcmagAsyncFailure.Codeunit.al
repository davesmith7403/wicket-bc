codeunit 94136 "Bcmag Async Failure"
{
    // TaskScheduler failure codeunit for a scheduled worker task. It runs AFTER the worker's own
    // transaction rolled back, so it must be tiny and defensive: re-read the row by Entry No., and if
    // it is still non-terminal, record the failure. TableNo binds the task's RecordId to Rec.

    TableNo = "Bcmag Request Queue";

    var
        Problem: Codeunit "Bcmag Problem";

    trigger OnRun()
    var
        Row: Record "Bcmag Request Queue";
    begin
        Row.LockTable();
        if not Row.Get(Rec."Entry No.") then
            exit;
        if Row.IsTerminal() then
            exit; // the worker may have already finalized it before the fault
        Row.Status := Row.Status::Failed;
        Row."Problem Type" := CopyStr(Problem.TypeUri('async-task-failed'), 1, MaxStrLen(Row."Problem Type"));
        Row.SetLastError(GetLastErrorText());
        Row.StampCompletion(); // a blob the failed run may have begun uploading is Pending; it expires with the row
        Row.Modify(true);
    end;
}
