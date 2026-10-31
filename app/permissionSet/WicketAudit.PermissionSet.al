permissionset 94106 "Wicket - Audit"
{
    // CONTROL-PLANE VIEWER (support, security review, auditors). Opens every Wicket admin page and
    // reads every Wicket table — the operation log, the idempotency log, the request queue, the
    // exposure allowlist, the catalogs and the setup card — but cannot change any of it: no I/M/D,
    // no log purge, no credential prompt. The queue page's Cancel action fails at the platform
    // Modify check for this role, and the setup card opens read-only.
    //
    // Note the log/queue tables hold EVERY principal's rows (request ids, origins, problem details,
    // package URLs that may embed a SAS token); that is the point of an audit role, and why the
    // data-plane roles do not get these pages.
    Assignable = true;
    Caption = 'Wicket - Audit';
    IncludedPermissionSets = "Wicket - Objects", "Wicket - Changes";
    Permissions =
        tabledata "Bcmag Setup" = R,
        tabledata "Bcmag Exposure" = R,
        tabledata "Bcmag Field Exposure" = R,
        tabledata "Bcmag Classification Rule" = R,
        tabledata "Bcmag Mask Profile" = R,
        tabledata "Bcmag Access Exception" = R,
        tabledata "Bcmag Procedure Catalog" = R,
        tabledata "Bcmag Action Catalog" = R,
        tabledata "Bcmag Operation Log" = R,
        tabledata "Bcmag Idempotency Log" = R,
        tabledata "Bcmag Idempotency Reservation" = R,
        tabledata "Bcmag Request Queue" = R,
        page "Bcmag Setup Card" = X,
        page "Bcmag Exposure List" = X,
        page "Bcmag Field Exposure List" = X,
        page "Bcmag Classification Rules" = X,
        page "Bcmag Mask Profiles" = X,
        page "Bcmag Access Exceptions" = X,
        page "Bcmag Procedure Catalog List" = X,
        page "Bcmag Action Catalog List" = X,
        page "Bcmag Operation Log List" = X,
        page "Bcmag Request Queue List" = X;
}
