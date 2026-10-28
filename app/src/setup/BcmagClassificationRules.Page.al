page 94109 "Bcmag Classification Rules"
{
    PageType = List;
    SourceTable = "Bcmag Classification Rule";
    Caption = 'Wicket Classification Rules';
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
                field(DataClass;   Rec."Data Class")   { ApplicationArea = All; ToolTip = 'The data classification this rule governs. Fields carry their classification in table metadata.'; }
                field(ReadAccess;  Rec."Read Access")  { ApplicationArea = All; ToolTip = 'Hidden: the field is invisible to callers. Masked: the field is returned masked and cannot be filtered or sorted on. Clear: the value is returned as is. Applies in By Classification mode to every field without a field exposure row.'; }
                field(MaskProfile; Rec."Mask Profile") { ApplicationArea = All; ToolTip = 'How a Masked value is rendered. Blank uses the built-in partial mask (the last 2 characters kept).'; }
            }
        }
    }
}
