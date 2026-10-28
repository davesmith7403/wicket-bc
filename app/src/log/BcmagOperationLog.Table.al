table 94102 "Bcmag Operation Log"
{
    Caption = 'Wicket Operation Log';
    DataClassification = SystemMetadata;
    LookupPageId = "Bcmag Operation Log List";
    DrillDownPageId = "Bcmag Operation Log List";

    fields
    {
        field(1; "Entry No."; BigInteger) { Caption = 'Entry No.'; AutoIncrement = true; DataClassification = SystemMetadata; }
        // Request Id / Idempotency Key are caller-supplied opaque tokens (CustomerContent).
        field(10; "Request Id"; Text[64]) { Caption = 'Request Id'; DataClassification = CustomerContent; }
        field(11; "Idempotency Key"; Text[128]) { Caption = 'Idempotency Key'; DataClassification = CustomerContent; }
        field(12; "Operation"; Text[32]) { Caption = 'Operation'; DataClassification = SystemMetadata; }
        // Caller is a UPN / app-principal identity and Origin is caller-supplied free text;
        // both can carry user-identifying context, so they are EndUserIdentifiableInformation.
        field(13; "Caller"; Text[80]) { Caption = 'Caller'; DataClassification = EndUserIdentifiableInformation; }
        field(14; "Origin"; Text[256]) { Caption = 'Origin'; DataClassification = EndUserIdentifiableInformation; }
        field(15; "Status"; Integer) { Caption = 'Status'; DataClassification = SystemMetadata; }
        field(16; "Cost"; Integer) { Caption = 'Cost'; DataClassification = SystemMetadata; }
        field(17; "Started At"; DateTime) { Caption = 'Started At'; DataClassification = SystemMetadata; }
        field(18; "Ended At"; DateTime) { Caption = 'Ended At'; DataClassification = SystemMetadata; }
        field(19; "Problem Type"; Text[128]) { Caption = 'Problem Type'; DataClassification = SystemMetadata; }
        field(20; "Problem Detail"; Text[2048]) { Caption = 'Problem Detail'; DataClassification = CustomerContent; }
        field(21; "Duration (ms)"; Integer) { Caption = 'Duration (ms)'; DataClassification = SystemMetadata; }
        // "table:field" pairs this request read in clear although the caller's baseline masks them (a
        // user exception or the Unmask tier lifted them), e.g. "18:2,18:102"; ",+N" ends a list that was
        // cut short. Field numbers only — no values — and only for operations that return field values.
        field(22; "Unmasked Fields"; Text[250]) { Caption = 'Unmasked Fields'; DataClassification = SystemMetadata; }
        // What the request was about, always recorded because it carries no data values: the table it
        // addressed, and for invoke/action/describe-codeunit/status the procedure, action or request.
        field(23; "Table Id"; Integer) { Caption = 'Table Id'; DataClassification = SystemMetadata; }
        field(24; "Target"; Text[100]) { Caption = 'Target'; DataClassification = SystemMetadata; }
        // The request's shape (select, filter, orderBy, top, window, aggregate, the field NAMES a write
        // set — never their values) when Setup "Log Request Details" is on. A filter can carry a value
        // the caller searched for (a name, an e-mail), so this is customer content; it is purged with
        // the rest of the row after "Operation Log Retention Days".
        field(25; "Request Details"; Text[2048]) { Caption = 'Request Details'; DataClassification = CustomerContent; }
    }

    keys
    {
        key(PK; "Entry No.") { Clustered = true; }
        key(RequestId; "Request Id") { }
        key(IdemKey; "Idempotency Key") { }
        key(Started; "Started At") { }
        key(OpStatus; "Operation", "Status") { }
        key(TableStarted; "Table Id", "Started At") { }
    }
}
