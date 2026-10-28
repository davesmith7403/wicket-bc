table 94103 "Bcmag Idempotency Log"
{
    Caption = 'Wicket Idempotency Log';
    DataClassification = SystemMetadata;

    fields
    {
        field(1; "Entry No.";       BigInteger){ Caption = 'Entry No.'; AutoIncrement = true; }
        field(2; "Idempotency Key"; Text[128]) { Caption = 'Idempotency Key'; NotBlank = true; }
        field(3; "Request Id";      Text[64])  { Caption = 'Request Id'; }
        field(4; "Body Hash";       Text[64])  { Caption = 'Body Hash'; }
        field(5; "Logged At";       DateTime)  { Caption = 'Logged At'; }
        // v1.2 replay snapshot: rows carrying a Response replay verbatim on a key+hash match.
        // Rows without a Response (legacy v1, or never written because the outcome was 5xx)
        // are invisible to replay lookup, so they can neither replay nor raise a 409.
        field(6; Operation;         Text[30])  { Caption = 'Operation'; }
        field(7; Status;            Integer)   { Caption = 'Status'; }
        // The stored response is business data (query rows, posted document numbers), not metadata.
        field(8; Response;          Blob)      { Caption = 'Response'; Subtype = Memo; DataClassification = CustomerContent; }
        // Calling principal (UserSecurityId()). Replay is scoped to this so one user can NEVER
        // see or conflict with another user's cached row (confused-deputy / stale-authz leak).
        // A Guid is legal in a key. Legacy v1.2 rows carry an empty Guid: FindReplay filters on
        // Caller = UserSecurityId(), so those rows match no one and simply fall through to
        // execution — fail-safe, they can never be replayed to the wrong caller.
        field(9; Caller;            Guid)      { Caption = 'Caller'; }
    }

    keys
    {
        key(PK;        "Entry No.")                    { Clustered = true; }
        key(IdemKey;   "Idempotency Key", Caller)      { }
    }
}
