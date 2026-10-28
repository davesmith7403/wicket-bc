permissionset 94105 "Wicket - Edit"
{
    // DATA-PLANE FULL CALLER: read + execute + the generic write plane (insert / modify / delete).
    //
    // Like every Wicket set it grants no business-table data rights: a write still needs tabledata
    // I/M/D on the target table from the principal's other sets, the per-row Allow Insert/Modify/
    // Delete flag in Wicket Exposure (or Open mode), the field policy, and Read-Only Mode off.
    Assignable = true;
    Caption = 'Wicket - Edit';
    IncludedPermissionSets = "Wicket - Execute";
    Permissions =
        // Rung sentinel (empty table): RIMD here is what lets the dispatcher route insert/modify/delete
        // for this principal — the ONLY set below Admin that opens the generic write plane, whatever
        // codeunit wildcard or business-table write set the principal holds elsewhere.
        tabledata "Bcmag Write Gate" = RIMD,
        codeunit "Bcmag Op Insert" = X,
        codeunit "Bcmag Op Modify" = X,
        codeunit "Bcmag Op Delete" = X,
        codeunit "Bcmag Value Coercer" = X,   // typed coercion of caller values — write path only
        codeunit "Bcmag Record Access" = X;   // token -> record re-fetch + etag check — modify/delete only
}
