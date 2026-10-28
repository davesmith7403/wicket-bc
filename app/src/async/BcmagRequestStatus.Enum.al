enum 94104 "Bcmag Request Status"
{
    // Lifecycle of an async delivery request. Terminal states are Succeeded/Failed/Cancelled/Expired.
    Extensible = false;

    value(0; Queued) { Caption = 'Queued'; }          // accepted, immediate worker starting
    value(1; Scheduled) { Caption = 'Scheduled'; }    // accepted, waiting for its NotBefore time
    value(2; Running) { Caption = 'Running'; }        // worker is producing the package
    value(3; Succeeded) { Caption = 'Succeeded'; }    // package written, URL live
    value(4; Failed) { Caption = 'Failed'; }          // worker or upload failed (see Problem/Last Error)
    value(5; Cancelled) { Caption = 'Cancelled'; }    // cancelled before or during execution
    value(6; Expired) { Caption = 'Expired'; }        // package retention elapsed, blob removed
}
