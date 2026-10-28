table 94111 "Bcmag Classification Rule"
{
    // The tenant's read posture per data classification, consulted in ByClassification mode for every
    // field without a per-field "Bcmag Field Exposure" row. One row per classification; a missing row
    // falls back to "Bcmag Policy Defaults".BuiltInRule (the same values install seeds), so deleting a
    // row restores the shipped default rather than opening or closing the classification by accident.
    // Mask Profile only matters when Read Access = Masked; blank means the built-in partial mask.
    Caption = 'Wicket Classification Rule';
    DataClassification = SystemMetadata;
    LookupPageId = "Bcmag Classification Rules";
    DrillDownPageId = "Bcmag Classification Rules";

    fields
    {
        field(1;  "Data Class";   Enum "Bcmag Data Class")  { Caption = 'Data Class'; }
        field(10; "Read Access";  Enum "Bcmag Read Access") { Caption = 'Read Access'; }
        field(11; "Mask Profile"; Code[20])                 { Caption = 'Mask Profile'; TableRelation = "Bcmag Mask Profile"; }
    }

    keys { key(PK; "Data Class") { Clustered = true; } }
}
