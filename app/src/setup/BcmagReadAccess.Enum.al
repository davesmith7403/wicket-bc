enum 94109 "Bcmag Read Access"
{
    // The three-way read verdict of the field policy. Hidden: the field does not exist for the caller
    // (403 field-restricted, omitted from describe). Masked: the field is emitted, but only as the
    // rendering of its mask profile, and cannot be filtered, sorted or aggregated on. Clear: the value
    // itself. The ordinals rank the verdicts from most to least restrictive; code that compares them
    // still maps through an explicit case rather than relying on that order.
    Extensible = false;
    Caption = 'Wicket Read Access';

    value(0; Hidden) { Caption = 'Hidden'; }
    value(1; Masked) { Caption = 'Masked'; }
    value(2; Clear)  { Caption = 'Clear'; }
}
