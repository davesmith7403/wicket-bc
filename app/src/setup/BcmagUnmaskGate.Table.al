table 94114 "Bcmag Unmask Gate"
{
    // Unmask-tier sentinel, never holds a row. Only "Wicket - Unmask" grants RIMD on it — deliberately
    // NOT "Wicket - Admin": unmasking is a data grant, not an administrative one. The field policy asks
    // Record.WritePermission on this table to decide whether a Masked verdict is lifted to Clear for
    // the caller, and only while Setup "Unmask Tier Enabled" is on (SUPER holds every table
    // permission, so that switch is how a tenant — or the test suite — keeps SUPER from unmasking).
    // A tabledata wildcard (the Data sets) yields Read only, which does not open the tier.
    Caption = 'Wicket Unmask Gate';
    DataClassification = SystemMetadata;
    Access = Public;

    fields
    {
        field(1; "Primary Key"; Code[10]) { Caption = 'Primary Key'; DataClassification = SystemMetadata; }
    }

    keys
    {
        key(PK; "Primary Key") { Clustered = true; }
    }
}
