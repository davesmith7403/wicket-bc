page 94111 "Bcmag Access Exceptions"
{
    PageType = List;
    SourceTable = "Bcmag Access Exception";
    Caption = 'Wicket Access Exceptions';
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
                field(EntryNo;        Rec."Entry No.")        { ApplicationArea = All; ToolTip = 'The entry number.'; Visible = false; }
                field(UserSecurityId; Rec."User Security ID") { ApplicationArea = All; ToolTip = 'The user the exception applies to.'; }
                field(UserName;       Rec."User Name")        { ApplicationArea = All; ToolTip = 'The user name of the user the exception applies to.'; }
                field(Scope;          Rec.Scope)              { ApplicationArea = All; ToolTip = 'Classification: every field of one data classification. Field: one table field (wins over a classification exception).'; }
                field(DataClass;      Rec."Data Class")       { ApplicationArea = All; ToolTip = 'The data classification, when Scope is Classification.'; }
                field(TableId;        Rec."Table Id")         { ApplicationArea = All; ToolTip = 'The table, when Scope is Field.'; }
                field(FieldNo;        Rec."Field No.")        { ApplicationArea = All; ToolTip = 'The field number, when Scope is Field.'; }
                field(ReadAccess;     Rec."Read Access")      { ApplicationArea = All; ToolTip = 'The verdict that replaces the baseline for this user. It can loosen (Masked to Clear) or tighten (Clear to Hidden). Reading only; writes are unaffected.'; }
                field(MaskProfile;    Rec."Mask Profile")     { ApplicationArea = All; ToolTip = 'How the value is masked when Read Access is Masked. Blank uses the built-in partial mask.'; }
                field(ValidFrom;      Rec."Valid From")       { ApplicationArea = All; ToolTip = 'When the exception starts. Blank: already active.'; }
                field(ValidUntil;     Rec."Valid Until")      { ApplicationArea = All; ToolTip = 'When the exception ends. Blank: no end.'; }
                field(Reason;         Rec.Reason)             { ApplicationArea = All; ToolTip = 'Why the exception was granted.'; }
            }
        }
    }
}
