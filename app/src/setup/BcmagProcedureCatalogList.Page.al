page 94104 "Bcmag Procedure Catalog List"
{
    PageType = List;
    SourceTable = "Bcmag Procedure Catalog";
    Caption = 'Wicket Procedure Catalog';
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
                field(LogicalCodeunitId; Rec."Logical Codeunit Id") { ApplicationArea = All; }
                field(ProcedureName; Rec."Procedure Name") { ApplicationArea = All; }
                field(WrapperCodeunitId; Rec."Wrapper Codeunit Id") { ApplicationArea = All; }
                field(ReturnShape; Rec."Return Shape") { ApplicationArea = All; }
                field(AllowRun; Rec."Allow Run") { ApplicationArea = All; }
                field(Description; Rec.Description) { ApplicationArea = All; }
            }
        }
    }
}
