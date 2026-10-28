codeunit 94156 "Bcmag App Info"
{
    // Which installed app owns an object (discover and describe report it as `app`, so an agent can
    // tell a solution table from a Base Application one without guessing from id ranges), the
    // publisher filter discover offers over that, and the structure fingerprint capabilities
    // publishes. The installed-app list is small (one row per app), so it is read once per instance.

    var
        Loaded: Boolean;
        AppIds: Dictionary of [Text, Text];
        AppNames: Dictionary of [Text, Text];
        AppPublishers: Dictionary of [Text, Text];
        AppVersions: Dictionary of [Text, Text];

    // Adds `app`: { id, name, publisher, version } for the package that defines the object, or null for
    // a platform object that belongs to no installed app (system and virtual tables).
    procedure AddAppMember(var Row: JsonObject; PackageId: Guid)
    var
        AppObj: JsonObject;
        NullValue: JsonValue;
        PkgKey: Text;
    begin
        Load();
        PkgKey := PackageKey(PackageId);
        if IsNullGuid(PackageId) or not AppIds.ContainsKey(PkgKey) then begin
            NullValue.SetValueToNull();
            Row.Add('app', NullValue);
            exit;
        end;
        AppObj.Add('id', AppIds.Get(PkgKey));
        AppObj.Add('name', AppNames.Get(PkgKey));
        AppObj.Add('publisher', AppPublishers.Get(PkgKey));
        AppObj.Add('version', AppVersions.Get(PkgKey));
        Row.Add('app', AppObj);
    end;

    // The package ids of the installed apps whose Publisher matches an AL filter. False when the filter
    // is malformed (the caller answers 400 invalid-filter with GetLastErrorText).
    [TryFunction]
    procedure TryPackagesByPublisher(PublisherFilter: Text; var PackageKeys: List of [Text])
    var
        InstalledApp: Record "NAV App Installed App";
    begin
        Clear(PackageKeys);
        InstalledApp.SetFilter(Publisher, PublisherFilter);
        if InstalledApp.FindSet() then
            repeat
                PackageKeys.Add(PackageKey(InstalledApp."Package ID"));
            until InstalledApp.Next() = 0;
    end;

    procedure PackageKey(PackageId: Guid): Text
    begin
        exit(LowerCase(Format(PackageId, 0, 4)));
    end;

    // Moves when an app is installed, upgraded or removed — every package id is per version — which is
    // when table structure can have changed. Policy changes leave it alone: describe's own
    // describeVersion covers those.
    procedure StructureVersion(): Text
    var
        InstalledApp: Record "NAV App Installed App";
        CryptographyMgt: Codeunit "Cryptography Management";
        HashAlgorithm: Option MD5,SHA1,SHA256,SHA384,SHA512;
        Content: TextBuilder;
    begin
        InstalledApp.SetCurrentKey("Package ID");
        if InstalledApp.FindSet() then
            repeat
                Content.Append(PackageKey(InstalledApp."Package ID"));
                Content.Append(';');
            until InstalledApp.Next() = 0;
        exit(LowerCase(CryptographyMgt.GenerateHash(Content.ToText(), HashAlgorithm::SHA256)));
    end;

    local procedure Load()
    var
        InstalledApp: Record "NAV App Installed App";
        PkgKey: Text;
    begin
        if Loaded then
            exit;
        Loaded := true;
        if InstalledApp.FindSet() then
            repeat
                PkgKey := PackageKey(InstalledApp."Package ID");
                if not AppIds.ContainsKey(PkgKey) then begin
                    AppIds.Add(PkgKey, LowerCase(Format(InstalledApp."App ID", 0, 4)));
                    AppNames.Add(PkgKey, InstalledApp.Name);
                    AppPublishers.Add(PkgKey, InstalledApp.Publisher);
                    AppVersions.Add(PkgKey, Format(InstalledApp."Version Major", 0, 9) + '.' + Format(InstalledApp."Version Minor", 0, 9) + '.' +
                        Format(InstalledApp."Version Build", 0, 9) + '.' + Format(InstalledApp."Version Revision", 0, 9));
                end;
            until InstalledApp.Next() = 0;
    end;
}
