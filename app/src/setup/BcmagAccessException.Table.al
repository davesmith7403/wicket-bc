table 94113 "Bcmag Access Exception"
{
    // Per-user read exceptions with an optional validity window. A row replaces the baseline verdict
    // (and mask profile) for one user: Scope = Field for one table field, Scope = Classification for
    // every field of one data classification; a field-scope row wins over a classification-scope row.
    // An exception can loosen (Masked → Clear) or tighten (Clear → Hidden). Blank Valid From / Valid
    // Until are open-ended. Exceptions govern reading only — writability never follows them.
    Caption = 'Wicket Access Exception';
    DataClassification = SystemMetadata;
    LookupPageId = "Bcmag Access Exceptions";
    DrillDownPageId = "Bcmag Access Exceptions";

    fields
    {
        field(1;  "Entry No.";        Integer)  { Caption = 'Entry No.'; AutoIncrement = true; }
        field(2;  "User Security ID"; Guid)
        {
            Caption = 'User Security ID';
            TableRelation = User."User Security ID";
            NotBlank = true;
            DataClassification = EndUserPseudonymousIdentifiers;
        }
        field(3;  "User Name";        Code[50])
        {
            Caption = 'User Name';
            FieldClass = FlowField;
            CalcFormula = lookup(User."User Name" where("User Security ID" = field("User Security ID")));
            Editable = false;
        }
        field(4;  Scope;              Option)   { Caption = 'Scope'; OptionMembers = Classification,Field; OptionCaption = 'Classification,Field'; }
        // Scope = Classification
        field(5;  "Data Class";       Enum "Bcmag Data Class") { Caption = 'Data Class'; }
        // Scope = Field
        field(6;  "Table Id";         Integer)  { Caption = 'Table Id'; }
        field(7;  "Field No.";        Integer)  { Caption = 'Field No.'; }
        field(10; "Read Access";      Enum "Bcmag Read Access") { Caption = 'Read Access'; }
        field(11; "Mask Profile";     Code[20]) { Caption = 'Mask Profile'; TableRelation = "Bcmag Mask Profile"; }
        field(20; "Valid From";       DateTime) { Caption = 'Valid From'; }
        field(21; "Valid Until";      DateTime) { Caption = 'Valid Until'; }
        field(30; Reason;             Text[250]) { Caption = 'Reason'; }
    }

    keys
    {
        key(PK; "Entry No.") { Clustered = true; }
        key(User; "User Security ID", Scope) { }
    }
}
