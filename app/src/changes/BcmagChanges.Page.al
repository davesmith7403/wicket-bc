page 94112 "Bcmag Changes"
{
    // Wicket Changes: what the agent created, changed or deleted through Wicket, and the actions and
    // procedures it ran — for the customer's admin. Select an entry to see its changed fields. Knock-on
    // changes in other records are in Business Central's Change Log (action below).
    PageType = List;
    SourceTable = "Bcmag Change Entry";
    SourceTableView = sorting("Entry No.") order(descending);
    Caption = 'Wicket Changes';
    UsageCategory = Administration;
    ApplicationArea = All;
    Editable = false;

    layout
    {
        area(Content)
        {
            group(Empty)
            {
                ShowCaption = false;
                Visible = HistoryOff;
                field(OffNote; OffTxt) { ApplicationArea = All; ShowCaption = false; Editable = false; Style = Attention; }
            }
            repeater(Entries)
            {
                field(CreatedAt; Rec."Created At") { ApplicationArea = All; Caption = 'When'; ToolTip = 'When the change was made.'; }
                field(Kind; Rec.Kind) { ApplicationArea = All; ToolTip = 'Created, Changed or Deleted record, or an Action or Procedure run.'; }
                field(TableName; Rec."Table Name") { ApplicationArea = All; ToolTip = 'The table of the record.'; }
                field(RecordKey; Rec."Record Key") { ApplicationArea = All; ToolTip = 'The record''s key.'; }
                field(Name; Rec.Name) { ApplicationArea = All; ToolTip = 'For an action or procedure run: which one.'; }
                field(FieldCount; Rec."Field Count") { ApplicationArea = All; ToolTip = 'How many fields changed.'; }
                field(Outcome; Rec.Outcome) { ApplicationArea = All; ToolTip = 'For an action or procedure run: Succeeded, or failed (it may still have changed data before it failed).'; }
                field(Result; Rec.Result) { ApplicationArea = All; ToolTip = 'For an action or procedure run: what it returned, cut to 250 characters.'; }
                field(UserId; Rec."User Id") { ApplicationArea = All; ToolTip = 'The Business Central user or app the agent signed in as.'; }
                field(Connection; Rec.Connection) { ApplicationArea = All; ToolTip = 'The name of the Wicket connection on the computer that made the change.'; }
                field(RequestId; Rec."Request Id") { ApplicationArea = All; Visible = false; ToolTip = 'The request in the Wicket Operation Log.'; }
            }
            part(Fields; "Bcmag Field Changes")
            {
                ApplicationArea = All;
                SubPageLink = "Entry No." = field("Entry No.");
            }
        }
    }

    actions
    {
        area(Navigation)
        {
            action(OperationLog)
            {
                ApplicationArea = All;
                Caption = 'Operation Log Entry';
                Image = Log;
                ToolTip = 'Open the request that made this change in the Wicket Operation Log.';
                trigger OnAction()
                var
                    OperationLog: Record "Bcmag Operation Log";
                begin
                    OperationLog.SetRange("Request Id", Rec."Request Id");
                    Page.Run(Page::"Bcmag Operation Log List", OperationLog);
                end;
            }
            action(ChangeLog)
            {
                ApplicationArea = All;
                Caption = 'Change Log';
                Image = ChangeLog;
                ToolTip = 'Open Business Central''s Change Log for this record: the changes Business Central made as a consequence, in other tables, for the tables the Change Log is set up for.';
                trigger OnAction()
                begin
                    Hyperlink(ChangeLogUrl());
                end;
            }
            action(OpenRecord)
            {
                ApplicationArea = All;
                Caption = 'Open Record';
                Image = Navigate;
                ToolTip = 'Open the record that changed, if it still exists.';
                trigger OnAction()
                var
                    TableMetadata: Record "Table Metadata";
                    RecRef: RecordRef;
                begin
                    // The table's default page, as the pageUrl operation picks it.
                    if (Rec."Table Id" = 0) or IsNullGuid(Rec."Record SystemId") then
                        Error(NoRecordErr);
                    RecRef.Open(Rec."Table Id");
                    if not RecRef.GetBySystemId(Rec."Record SystemId") then
                        Error(NoRecordErr);
                    if not TableMetadata.Get(Rec."Table Id") or (TableMetadata.LookupPageID = 0) then
                        Error(NoPageErr);
                    Hyperlink(GetUrl(ClientType::Web, CompanyName(), ObjectType::Page, TableMetadata.LookupPageID, RecRef));
                end;
            }
        }
        area(Processing)
        {
            action(DeleteFiltered)
            {
                ApplicationArea = All;
                Caption = 'Delete Filtered Entries';
                Image = Delete;
                ToolTip = 'Delete the entries the current filters show, with their changed fields (for example, set a filter on When first).';
                trigger OnAction()
                var
                    Entry: Record "Bcmag Change Entry";
                    FieldChange: Record "Bcmag Field Change";
                begin
                    Entry.CopyFilters(Rec);
                    if not Confirm(DeleteQst, false, Entry.Count()) then
                        exit;
                    if Entry.FindSet() then
                        repeat
                            FieldChange.SetRange("Entry No.", Entry."Entry No.");
                            FieldChange.DeleteAll();
                        until Entry.Next() = 0;
                    Entry.DeleteAll();
                end;
            }
        }
        area(Promoted)
        {
            actionref(OperationLog_Promoted; OperationLog) { }
            actionref(ChangeLog_Promoted; ChangeLog) { }
            actionref(OpenRecord_Promoted; OpenRecord) { }
        }
    }

    var
        HistoryOff: Boolean;
        OffTxt: Label 'The change history is off: switch on Record Changes on the Wicket Setup card to keep what the agent changes.';
        NoRecordErr: Label 'The record no longer exists, or this entry names none.';
        NoPageErr: Label 'This table has no page to open the record in.';
        DeleteQst: Label 'Delete %1 change history entries? This cannot be undone.', Comment = '%1 = number of entries';
        ChangeLogPageId: Integer;

    trigger OnOpenPage()
    var
        Setup: Record "Bcmag Setup";
    begin
        Setup.GetSingleton();
        HistoryOff := Setup."Record Changes" = Setup."Record Changes"::Off;
        ChangeLogPageId := 595; // Change Log Entries (Base Application; referenced by id, see design)
    end;

    // Business Central's Change Log Entries page, filtered to this record's table and first key value
    // through the web client's filter syntax, so the core app needs no Base Application dependency.
    local procedure ChangeLogUrl(): Text
    var
        FilterText: Text;
    begin
        FilterText := StrSubstNo('''Table No.'' IS ''%1''', Rec."Table Id");
        if Rec."Record Key" <> '' then
            FilterText += StrSubstNo(' AND ''Primary Key Field 1 Value'' IS ''%1''', FirstKeyValue(Rec."Record Key"));
        exit(GetUrl(ClientType::Web, CompanyName(), ObjectType::Page, ChangeLogPageId) + '&filter=' + FilterText);
    end;

    local procedure FirstKeyValue(KeyText: Text): Text
    var
        Comma: Integer;
    begin
        Comma := StrPos(KeyText, ', ');
        if Comma > 0 then
            exit(CopyStr(KeyText, 1, Comma - 1));
        exit(KeyText);
    end;
}
