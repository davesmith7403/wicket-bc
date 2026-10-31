permissionset 94113 "Wicket - Changes"
{
    // CHANGE HISTORY AUDITOR. Read every principal's change history: the Wicket Changes page, and the
    // changes operation with a user filter (the Changes Gate). Without it, the changes operation answers
    // a caller's own entries only. Included in "Wicket - Audit" and "Wicket - Admin".
    Assignable = true;
    Caption = 'Wicket - Audit Changes';
    Permissions =
        tabledata "Bcmag Change Entry" = R,
        tabledata "Bcmag Field Change" = R,
        tabledata "Bcmag Changes Gate" = RIMD,
        page "Bcmag Changes" = X,
        page "Bcmag Field Changes" = X;
}
