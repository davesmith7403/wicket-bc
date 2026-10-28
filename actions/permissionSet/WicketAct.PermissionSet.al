permissionset 94200 "Wicket Act"
{
    // Makes the companion's wrappers REACHABLE — nothing more. It grants Execute on the wrapper and
    // posting codeunits plus Read on the tables the wrappers inspect. It deliberately grants NO write
    // access anywhere: enrolment into the Wicket control tables (Procedure Catalog / Action Catalog /
    // Exposure) happens in the install codeunit, which runs in system context and needs no assigned
    // set — granting an assignee IMD there would hand them the allowlist (privilege escalation).
    // Likewise, ALL posting data permissions (RIMD on documents, journals, ledgers) must come from the
    // standard Business Central posting permission sets assigned to the calling principal; the wrappers
    // only read the headers/lines, and the posting codeunits do the writes under those standard sets.
    // Composes with the core's ladder: the calling principal needs at least "Wicket - Execute" (Execute
    // on the invoke/action handlers) plus this set; "Wicket - Read" alone cannot reach a wrapper.
    Assignable = true;
    Caption = 'Wicket Actions';
    Permissions =
        codeunit "Bcmag Act Post Sales Doc" = X,
        codeunit "Bcmag Act Post Purchase Doc" = X,
        codeunit "Bcmag Act Post Gen Journal" = X,
        codeunit "Bcmag Act Post Item Journal" = X,
        codeunit "Bcmag Act Helper" = X,
        codeunit "Bcmag Act Release Sales Doc" = X,
        codeunit "Bcmag Act Reopen Sales Doc" = X,
        codeunit "Bcmag Act Release Purch Doc" = X,
        codeunit "Bcmag Act Reopen Purch Doc" = X,
        codeunit "Bcmag Act Doc Resolver" = X,
        codeunit "Bcmag Act Sales Quote To Order" = X,
        codeunit "Bcmag Act Sales Quote To Inv" = X,
        codeunit "Bcmag Act Purch Quote To Order" = X,
        codeunit "Bcmag Act Document Pdf" = X,
        codeunit "Bcmag Act Item Availability" = X,
        codeunit "Bcmag Act Preview" = X,
        codeunit "Bcmag Act Preview Capture" = X,
        codeunit "Bcmag Act Install" = X,
        // Wicket core objects the wrappers/install use.
        codeunit "Bcmag Invoke Context" = X,
        tabledata "Bcmag Procedure Catalog" = R,   // read-only visibility; enrolment is install-time (system context)
        tabledata "Bcmag Action Catalog" = R,      // read-only visibility; enrolment is install-time (system context)
        tabledata "Bcmag Exposure" = R,            // read-only visibility; self-exposure is install-time (system context)
        // Base App posting entry points invoked by the wrappers.
        codeunit "Sales-Post" = X,
        codeunit "Purch.-Post" = X,
        codeunit "Gen. Jnl.-Post Batch" = X,
        codeunit "Item Jnl.-Post Batch" = X,
        codeunit "Release Sales Document" = X,
        codeunit "Release Purchase Document" = X,
        codeunit "Sales-Quote to Order" = X,
        codeunit "Sales-Quote to Invoice" = X,
        codeunit "Purch.-Quote to Order" = X,
        codeunit "Available to Promise" = X,
        // Posting previews run Business Central's own preview engine (no writes survive it).
        codeunit "Gen. Jnl.-Post Preview" = X,
        codeunit "Posting Preview Event Handler" = X,
        codeunit "Sales-Post (Yes/No)" = X,
        codeunit "Purch.-Post (Yes/No)" = X,
        codeunit "Gen. Jnl.-Post" = X,
        codeunit "Item Jnl.-Post" = X,
        // Read-only: the wrappers only locate/inspect the document or batch. Writes and deletes during
        // posting run under the caller's standard BC posting permission sets — not granted here.
        tabledata "Sales Header" = R,
        tabledata "Purchase Header" = R,
        tabledata "Gen. Journal Line" = R,
        tabledata "Item Journal Line" = R,
        // Batch existence checks and post-run register read-back (posting evidence).
        tabledata "Gen. Journal Batch" = R,
        tabledata "Item Journal Batch" = R,
        tabledata "G/L Register" = R,
        tabledata "Item Register" = R,
        // Journal guards replicated from Gen. Jnl.-Post / Item Jnl.-Post (Force Posting Report, Job WIP).
        tabledata "Gen. Journal Template" = R,
        tabledata "Item Journal Template" = R,
        tabledata "Source Code Setup" = R,
        // Post-commit evidence: a posted document for the source, found when posting reported an error
        // after its commit (the source header is already deleted then).
        tabledata "Sales Invoice Header" = R,
        tabledata "Sales Cr.Memo Header" = R,
        tabledata "Sales Shipment Header" = R,
        tabledata "Return Receipt Header" = R,
        tabledata "Purch. Inv. Header" = R,
        tabledata "Purch. Cr. Memo Hdr." = R,
        tabledata "Purch. Rcpt. Header" = R,
        tabledata "Return Shipment Header" = R,
        // Quote conversion refuses a quote tied to an opportunity in progress; document-pdf picks the
        // report from Report Selections; item-availability reads the item and the company's look-ahead.
        tabledata Opportunity = R,
        tabledata "Report Selections" = R,
        tabledata Item = R,
        tabledata "Company Information" = R;
}
