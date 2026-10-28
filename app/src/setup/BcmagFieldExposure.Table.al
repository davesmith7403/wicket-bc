table 94105 "Bcmag Field Exposure"
{
    // Per-field override of the field policy (ignored in AllFields mode). A row replaces the
    // classification rule for one field — and in Explicit mode a row is the only way a field becomes
    // visible at all. Read Access defaults to Clear because an override row is usually a grant;
    // Mask Profile only matters when Read Access = Masked (blank = the built-in partial mask).
    // Allow Write is independent of Read Access: a Masked field can be writable without ever being
    // readable in clear.
    Caption = 'Wicket Field Exposure';
    DataClassification = SystemMetadata;
    LookupPageId = "Bcmag Field Exposure List";
    DrillDownPageId = "Bcmag Field Exposure List";

    fields
    {
        field(1;  "Table Id";     Integer)   { Caption = 'Table Id'; NotBlank = true; }
        field(2;  "Field No.";    Integer)   { Caption = 'Field No.'; NotBlank = true; }
        field(11; "Allow Write";  Boolean)   { Caption = 'Allow Write'; }
        field(12; "Read Access";  Enum "Bcmag Read Access") { Caption = 'Read Access'; InitValue = Clear; }
        field(13; "Mask Profile"; Code[20])  { Caption = 'Mask Profile'; TableRelation = "Bcmag Mask Profile"; }
        field(20; "Description";  Text[100]) { Caption = 'Description'; }
    }

    keys { key(PK; "Table Id", "Field No.") { Clustered = true; } }
}
