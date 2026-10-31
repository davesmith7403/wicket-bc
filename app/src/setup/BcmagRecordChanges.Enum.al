enum 94113 "Bcmag Record Changes"
{
    // How much of what the agent changes Wicket keeps in its change history (Setup "Record Changes").
    // Off: nothing. Fields Only: which fields changed, never their values. Old and New Values: both, as
    // the field policy shows each field (masked stays masked, hidden shows only that it changed).
    Extensible = false;
    Caption = 'Wicket Record Changes';

    value(0; Off) { Caption = 'Off'; }
    value(1; FieldsOnly) { Caption = 'Fields Only'; }
    value(2; OldAndNewValues) { Caption = 'Old and New Values'; }
}
