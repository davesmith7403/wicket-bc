permissionset 94113 "Wicket - Changes"
{
    // CHANGE HISTORY AUDITOR. Read every principal's change history: the Wicket Changes page, and the
    // changes operation with a user filter (the Changes Gate). Without it, the changes operation answers
    // a caller's own entries only. Included in "Wicket - Audit" and "Wicket - Admin".
    Assignable = true;
    Caption = 'Wicket - Audit Changes';
    // Assignable on its own: the two pages read Setup and render every value through the field policy
    // and the masker, so the set carries the object rung and read on the policy tables. It grants no
    // rung sentinel, so by itself it opens no data-plane operation.
    IncludedPermissionSets = "Wicket - Objects";
    Permissions =
        tabledata "Bcmag Setup" = R,
        tabledata "Bcmag Field Exposure" = R,
        tabledata "Bcmag Classification Rule" = R,
        tabledata "Bcmag Mask Profile" = R,
        tabledata "Bcmag Access Exception" = R,
        tabledata "Bcmag Change Entry" = R,
        tabledata "Bcmag Field Change" = R,
        tabledata "Bcmag Changes Gate" = RIMD,
        page "Bcmag Changes" = X,
        page "Bcmag Field Changes" = X;
}
