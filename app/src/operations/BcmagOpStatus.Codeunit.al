codeunit 94138 "Bcmag Op Status"
{
    // "status" operation: report one async request's lifecycle to its owner. Also the home of the
    // shared projection + caller-scoping helpers reused by "cancel" and "requests", so all three
    // present an identical, machine-stable shape. Enum/option values are case-mapped to invariant
    // names (never Format(), which is locale-dependent). Caller-scoping is strict: a row owned by a
    // different principal is indistinguishable from a nonexistent one (404 unknown-request), so one
    // caller can never probe another's requests.

    Access = Public;

    var
        JsonRead: Codeunit "Bcmag Json Read";
        Problem: Codeunit "Bcmag Problem";
        AzureClient: Codeunit "Bcmag Azure Client";

    procedure Run(Data: JsonObject; var Response: JsonObject; var Fail: JsonObject; var Cost: Integer): Boolean
    var
        Row: Record "Bcmag Request Queue";
        RequestId: Text;
    begin
        if not GetRequestId(Data, RequestId, Fail) then
            exit(false);
        if not LoadCallerRow(RequestId, Row, Fail) then
            exit(false);
        Clear(Response);
        Response.Add('value', ProjectRow(Row));
        Cost := 1;
        exit(true);
    end;

    // data.requestId → the row, scoped to the calling principal. A missing/malformed/foreign/absent
    // request all resolve to the same 404 (never disclose another caller's request exists).
    procedure GetRequestId(Data: JsonObject; var RequestId: Text; var Fail: JsonObject): Boolean
    var
        Tok: JsonToken;
    begin
        if not JsonRead.GetValue(Data, 'requestId', Tok) then begin
            Fail := Problem.NewFailure(400, 'missing-field', 'Missing requestId', 'data.requestId is required');
            exit(false);
        end;
        RequestId := Tok.AsValue().AsText();
        exit(true);
    end;

    procedure LoadCallerRow(RequestId: Text; var Row: Record "Bcmag Request Queue"; var Fail: JsonObject): Boolean
    var
        SystemId: Guid;
    begin
        if not TryParseGuid(RequestId, SystemId) then begin
            Fail := UnknownRequest();
            exit(false);
        end;
        if not Row.GetBySystemId(SystemId) then begin
            Fail := UnknownRequest();
            exit(false);
        end;
        if Row.Caller <> UserSecurityId() then begin
            Fail := UnknownRequest();
            exit(false);
        end;
        exit(true);
    end;

    procedure ProjectRow(var Row: Record "Bcmag Request Queue") Obj: JsonObject
    var
        ProblemObj: JsonObject;
    begin
        Obj.Add('requestId', Row.PublicId());
        Obj.Add('status', StatusName(Row.Status));
        Obj.Add('operation', Row.Operation);
        Obj.Add('packageFormat', PackageFormatName(Row."Package Format"));
        AddDateTime(Obj, 'createdAt', Row."Created At");
        AddDateTime(Obj, 'scheduledFor', Row."Scheduled For");
        AddDateTime(Obj, 'startedAt', Row."Started At");
        AddDateTime(Obj, 'completedAt', Row."Completed At");
        AddDateTime(Obj, 'expiresAt', Row."Expires At");
        Obj.Add('progressRows', Row."Progress Rows");
        Obj.Add('resultRowCount', Row."Result Row Count");
        Obj.Add('resultBytes', Row."Result Bytes");
        // The download URL is only meaningful once the package exists. It is composed NOW, not read from
        // the row (which holds only the tokenless blob URL): Service SAS re-mints a token valid for SAS TTL
        // Minutes, capped at the package's expiry, so the URL keeps working for as long as the package
        // lives instead of dying with the token minted at completion. Ready SAS appends the stored token.
        if Row.Status = Row.Status::Succeeded then
            Obj.Add('packageUrl', AzureClient.BuildDownloadUrl(Row));
        if Row."Problem Type" <> '' then begin
            ProblemObj.Add('type', Row."Problem Type");
            ProblemObj.Add('detail', Row.GetLastError());
            Obj.Add('problem', ProblemObj);
        end;
    end;

    // Invariant, lowercase status name — matches the "queued"/"scheduled" wording of the enqueue
    // response. NOT Format(Status), which renders the localized caption on a non-ENU session.
    procedure StatusName(Status: Enum "Bcmag Request Status"): Text
    begin
        case Status of
            Status::Queued:
                exit('queued');
            Status::Scheduled:
                exit('scheduled');
            Status::Running:
                exit('running');
            Status::Succeeded:
                exit('succeeded');
            Status::Failed:
                exit('failed');
            Status::Cancelled:
                exit('cancelled');
            Status::Expired:
                exit('expired');
        end;
        exit('');
    end;

    procedure PackageFormatName(PackageFormat: Enum "Bcmag Package Format"): Text
    begin
        case PackageFormat of
            PackageFormat::Ndjson:
                exit('ndjson');
            PackageFormat::Json:
                exit('json');
            PackageFormat::Zip:
                exit('zip');
        end;
        exit('');
    end;

    procedure UnknownRequest() Fail: JsonObject
    begin
        Fail := Problem.NewFailure(404, 'unknown-request', 'Unknown request',
            'no async request with that id exists for the caller');
    end;

    local procedure AddDateTime(var Obj: JsonObject; Name: Text; Dt: DateTime)
    var
        NullTok: JsonToken;
    begin
        if Dt = 0DT then begin
            NullTok.ReadFrom('null');
            Obj.Add(Name, NullTok);
        end else
            Obj.Add(Name, Format(Dt, 0, 9));
    end;

    [TryFunction]
    local procedure TryParseGuid(Input: Text; var Value: Guid)
    begin
        Evaluate(Value, Input);
    end;
}
