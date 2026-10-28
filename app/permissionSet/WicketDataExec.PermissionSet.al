permissionset 94111 "Wicket Data - Exec"
{
    // READ + EXECUTE, NO GENERIC WRITES. "Wicket - Execute" (RPC read plane + invoke/action) and
    // "Wicket Data - Read" (Read on all table data, Execute on tables/pages/queries), plus Execute on
    // ALL codeunits, reports and xmlports. Direct table-data rights stay Read-only everywhere; the
    // only writable tables are Wicket's own logging/queue tables (Insert on the operation and
    // idempotency logs, Insert/Modify on the request queue and idempotency reservation — via
    // "Wicket - Read") and the Execute Gate sentinel (via "Wicket - Execute").
    //
    // READ THIS BEFORE ASSIGNING IT IN PRODUCTION.
    // 1. `codeunit * = X` reaches EVERY codeunit — including Wicket's own insert/modify/delete handlers.
    //    A permission set cannot carve an exception out of a wildcard. What keeps the generic RPC
    //    write plane closed to this role is NOT this set's shape but the dispatcher's role gate: it
    //    routes insert/modify/delete only for principals that can write the "Bcmag Write Gate"
    //    sentinel, which this set does not grant (the tabledata wildcard yields Read only). A caller
    //    holding this set gets 403 role-forbidden on those operations even if some OTHER assigned set
    //    gives them business-table write rights.
    // 2. Execute on an object that carries its own `Permissions` property lets that object write while
    //    it runs — that is how the standard posting routines create ledger entries for users who hold
    //    no ledger permission. `tabledata * = R` + `codeunit * = X` is therefore "cannot write
    //    directly", not "cannot cause a write": a wrapper enrolled for invoke/action can post or
    //    otherwise change data through such a codeunit. Treat the enrolment of every wrapper as the
    //    real write grant.
    // 3. Permission sets are ADDITIVE. This set restricts nothing a principal holds elsewhere; it only
    //    adds. Do not read it as a ceiling.
    // Least-privilege alternative for production: "Wicket Data - Read" + "Wicket - Execute" + the
    // provider's own wrapper set (e.g. "Wicket Act"), which names exactly the codeunits in scope.
    Assignable = true;
    Caption = 'Wicket Data - Execute';
    IncludedPermissionSets = "Wicket - Execute", "Wicket Data - Read";
    Permissions =
        codeunit * = X,
        report * = X,
        xmlport * = X;
}
