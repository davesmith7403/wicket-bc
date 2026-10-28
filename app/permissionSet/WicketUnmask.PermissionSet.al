permissionset 94112 "Wicket - Unmask"
{
    // DATA GRANT: lifts Masked fields to Clear for the principal holding it — for every
    // classification, and only while Setup "Unmask Tier Enabled" is on. Hidden fields stay hidden and
    // a per-user exception still overrides it. The field policy asks Record.WritePermission on the
    // empty "Bcmag Unmask Gate" sentinel, so this set is exactly that one grant.
    //
    // Standalone and NOT included by "Wicket - Admin": administering the policy and reading the data it
    // protects are separate decisions. Assign it next to a data-plane rung (Read / Execute / Edit).
    // A tabledata wildcard (the Data sets) yields Read only and therefore never opens the tier; SUPER,
    // which holds every permission, is the reason the Setup switch exists.
    // For an unmask grant narrower than "every classification", use per-user rows in
    // "Bcmag Access Exception" instead.
    Assignable = true;
    Caption = 'Wicket - Unmask';
    Permissions =
        tabledata "Bcmag Unmask Gate" = RIMD;
}
