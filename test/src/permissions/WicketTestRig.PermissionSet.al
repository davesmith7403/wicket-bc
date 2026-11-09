permissionset 94300 "Wicket Test Rig"
{
    // What a test needs to keep running while the Permissions Mock has replaced the session's
    // permission sets with exactly one Wicket rung: execute on the test objects themselves, and the
    // test app's own table as the "business table" a caller writes. It grants nothing on any Wicket
    // object or table, so the rung under test is the only source of those.
    Assignable = true;
    Caption = 'Wicket Test Rig';
    Permissions =
        table "Bcmag Test Record" = X,
        tabledata "Bcmag Test Record" = RIMD,
        codeunit "Bcmag Restricted Identity Test" = X,
        codeunit "Bcmag Test Helper" = X,
        codeunit "Permissions Mock" = X,
        codeunit "Library Assert" = X;
}
