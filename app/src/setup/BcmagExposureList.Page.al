page 94102 "Bcmag Exposure List"
{
    PageType = List;
    SourceTable = "Bcmag Exposure";
    Caption = 'Wicket Exposure';
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
                field(ObjectType;   Rec."Object Type")  { ApplicationArea = All; }
                field(ObjectId;     Rec."Object Id")    { ApplicationArea = All; }
                field(AllowRead;    Rec."Allow Read")   { ApplicationArea = All; }
                field(AllowInsert;  Rec."Allow Insert") { ApplicationArea = All; }
                field(AllowModify;  Rec."Allow Modify") { ApplicationArea = All; }
                field(AllowDelete;  Rec."Allow Delete") { ApplicationArea = All; }
                field(AllowInvoke;  Rec."Allow Invoke") { ApplicationArea = All; }
                field(Description;  Rec.Description)    { ApplicationArea = All; }
            }
        }
    }
}
