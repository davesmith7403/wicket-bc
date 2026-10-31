table 94116 "Bcmag Field Change"
{
    // One changed field of a change history entry: its old and new value as the field policy showed
    // that field when it changed (masked stays masked; hidden keeps no values), cut at Setup "Max
    // Value Length". Values are copies of business data, so they follow the policy again when read.
    Caption = 'Wicket Field Change';
    DataClassification = SystemMetadata;

    fields
    {
        field(1; "Entry No."; BigInteger) { Caption = 'Entry No.'; TableRelation = "Bcmag Change Entry"; }
        field(2; "Line No."; Integer) { Caption = 'Line No.'; }
        field(3; "Field No."; Integer) { Caption = 'Field No.'; }
        field(4; "Field Name"; Text[30]) { Caption = 'Field'; }
        field(5; "Old Value"; Text[2048]) { Caption = 'Old Value'; DataClassification = CustomerContent; }
        field(6; "New Value"; Text[2048]) { Caption = 'New Value'; DataClassification = CustomerContent; }
        field(7; "Stored As"; Enum "Bcmag Read Access") { Caption = 'Stored As'; }
        field(8; Truncated; Boolean) { Caption = 'Cut'; }
    }

    keys
    {
        key(PK; "Entry No.", "Line No.") { Clustered = true; }
    }
}
