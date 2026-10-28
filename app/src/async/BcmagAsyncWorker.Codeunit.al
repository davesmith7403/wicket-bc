codeunit 94135 "Bcmag Async Worker"
{
    // Runs in the background (StartSession for immediate jobs, TaskScheduler for scheduled ones).
    // TableNo binds the passed queue row / task RecordId to Rec for both entry paths. The worker
    // re-runs the stored query THROUGH "Bcmag Op Query" (so field policy / exposure / read-only all
    // still hold — it IS the query op), pages via the cursor internally, packages the rows, and
    // uploads the package to Azure. All GUI is suppressed anyway (background sessions have no client),
    // and this codeunit raises no dialogs.
    //
    // Testability seam: BuildPackage (query → package Temp Blob) is a public procedure the test app
    // calls WITHOUT Azure to assert the NDJSON/JSON/ZIP contents; only the upload needs a sandbox.

    Access = Public;
    TableNo = "Bcmag Request Queue";

    var
        Problem: Codeunit "Bcmag Problem";
        AzureClient: Codeunit "Bcmag Azure Client";
        OutcomeTelemetryIdTok: Label 'WICKET-0003', Locked = true;

    trigger OnRun()
    begin
        Execute(Rec."Entry No.");
    end;

    local procedure Execute(EntryNo: BigInteger)
    var
        ResultTempBlob: Codeunit "Temp Blob";
        Fail: JsonObject;
        ContentType, UploadError: Text;
        RowCount: Integer;
        QueryFailed, Cancelled, Uploaded: Boolean;
    begin
        if not StartRunning(EntryNo) then
            exit;

        // The heavy body may raise an AL error (e.g. a query blowing the scan budget rethrown). Guard it
        // so the row is marked Failed rather than left Running; for the TaskScheduler path the Failure
        // codeunit is a second backstop. No database write happens inside either try function.
        ClearLastError();
        if not TryBuild(EntryNo, ResultTempBlob, ContentType, RowCount, QueryFailed, Cancelled, Fail) then begin
            MarkFailed(EntryNo, Problem.TypeUri('internal'), GetLastErrorText());
            exit;
        end;
        if QueryFailed then begin
            MarkFailed(EntryNo, Problem.ProblemTypeOf(Fail), Problem.DetailOf(Fail));
            exit;
        end;
        if Cancelled then begin
            FinishCancelled(EntryNo);
            exit;
        end;

        // From here a blob may come to exist: record that (committed) BEFORE the upload starts, so a crash,
        // timeout or failure mid-upload still leaves a row the reaper knows to clean. Stops here if the
        // request was cancelled or finalised meanwhile.
        if not MarkUploadPending(EntryNo) then
            exit;

        ClearLastError();
        if not TryUpload(EntryNo, ResultTempBlob, ContentType, Uploaded, UploadError) then begin
            MarkFailed(EntryNo, Problem.TypeUri('async-upload-failed'), GetLastErrorText());
            exit;
        end;
        if not Uploaded then begin
            MarkFailed(EntryNo, Problem.TypeUri('async-upload-failed'), UploadError);
            exit;
        end;

        // The upload succeeded, but Succeeded also promises a FETCHABLE URL. Configuration can change
        // between enqueue and now (token cleared, mode switched) — recheck before promising delivery.
        if not AzureClient.ValidateDownloadConfiguration(UploadError) then begin
            MarkFailed(EntryNo, Problem.TypeUri('async-upload-failed'), UploadError);
            exit;
        end;
        MarkSucceeded(EntryNo, ResultTempBlob.Length(), RowCount, ContentType);
    end;

    // Promote the row to Running under a lock, re-checking it first: a cancel (or the reaper) may have
    // finalised it, or asked it to stop, between enqueue and now. False = do not run.
    local procedure StartRunning(EntryNo: BigInteger): Boolean
    var
        Row: Record "Bcmag Request Queue";
    begin
        Row.LockTable();
        if not Row.Get(EntryNo) then
            exit(false);
        if Row.IsTerminal() then begin
            Commit();
            exit(false);
        end;
        if Row."Cancel Requested" then begin
            Commit(); // release the lock before FinishCancelled re-reads
            FinishCancelled(EntryNo);
            exit(false);
        end;

        Row.Status := Row.Status::Running;
        Row."Started At" := CurrentDateTime();
        Row."Attempt Count" += 1;
        // Record the destination this run uploads to. A scheduled job may start days after enqueue, and
        // Setup may have moved meanwhile; the credential in IsolatedStorage matches Setup NOW, so the
        // upload goes where Setup points now — and the row must say so, because the download URL and
        // the eventual cleanup target the row's destination, never Setup's later value. Persisted with
        // the Running state (this Modify + Commit), so even a crash mid-upload leaves the truth behind.
        AzureClient.StampDestination(Row);
        Row."Package Url" := CopyStr(AzureClient.ComposeBlobUrl(Row), 1, MaxStrLen(Row."Package Url"));
        Row.Modify(true);
        Commit(); // release the lock and publish Running before the heavy body
        exit(true);
    end;

    // Query + packaging, in memory. No COMMIT and no write: the query is a read, and the cancel
    // checkpoint uses a dirty read so it never has to commit mid-body.
    [TryFunction]
    local procedure TryBuild(EntryNo: BigInteger; var ResultTempBlob: Codeunit "Temp Blob"; var ContentType: Text; var RowCount: Integer; var QueryFailed: Boolean; var Cancelled: Boolean; var Fail: JsonObject)
    var
        Row: Record "Bcmag Request Queue";
        InnerData: JsonObject;
    begin
        Row.Get(EntryNo);
        InnerData := ReadInnerData(Row);
        QueryFailed := not BuildPackage(EntryNo, InnerData, Row."Package Format", ResultTempBlob, ContentType, RowCount, Cancelled, Fail);
    end;

    local procedure MarkUploadPending(EntryNo: BigInteger): Boolean
    var
        Row: Record "Bcmag Request Queue";
    begin
        Row.LockTable();
        if not Row.Get(EntryNo) then
            exit(false);
        if Row.IsTerminal() then begin
            Commit();
            exit(false);
        end;
        if Row."Cancel Requested" then begin
            Commit();
            FinishCancelled(EntryNo);
            exit(false);
        end;
        if Row."Blob Cleanup" <> Row."Blob Cleanup"::Pending then begin
            Row."Blob Cleanup" := Row."Blob Cleanup"::Pending;
            Row.Modify(true);
        end;
        Commit();
        exit(true);
    end;

    // Container provisioning (best effort) + the upload. Network only; no database write (the Azure
    // client's OnBeforeBlobRequest subscribers must not write either). A container that could not be
    // created is not fatal by itself — it usually already exists, or the credential may upload but not
    // create — so the upload decides, and its error carries the container error for diagnosis.
    [TryFunction]
    local procedure TryUpload(EntryNo: BigInteger; var ResultTempBlob: Codeunit "Temp Blob"; ContentType: Text; var Uploaded: Boolean; var UploadError: Text)
    var
        Row: Record "Bcmag Request Queue";
        UploadInStr: InStream;
        ContainerError: Text;
    begin
        Uploaded := false;
        Row.Get(EntryNo);
        if not AzureClient.EnsureContainer(Row, ContainerError) then;
        ResultTempBlob.CreateInStream(UploadInStr);
        Uploaded := AzureClient.UploadStream(Row, UploadInStr, ContentType, UploadError);
        if (not Uploaded) and (ContainerError <> '') then
            UploadError := UploadError + ' (container provisioning also failed: ' + ContainerError + ')';
    end;

    // Public testable seam: re-run the query through Op Query, following @nextLink internally, feeding
    // every row into a fresh Package Builder. Returns false + Fail if the query op returns a problem.
    // Between pages it dirty-reads Cancel Requested (visible cross-session without our own commit); if
    // set, it finalizes the partial package and returns Cancelled = true.
    procedure BuildPackage(EntryNo: BigInteger; InnerData: JsonObject; PackageFormat: Enum "Bcmag Package Format"; var ResultTempBlob: Codeunit "Temp Blob"; var ContentType: Text; var RowCount: Integer; var Cancelled: Boolean; var Fail: JsonObject): Boolean
    var
        OpQuery: Codeunit "Bcmag Op Query";
        Builder: Codeunit "Bcmag Package Builder";
        RunnerContext: Codeunit "Bcmag Op Runner Context";
        QueryData, PageResponse, PageFail: JsonObject;
        ValueArr: JsonArray;
        Tok, RowTok: JsonToken;
        Cursor: Text;
        Cost, i: Integer;
        HasNext: Boolean;
    begin
        Cancelled := false;
        // The background session has its own, empty single-instance context: without this the field
        // policy would read no "unmask" member (default true) and the caller's "unmask": false opt-out
        // would be lost between enqueue and run. Fields lifted during the build are noted against it.
        RunnerContext.SetRequest('query', InnerData);
        Builder.BeginPackage(PackageFormat);
        repeat
            QueryData := CloneObject(InnerData);
            if Cursor <> '' then
                QueryData.Add('cursor', Cursor);

            Clear(PageResponse);
            Clear(PageFail);
            if not OpQuery.Run(QueryData, PageResponse, PageFail, Cost) then begin
                Fail := PageFail;
                exit(false);
            end;

            if PageResponse.Get('value', Tok) then begin
                ValueArr := Tok.AsArray();
                for i := 0 to ValueArr.Count() - 1 do begin
                    ValueArr.Get(i, RowTok);
                    Builder.AddRow(RowTok.AsObject());
                end;
            end;

            HasNext := PageResponse.Get('@nextLink', Tok);
            if HasNext then
                Cursor := Tok.AsValue().AsText();

            // Cooperative-cancel checkpoint (EntryNo = 0 in tests → no live row → never cancelled).
            if (EntryNo <> 0) and CancelRequestedDirty(EntryNo) then begin
                Cancelled := true;
                Builder.FinishPackage(ResultTempBlob, ContentType, RowCount);
                exit(true);
            end;
        until not HasNext;

        Builder.FinishPackage(ResultTempBlob, ContentType, RowCount);
        exit(true);
    end;

    local procedure ReadInnerData(var Row: Record "Bcmag Request Queue") InnerData: JsonObject
    var
        Envelope: JsonObject;
        Tok: JsonToken;
    begin
        // Request Data is the canonical {operation, data} snapshot; the worker runs its data part.
        Envelope.ReadFrom(Row.GetRequestData());
        if Envelope.Get('data', Tok) then
            InnerData := Tok.AsObject();
    end;

    local procedure CloneObject(Source: JsonObject) Clone: JsonObject
    var
        Serialized: Text;
    begin
        Source.WriteTo(Serialized);
        Clone.ReadFrom(Serialized);
    end;

    local procedure CancelRequestedDirty(EntryNo: BigInteger): Boolean
    var
        Row: Record "Bcmag Request Queue";
    begin
        // Dirty read so the cancel op's committed flag is seen without our body committing (and
        // without taking a lock that would deadlock the caller's cancel Modify).
        Row.ReadIsolation := IsolationLevel::ReadUncommitted;
        if Row.Get(EntryNo) then
            exit(Row."Cancel Requested");
        exit(false);
    end;

    local procedure MarkSucceeded(EntryNo: BigInteger; ResultBytes: BigInteger; RowCount: Integer; ContentType: Text)
    var
        Row: Record "Bcmag Request Queue";
    begin
        Row.LockTable();
        if not Row.Get(EntryNo) then
            exit;
        // Never resurrect a terminal row: a cancel (or the reaper) may have finalised it while this
        // worker was mid-run. Honouring that here is what makes cooperative cancel actually stick.
        if Row.IsTerminal() then begin
            Commit();
            exit;
        end;
        // Cancelled while the upload ran: the caller asked to stop, so the package is not delivered —
        // finalise Cancelled; the blob just written is Pending and gets deleted.
        if Row."Cancel Requested" then begin
            Commit();
            FinishCancelled(EntryNo);
            exit;
        end;
        Row.Status := Row.Status::Succeeded;
        // Tokenless: the caller-facing (signed) URL is composed when status is read.
        Row."Package Url" := CopyStr(AzureClient.ComposeBlobUrl(Row), 1, MaxStrLen(Row."Package Url"));
        Row."Result Bytes" := ResultBytes;
        Row."Result Row Count" := RowCount;
        Row."Progress Rows" := RowCount;
        Row."Content Type" := CopyStr(ContentType, 1, MaxStrLen(Row."Content Type"));
        Row.StampCompletion();
        Row.Modify(true);
        Commit();
        LogOutcome(Row);
    end;

    local procedure MarkFailed(EntryNo: BigInteger; ProblemType: Text; Detail: Text)
    var
        Row: Record "Bcmag Request Queue";
    begin
        Row.LockTable();
        if not Row.Get(EntryNo) then
            exit;
        // A cancel or the reaper may have already finalised the row; don't overwrite a terminal state.
        if Row.IsTerminal() then begin
            Commit();
            exit;
        end;
        Row.Status := Row.Status::Failed;
        Row."Problem Type" := CopyStr(ProblemType, 1, MaxStrLen(Row."Problem Type"));
        Row.SetLastError(Detail);
        Row.StampCompletion();
        Row.Modify(true);
        Commit();
        LogOutcome(Row);
    end;

    // Finalise Cancelled. A package may already be in the container (Blob Cleanup = Pending: cancelled
    // after the upload began); it gets one delete attempt now — made WITHOUT holding a lock — and the
    // reaper retries a pending one, since Cancelled rows are in its population.
    local procedure FinishCancelled(EntryNo: BigInteger)
    var
        Row, Fresh : Record "Bcmag Request Queue";
        Reaper: Codeunit "Bcmag Async Reaper";
        Attempted, Confirmed : Boolean;
        ErrorText: Text;
    begin
        if not Row.Get(EntryNo) then
            exit;
        if Row.IsTerminal() then
            exit;
        Reaper.AttemptDelete(Row, Attempted, Confirmed, ErrorText);

        Fresh.LockTable();
        if not Fresh.Get(EntryNo) then
            exit;
        if Fresh.IsTerminal() then begin
            Commit();
            exit;
        end;
        Fresh.Status := Fresh.Status::Cancelled;
        Fresh.StampCompletion();
        Reaper.ApplyCleanup(Fresh, Attempted, Confirmed, ErrorText);
        Fresh.Modify(true);
        Commit();
        LogOutcome(Fresh);
    end;

    // One telemetry signal per finished request (worker-driven outcomes). SystemMetadata only: ids,
    // counts, status and problem type — never the query, the URL or the error text.
    local procedure LogOutcome(Row: Record "Bcmag Request Queue")
    var
        OpStatus: Codeunit "Bcmag Op Status";
        Dimensions: Dictionary of [Text, Text];
        Level: Verbosity;
    begin
        Dimensions.Add('requestId', Row.PublicId());
        Dimensions.Add('status', OpStatus.StatusName(Row.Status));
        Dimensions.Add('packageFormat', OpStatus.PackageFormatName(Row."Package Format"));
        Dimensions.Add('resultRowCount', Format(Row."Result Row Count", 0, 9));
        Dimensions.Add('resultBytes', Format(Row."Result Bytes", 0, 9));
        Dimensions.Add('attemptCount', Format(Row."Attempt Count", 0, 9));
        Dimensions.Add('problemType', Row."Problem Type");
        if (Row."Started At" <> 0DT) and (Row."Completed At" <> 0DT) then
            Dimensions.Add('durationMs', Format(Row."Completed At" - Row."Started At", 0, 9));
        Level := Verbosity::Normal;
        if Row.Status = Row.Status::Failed then
            Level := Verbosity::Warning;
        Session.LogMessage(OutcomeTelemetryIdTok, StrSubstNo('Wicket async request -> %1', OpStatus.StatusName(Row.Status)),
            Level, DataClassification::SystemMetadata, TelemetryScope::ExtensionPublisher, Dimensions);
    end;
}
