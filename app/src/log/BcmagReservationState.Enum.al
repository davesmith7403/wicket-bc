enum 94106 "Bcmag Reservation State"
{
    // Lifecycle of an execution reservation (see Bcmag Idempotency Reservation).
    Extensible = false;

    value(0; "In Progress") { Caption = 'In Progress'; }   // taken and committed; the operation may be running — or its session died
    value(1; Completed) { Caption = 'Completed'; }         // a FINAL outcome (2xx/4xx) was reached; the snapshot, if it landed, replays it
    value(2; Released) { Caption = 'Released'; }           // ended 5xx (retryable, nothing final): the next attempt may take the row over
}
