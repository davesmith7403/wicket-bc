codeunit 94139 "Bcmag Async Cancel"
{
    // "cancel" operation and the shared CancelRow routine (also called by the queue-list page action).
    // Cancellation is cooperative for work already in flight: a Running row gets a Cancel Requested
    // flag the worker honours at its next checkpoint; a Scheduled or Queued row (not started yet) is
    // cancelled outright, cancelling its TaskScheduler task if one is still live. Terminal rows are a
    // no-op. The op path is caller-scoped (404 unknown-request for a foreign/absent row).

    Access = Public;

    var
        OpStatus: Codeunit "Bcmag Op Status";

    procedure Run(Data: JsonObject; var Response: JsonObject; var Fail: JsonObject; var Cost: Integer): Boolean
    var
        Row: Record "Bcmag Request Queue";
        RequestId: Text;
        Value: JsonObject;
    begin
        if not OpStatus.GetRequestId(Data, RequestId, Fail) then
            exit(false);
        if not OpStatus.LoadCallerRow(RequestId, Row, Fail) then
            exit(false);
        CancelRow(Row);
        Clear(Response);
        Value.Add('requestId', Row.PublicId());
        Value.Add('status', OpStatus.StatusName(Row.Status));
        Response.Add('value', Value);
        Cost := 1;
        exit(true);
    end;

    // Decided on a fresh read under LockTable, never on the caller's (possibly stale) copy: the worker
    // takes the same lock to promote Queued -> Running and to finalise, so the two cannot interleave.
    //   Scheduled  not started: cancel the platform task (if still live) and finalise Cancelled.
    //   Queued     not started either (the worker flips it to Running, under this lock, before any work):
    //              finalise Cancelled directly — a worker session that starts afterwards sees a terminal
    //              row and exits. The flag is set too, for the record.
    //   Running    cooperative: set Cancel Requested; the worker stops at its next checkpoint, and a
    //              worker that finishes its upload first honours the flag instead of reporting success.
    // Row is refreshed to the persisted state on return.
    procedure CancelRow(var Row: Record "Bcmag Request Queue")
    var
        Fresh: Record "Bcmag Request Queue";
    begin
        Fresh.LockTable();
        if not Fresh.Get(Row."Entry No.") then
            exit;
        if Fresh.IsTerminal() then begin
            Commit();
            Row := Fresh;
            exit; // already done — nothing to cancel
        end;

        case Fresh.Status of
            Fresh.Status::Scheduled:
                begin
                    if (not IsNullGuid(Fresh."Task Id")) and TaskScheduler.TaskExists(Fresh."Task Id") then
                        TaskScheduler.CancelTask(Fresh."Task Id");
                    Fresh.Status := Fresh.Status::Cancelled;
                    Fresh.StampCompletion();
                end;
            Fresh.Status::Queued:
                begin
                    Fresh."Cancel Requested" := true;
                    Fresh.Status := Fresh.Status::Cancelled;
                    Fresh.StampCompletion();
                end;
            else
                Fresh."Cancel Requested" := true;
        end;
        Fresh.Modify(true);
        // Make the change (especially the flag) visible to the background worker session.
        Commit();
        Row := Fresh;
    end;
}
