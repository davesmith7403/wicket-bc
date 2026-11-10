permissionset 94301 "Wicket Test Unshared"
{
    // Exists so the unshared test table is covered by a permission set (the per-tenant-extension rule).
    // The restricted-identity tests never assign it: that table must stay unreadable to a principal
    // holding only a Wicket rung and the test rig.
    Assignable = true;
    Caption = 'Wicket Test Unshared';
    Permissions =
        table "Bcmag Test Unshared Record" = X,
        tabledata "Bcmag Test Unshared Record" = RIMD;
}
