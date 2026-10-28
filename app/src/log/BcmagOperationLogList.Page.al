page 94103 "Bcmag Operation Log List"
{
    PageType = List;
    SourceTable = "Bcmag Operation Log";
    Caption = 'Wicket Operation Log';
    UsageCategory = History;
    ApplicationArea = All;
    Editable = false;
    SourceTableView = sorting("Entry No.") order(descending);

    layout
    {
        area(content)
        {
            repeater(Group)
            {
                field(EntryNo;       Rec."Entry No.")        { ApplicationArea = All; }
                field(StartedAt;     Rec."Started At")       { ApplicationArea = All; }
                field(Operation;     Rec.Operation)          { ApplicationArea = All; }
                field(TableId;       Rec."Table Id")         { ApplicationArea = All; ToolTip = 'The table the request addressed, when it named one.'; }
                field(Target;        Rec.Target)             { ApplicationArea = All; ToolTip = 'For invoke the codeunit and procedure, for action the action code, for describe of a codeunit or API its id, for status and cancel the async request id.'; }
                field(RequestDetails; Rec."Request Details") { ApplicationArea = All; ToolTip = 'The request''s select, filter, orderBy, top, change window and aggregate, and the field names a write set (never their values). Recorded while Wicket Setup "Log Request Details" is on.'; }
                field(Status;        Rec.Status)             { ApplicationArea = All; }
                field(Cost;          Rec.Cost)               { ApplicationArea = All; }
                field(Caller;        Rec.Caller)             { ApplicationArea = All; }
                field(Origin;        Rec.Origin)             { ApplicationArea = All; }
                field(RequestId;     Rec."Request Id")       { ApplicationArea = All; }
                field(IdempotencyKey;Rec."Idempotency Key")  { ApplicationArea = All; }
                field(ProblemType;   Rec."Problem Type")     { ApplicationArea = All; }
                field(ProblemDetail; Rec."Problem Detail")   { ApplicationArea = All; }
                field(UnmaskedFields;Rec."Unmasked Fields")  { ApplicationArea = All; ToolTip = 'Fields (table:field) this request read in clear although the caller''s baseline masks them, lifted by a user exception or the Unmask permission tier. Recorded for query and readBlob only; ",+N" means N more were left out.'; }
            }
        }
    }
}
