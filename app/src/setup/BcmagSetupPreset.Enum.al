enum 94112 "Bcmag Setup Preset"
{
    // The one-step postures the Setup Card offers (Bcmag Setup.ApplyPreset), and what CurrentPreset
    // reports back. Custom is never applied: it names any combination no preset produces, including the
    // fresh-install default (Allowlisted, writable).
    Extensible = false;
    Caption = 'Wicket Setup Preset';

    value(0; Custom)                 { Caption = 'Custom'; }
    value(1; SimpleReadOnly)         { Caption = 'Simple Read-Only'; }
    value(2; ReadOnlySelectedTables) { Caption = 'Read-Only (Selected Tables)'; }
    value(3; ReadAndActions)         { Caption = 'Read + Business Actions'; }
    value(4; DeveloperSandbox)       { Caption = 'Developer Sandbox'; }
}
