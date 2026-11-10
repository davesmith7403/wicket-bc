permissionset 94350 "Wicket Act Test Rig"
{
    // What a companion test needs to keep running while the Permissions Mock has replaced the session's
    // permission sets: execute on the test objects themselves. It grants nothing on any Wicket or
    // Business Central object or table, so the sets under test are the only source of those.
    Assignable = true;
    Caption = 'Wicket Actions Test Rig';
    Permissions =
        codeunit "Bcmag Act Restricted Test" = X,
        codeunit "Bcmag Act Test Helper" = X,
        codeunit "Permissions Mock" = X,
        codeunit "Library Assert" = X;
}
