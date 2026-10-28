codeunit 94140 "Bcmag Op Requests"
{
    // "requests" operation: list the calling principal's async requests, newest first, using the same
    // projection as "status". Optional data.status filter (invariant name) and data.top (default 20,
    // capped at 100). Strictly caller-scoped: only rows owned by UserSecurityId are ever returned.

    Access = Public;

    var
        OpStatus: Codeunit "Bcmag Op Status";
        JsonRead: Codeunit "Bcmag Json Read";

    procedure Run(Data: JsonObject; var Response: JsonObject; var Fail: JsonObject; var Cost: Integer): Boolean
    var
        Row: Record "Bcmag Request Queue";
        Tok: JsonToken;
        Arr: JsonArray;
        Top, Returned: Integer;
        StatusValue: Enum "Bcmag Request Status";
        HasStatusFilter: Boolean;
    begin
        Top := 20;
        if Data.Get('top', Tok) then
            if JsonRead.IsNonNullValue(Tok) then
                if not JsonRead.ReadInteger(Tok, 'top', Top, Fail) then exit(false);
        if Top < 1 then
            Top := 1;
        if Top > 100 then
            Top := 100;

        if Data.Get('status', Tok) and JsonRead.IsNonNullValue(Tok) then
            // An unrecognized status name matches nothing rather than erroring — the filter is a
            // convenience, not a contract, so a typo yields an empty list, never someone else's rows.
            if TryMapStatus(Tok.AsValue().AsText(), StatusValue) then
                HasStatusFilter := true
            else begin
                Clear(Response);
                Response.Add('value', Arr);
                Cost := 0;
                exit(true);
            end;

        // Newest first, scoped to the caller: the (Caller, Entry No.) key serves both the range and the
        // descending order, so the scan touches only this caller's rows.
        Row.SetCurrentKey(Caller, "Entry No.");
        Row.Ascending(false);
        Row.SetRange(Caller, UserSecurityId());
        if HasStatusFilter then
            Row.SetRange(Status, StatusValue);

        if Row.FindSet() then
            repeat
                Arr.Add(OpStatus.ProjectRow(Row));
                Returned += 1;
            until (Returned >= Top) or (Row.Next() = 0);

        Clear(Response);
        Response.Add('value', Arr);
        Cost := Returned;
        exit(true);
    end;

    local procedure TryMapStatus(Name: Text; var Status: Enum "Bcmag Request Status"): Boolean
    begin
        case LowerCase(Name) of
            'queued':
                Status := Status::Queued;
            'scheduled':
                Status := Status::Scheduled;
            'running':
                Status := Status::Running;
            'succeeded':
                Status := Status::Succeeded;
            'failed':
                Status := Status::Failed;
            'cancelled':
                Status := Status::Cancelled;
            'expired':
                Status := Status::Expired;
            else
                exit(false);
        end;
        exit(true);
    end;
}
