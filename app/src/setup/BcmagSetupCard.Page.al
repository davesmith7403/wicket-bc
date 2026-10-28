page 94101 "Bcmag Setup Card"
{
    PageType = Card;
    SourceTable = "Bcmag Setup";
    Caption = 'Wicket Setup';
    UsageCategory = Administration;
    ApplicationArea = All;
    InsertAllowed = false;
    DeleteAllowed = false;

    layout
    {
        area(content)
        {
            group(General)
            {
                field(CurrentPreset;           CurrentPresetValue)
                {
                    ApplicationArea = All;
                    Caption = 'Current Preset';
                    Editable = false;
                    ToolTip = 'The preset the current settings match, or Custom. Apply a preset from the Presets actions.';
                }
                field(ReadOnlyMode; Rec."Read-Only Mode")
                {
                    ApplicationArea = All;

                    trigger OnValidate()
                    begin
                        CurrentPresetValue := Rec.CurrentPreset();
                    end;
                }
                field(Mode; Rec.Mode)
                {
                    ApplicationArea = All;

                    trigger OnValidate()
                    begin
                        CurrentPresetValue := Rec.CurrentPreset();
                    end;
                }
                field(AllowInvokeInOpenMode; Rec."Allow Invoke In Open Mode")
                {
                    ApplicationArea = All;

                    trigger OnValidate()
                    begin
                        CurrentPresetValue := Rec.CurrentPreset();
                    end;
                }
                field(DefaultLanguages;        Rec."Default Languages")   { ApplicationArea = All; }
                field(SkillDocUrl;             Rec."Skill Doc Url")       { ApplicationArea = All; }
            }
            group(Limits)
            {
                field(DefaultTop;              Rec."Default Top")         { ApplicationArea = All; }
                field(MaxTop;                  Rec."Max Top")             { ApplicationArea = All; }
                field(ScanBudget;              Rec."Per-Call Scan Budget"){ ApplicationArea = All; }
                field(MaxFilterLength;         Rec."Max Filter Length")   { ApplicationArea = All; }
                field(MaxSelectFields;         Rec."Max Select Fields")   { ApplicationArea = All; }
                field(DecimalStringThreshold;  Rec."Decimal String Threshold"){ ApplicationArea = All; }
            }
            group(WritesAndLog)
            {
                field(RequireEtag;             Rec."Require ETag On Writes"){ ApplicationArea = All; }
                field(StrongEtag;              Rec."Strong ETag")         { ApplicationArea = All; }
                field(RequireKeyForActions;    Rec."Require Key For Actions"){ ApplicationArea = All; ToolTip = 'Refuse action and invoke calls that carry no idempotency key (400 idempotency-key-required). A wrapper may post and commit; only a key lets a lost response be retried without posting twice.'; }
                field(AllowTriggerBypass;      Rec."Allow Trigger Bypass"){ ApplicationArea = All; ToolTip = 'Allow callers to skip table triggers with init:false (insert) or validate:false (modify). When off, such calls are refused with 403 trigger-bypass-disabled.'; }
                field(LogRetentionDays;        Rec."Operation Log Retention Days"){ ApplicationArea = All; }
                field(LogRequestDetails;       Rec."Log Request Details") { ApplicationArea = All; ToolTip = 'Record each request''s select, filter, orderBy, top, change window and aggregate, and the field names a write set (never their values), in the Operation Log''s Request Details. A filter can contain a value the caller searched for, such as a name; turn this off if that must not be stored. The table and target are always recorded.'; }
            }
            group(FieldPolicy)
            {
                field(FieldPolicyMode; Rec."Field Policy Mode")
                {
                    ApplicationArea = All;

                    trigger OnValidate()
                    begin
                        CurrentPresetValue := Rec.CurrentPreset();
                    end;
                }
                field(UnmaskTierEnabled;       Rec."Unmask Tier Enabled") { ApplicationArea = All; ToolTip = 'Let holders of the Wicket - Unmask permission set read Masked fields in clear. SUPER holds every permission, so while this is on every SUPER user reads masked fields in clear too.'; }
                field(DescribeRestrictedFields; Rec."Describe Restricted Fields"){ ApplicationArea = All; }
            }
            group(ApiRouting)
            {
                Caption = 'API Routing';

                field(ApiRoutingMode;          Rec."API Routing")         { ApplicationArea = All; ToolTip = 'Prefer lets a client read through the tenant''s own API pages when one covers the data, falling back to Wicket''s dynamic plane otherwise. The client asks Wicket first, so the exposure list and field policy still decide which tables and fields it may read, but the API read itself is not recorded in the Wicket Operation Log. Off: clients use the dynamic plane only.'; }
            }
            group(AsyncDelivery)
            {
                Caption = 'Async Delivery (Azure Blob)';

                field(AsyncEnabled;            Rec."Async Enabled")       { ApplicationArea = All; }
                field(AzureStorageAccount;     Rec."Azure Storage Account"){ ApplicationArea = All; }
                field(AzureBlobContainer;      Rec."Azure Blob Container"){ ApplicationArea = All; }
                field(AzureAuthMode;           Rec."Azure Auth Mode")     { ApplicationArea = All; }
                field(DownloadMode;            Rec."Download Mode")       { ApplicationArea = All; }
                field(DefaultPackageFormat;    Rec."Default Package Format"){ ApplicationArea = All; }
                field(PackageTtlHours;         Rec."Package TTL Hours")   { ApplicationArea = All; }
                field(SasTtlMinutes;           Rec."SAS TTL Minutes")     { ApplicationArea = All; }
                field(MaxScheduleAheadDays;    Rec."Max Schedule Ahead Days"){ ApplicationArea = All; }
                field(MaxActiveRequests;       Rec."Max Active Requests") { ApplicationArea = All; }
                field(AzureBlobEndpoint;       Rec."Azure Blob Endpoint") { ApplicationArea = All; }
            }
        }
    }

    actions
    {
        area(Promoted)
        {
            group(Category_Presets)
            {
                Caption = 'Presets';

                actionref(PresetSimpleReadOnly_Promoted; PresetSimpleReadOnly) { }
                actionref(PresetReadOnlySelectedTables_Promoted; PresetReadOnlySelectedTables) { }
                actionref(PresetReadAndActions_Promoted; PresetReadAndActions) { }
                actionref(PresetDeveloperSandbox_Promoted; PresetDeveloperSandbox) { }
            }
        }
        area(navigation)
        {
            action(ClassificationRules)
            {
                ApplicationArea = All;
                Caption = 'Classification Rules';
                Image = Setup;
                RunObject = page "Bcmag Classification Rules";
                ToolTip = 'Set, per data classification, whether fields are Hidden, Masked or Clear in By Classification mode.';
            }
            action(MaskProfiles)
            {
                ApplicationArea = All;
                Caption = 'Mask Profiles';
                Image = Setup;
                RunObject = page "Bcmag Mask Profiles";
                ToolTip = 'Define how Masked values are rendered.';
            }
            action(AccessExceptions)
            {
                ApplicationArea = All;
                Caption = 'Access Exceptions';
                Image = UserSetup;
                RunObject = page "Bcmag Access Exceptions";
                ToolTip = 'Give individual users a different read verdict for a classification or a field, optionally for a limited time.';
            }
        }
        area(processing)
        {
            group(Presets)
            {
                Caption = 'Presets';
                Image = Setup;

                action(PresetSimpleReadOnly)
                {
                    ApplicationArea = All;
                    Caption = 'Simple Read-Only';
                    Image = Open;
                    ToolTip = 'Read every table, write nothing. The caller needs Wicket Data - Read.';

                    trigger OnAction()
                    begin
                        ApplyPresetInteractive("Bcmag Setup Preset"::SimpleReadOnly);
                    end;
                }
                action(PresetReadOnlySelectedTables)
                {
                    ApplicationArea = All;
                    Caption = 'Read-Only (Selected Tables)';
                    Image = Lock;
                    ToolTip = 'Read only the tables you allow, write nothing. Opens the Exposure list so you can allow tables.';

                    trigger OnAction()
                    begin
                        ApplyPresetInteractive("Bcmag Setup Preset"::ReadOnlySelectedTables);
                    end;
                }
                action(PresetReadAndActions)
                {
                    ApplicationArea = All;
                    Caption = 'Read + Business Actions';
                    Image = Action;
                    ToolTip = 'Read every table and run enrolled business actions. Direct writes stay refused below Wicket - Edit.';

                    trigger OnAction()
                    begin
                        ApplyPresetInteractive("Bcmag Setup Preset"::ReadAndActions);
                    end;
                }
                action(PresetDeveloperSandbox)
                {
                    ApplicationArea = All;
                    Caption = 'Developer Sandbox';
                    Image = TestFile;
                    ToolTip = 'Open everything for development: all tables, invoke and every field. Sandbox environments only.';

                    trigger OnAction()
                    begin
                        ApplyPresetInteractive("Bcmag Setup Preset"::DeveloperSandbox);
                    end;
                }
            }
            action(SetAzureCredential)
            {
                ApplicationArea = All;
                Caption = 'Set Azure Credential';
                Image = EncryptionKeys;
                ToolTip = 'Store the Azure storage account key (Shared Key) or ready SAS token (Ready SAS) used to authorize blob operations. The secret is kept in IsolatedStorage as encrypted text and is never displayed again.';

                trigger OnAction()
                begin
                    PromptAndStore(false);
                end;
            }
            action(SetAzureReadySas)
            {
                ApplicationArea = All;
                Caption = 'Set Azure Read SAS';
                Image = EncryptionKeys;
                ToolTip = 'Store the pre-provisioned read-only SAS token appended to download URLs when Download Mode is Ready SAS. Paste the token without a leading question mark.';

                trigger OnAction()
                begin
                    PromptAndStore(true);
                end;
            }
        }
    }

    var
        CredentialStoredMsg: Label 'The secret has been stored.';
        CurrentPresetValue: Enum "Bcmag Setup Preset";
        ApplyPresetQst: Label 'Apply the %1 preset?\\%2', Comment = '%1 = preset caption, %2 = what the preset does';
        PresetAppliedMsg: Label 'The %1 preset is applied.\\Assign the caller (user or Microsoft Entra application): %2.', Comment = '%1 = preset caption, %2 = permission set names';

    trigger OnOpenPage()
    begin
        Rec.GetSingleton();
    end;

    trigger OnAfterGetRecord()
    begin
        CurrentPresetValue := Rec.CurrentPreset();
    end;

    local procedure ApplyPresetInteractive(Preset: Enum "Bcmag Setup Preset")
    begin
        if not Confirm(ApplyPresetQst, false, Preset, Rec.PresetSummary(Preset)) then
            exit;
        Rec.ApplyPreset(Preset);
        CurrentPresetValue := Rec.CurrentPreset();
        CurrPage.Update(false);
        Message(PresetAppliedMsg, Preset, Rec.PresetPermissionSets(Preset));
        if Preset = Preset::ReadOnlySelectedTables then
            Page.Run(Page::"Bcmag Exposure List");
    end;

    [NonDebuggable]
    local procedure PromptAndStore(IsReadySas: Boolean)
    var
        AzureClient: Codeunit "Bcmag Azure Client";
        SecretInput: Page "Bcmag Secret Input";
        Value: Text;
    begin
        if SecretInput.RunModal() <> Action::OK then
            exit;
        Value := SecretInput.GetValue();
        if Value = '' then
            exit;
        if IsReadySas then
            AzureClient.SetReadySas(Value)
        else
            AzureClient.SetCredential(Value);
        Clear(Value);
        Message(CredentialStoredMsg);
    end;
}
