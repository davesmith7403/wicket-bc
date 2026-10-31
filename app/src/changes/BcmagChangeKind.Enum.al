enum 94114 "Bcmag Change Kind"
{
    // What one change history entry records: a record the agent created, changed or deleted through
    // Wicket, or an action or enrolled procedure it ran.
    Extensible = false;
    Caption = 'Wicket Change Kind';

    value(0; Created) { Caption = 'Created'; }
    value(1; Changed) { Caption = 'Changed'; }
    value(2; Deleted) { Caption = 'Deleted'; }
    value(3; Action) { Caption = 'Action'; }
    value(4; ProcedureRun) { Caption = 'Procedure'; }
}
