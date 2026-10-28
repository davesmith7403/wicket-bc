permissionset 94110 "Wicket Data - Read"
{
    // READ ANY INFORMATION, one assignment. "Wicket - Read" (the RPC read plane) plus direct Read on
    // ALL table data and Execute on all table, page and query objects — so the principal can read
    // through Wicket, through the standard api/v2.0 pages, and through any published OData page or
    // query, but cannot insert, modify or delete anything, and cannot run codeunits, reports or
    // xmlports (those are "Wicket Data - Exec").
    //
    // Wildcards are generic by design (the platform accepts no per-extension scope for them):
    //   - `tabledata * = R` spans EVERY extension and system table in the tenant, including user,
    //     access-control and setup tables — "any information" means exactly that.
    //   - Inside Wicket the deny-by-default gates still apply: a table must be exposed for read (or
    //     Mode = Open) and the field policy still filters columns. The wildcard only supplies the
    //     BC-side R that those gates require in addition.
    //   - Page/query Execute is a UI/API surface grant; a page never writes on its own, and with R-only
    //     table data the platform refuses any save.
    // Third-party (AppSource) tables additionally need the publisher's entitlement to answer an S2S
    // token — no permission set can supply that.
    Assignable = true;
    Caption = 'Wicket Data - Read';
    IncludedPermissionSets = "Wicket - Read";
    Permissions =
        tabledata * = R,
        table * = X,
        page * = X,
        query * = X;
}
