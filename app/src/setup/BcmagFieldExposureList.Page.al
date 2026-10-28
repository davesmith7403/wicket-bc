page 94105 "Bcmag Field Exposure List"
{
    PageType = List;
    SourceTable = "Bcmag Field Exposure";
    Caption = 'Wicket Field Exposure';
    UsageCategory = Administration;
    ApplicationArea = All;
    InsertAllowed = true;
    ModifyAllowed = true;
    DeleteAllowed = true;

    layout
    {
        area(content)
        {
            repeater(Group)
            {
                field(TableId;     Rec."Table Id")   { ApplicationArea = All; }
                field(FieldNo;     Rec."Field No.")  { ApplicationArea = All; }
                field(ReadAccess;  Rec."Read Access") { ApplicationArea = All; ToolTip = 'Hidden, Masked or Clear for this one field, replacing its classification rule. In Explicit mode only fields with a row are visible.'; }
                field(MaskProfile; Rec."Mask Profile"){ ApplicationArea = All; ToolTip = 'How the value is masked when Read Access is Masked. Blank uses the built-in partial mask.'; }
                field(AllowWrite;  Rec."Allow Write") { ApplicationArea = All; }
                field(Description; Rec.Description)  { ApplicationArea = All; }
            }
        }
    }
}
