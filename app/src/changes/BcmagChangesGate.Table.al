table 94117 "Bcmag Changes Gate"
{
    // Empty sentinel: WritePermission on it means "may read every principal's change history" — the
    // changes operation answers a caller's own entries otherwise. Only "Wicket - Audit Changes" (and the
    // sets that include it) grant it; the wildcard data sets grant tabledata R only, never M, so they
    // cannot open it by accident. Same pattern as the Unmask gate.
    Caption = 'Wicket Changes Gate';
    DataClassification = SystemMetadata;

    fields
    {
        field(1; "Primary Key"; Code[10]) { Caption = 'Primary Key'; }
    }

    keys { key(PK; "Primary Key") { Clustered = true; } }
}
