codeunit 94144 "Bcmag Op Who Am I"
{
    // "whoAmI" operation: identify the calling principal and the endpoint posture in one call —
    // who BC thinks the caller is, which company the request landed in, and the switches that
    // change plane behavior (read-only, field policy and the caller's unmask grants, strong etag).
    // No required data.
    // Non-mutating; every value is already visible to the caller through capabilities or the
    // session itself, so no exposure/field-policy gate applies.

    var
        Setup: Record "Bcmag Setup";

    procedure Run(Data: JsonObject; var Response: JsonObject; var Fail: JsonObject; var Cost: Integer): Boolean
    var
        OpCapabilities: Codeunit "Bcmag Op Capabilities";
        FieldPolicy: Codeunit "Bcmag Field Policy";
        Result: JsonObject;
    begin
        Cost := 1;
        Setup.GetSingleton();
        // Guid emitted in the projector's wire format (lowercase, no braces); datetime in the
        // ISO 8601 round-trip form every other op uses; fieldPolicy via the same invariant
        // case map capabilities emits — never Format(enum), which is locale-dependent.
        Result.Add('userSecurityId', LowerCase(DelChr(Format(UserSecurityId()), '<>', '{}')));
        Result.Add('userId', UserId());
        Result.Add('company', CompanyName());
        Result.Add('readOnly', Setup."Read-Only Mode");
        Result.Add('fieldPolicy', OpCapabilities.FieldPolicyModeName(Setup."Field Policy Mode"));
        // The caller's own grants: whether the Unmask tier lifts masks for them right now, and how
        // many of their per-user exceptions are active — so "why do I see this value in clear?" has
        // an answer without admin access to the exception table.
        Result.Add('unmaskGranted', FieldPolicy.UnmaskGranted());
        Result.Add('activeExceptions', FieldPolicy.ActiveExceptionCount());
        Result.Add('strongEtag', Setup."Strong ETag");
        Result.Add('serverTime', Format(CurrentDateTime(), 0, 9));
        Clear(Response);
        Response.Add('value', Result);
        exit(true);
    end;
}
