enum 94110 "Bcmag Data Class"
{
    // Wicket's own copy of the platform's DataClassification option, so classification rules and
    // per-user exceptions can be keyed on it in a table. The ordinals deliberately equal the
    // Field.DataClassification ordinals, but the mapping ALWAYS goes through the explicit case in
    // "Bcmag Policy Defaults".DataClassOf — never through an ordinal cast or Format().
    Extensible = false;
    Caption = 'Wicket Data Class';

    value(0; CustomerContent)                     { Caption = 'Customer Content'; }
    value(1; ToBeClassified)                      { Caption = 'To Be Classified'; }
    value(2; EndUserIdentifiableInformation)      { Caption = 'End User Identifiable Information'; }
    value(3; AccountData)                         { Caption = 'Account Data'; }
    value(4; EndUserPseudonymousIdentifiers)      { Caption = 'End User Pseudonymous Identifiers'; }
    value(5; OrganizationIdentifiableInformation) { Caption = 'Organization Identifiable Information'; }
    value(6; SystemMetadata)                      { Caption = 'System Metadata'; }
}
