enum 94107 "Bcmag Reservation Outcome"
{
    // What Bcmag Idempotency Guard.Reserve found for a (caller, key).
    Extensible = false;

    value(0; Reserved) { Caption = 'Reserved'; }         // this request now owns the key: execute
    value(1; "In Progress") { Caption = 'In Progress'; } // another request owns it and has not settled: refuse (409)
    value(2; Completed) { Caption = 'Completed'; }       // settled earlier; the snapshot should replay — if it is missing, the outcome is unknowable
    value(3; Stale) { Caption = 'Stale'; }               // In Progress far beyond any request lifetime: the owner died; outcome unknowable
    value(4; Conflict) { Caption = 'Conflict'; }         // Released row whose owning attempt carried a DIFFERENT body: the key belongs to another request (409)
}
