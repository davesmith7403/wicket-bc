codeunit 94149 "Bcmag Api Catalog"
{
    // The tenant's own API surface, read from platform metadata so an agent can prefer a published API
    // page over the dynamic plane when one covers the data it needs. Three virtual tables carry it:
    //   Page Metadata       API pages: route parts (publisher/group/version/entity set), source table,
    //                       source table view, insert/modify/delete switches
    //   Page Control Field  each API field (the control name IS the wire name) and the table field it
    //                       is bound to; a control with no table field is computed in AL
    //   Query Metadata      API queries (joined/aggregated reads); no column-to-field mapping exists
    // All three are platform objects, so the System-Application-only dependency still holds.
    //
    // catalogVersion is a fingerprint of the catalog's CONTENT, so a client can cache the list and the
    // field maps and revalidate with one cheap call (discover kind "apis" + ifNoneMatch). It covers the
    // API rows themselves and, when the principal may read it, every installed app's package id, which
    // changes on any install, upgrade or uninstall (an upgrade can add fields without adding pages).
    //
    // Governance answers (routable, readable) are NOT part of the fingerprint and must not be cached:
    // they follow the exposure allowlist, the field policy and the API Routing switch as they are NOW.

    var
        Setup: Record "Bcmag Setup";
        Exposure: Record "Bcmag Exposure";
        FieldPolicy: Codeunit "Bcmag Field Policy";

    // ---- catalog listing (discover kind "apis") ----------------------------------------------------

    procedure ListApis(FilterText: Text; TableId: Integer; Skip: Integer; Top: Integer; var Value: JsonArray; var Total: Integer; var BadFilter: Text): Boolean
    var
        PageMeta: Record "Page Metadata";
        QueryMeta: Record "Query Metadata";
        Index: Integer;
    begin
        if not FilterPages(PageMeta, FilterText, TableId) then begin
            BadFilter := GetLastErrorText();
            exit(false);
        end;
        if PageMeta.FindSet() then
            repeat
                Index += 1;
                if (Index > Skip) and (Value.Count() < Top) then
                    Value.Add(PageRow(PageMeta));
            until PageMeta.Next() = 0;
        // API queries have no source table, so a tableId lookup never lists them.
        if TableId = 0 then begin
            if not FilterQueries(QueryMeta, FilterText) then begin
                BadFilter := GetLastErrorText();
                exit(false);
            end;
            if QueryMeta.FindSet() then
                repeat
                    Index += 1;
                    if (Index > Skip) and (Value.Count() < Top) then
                        Value.Add(QueryRow(QueryMeta));
                until QueryMeta.Next() = 0;
        end;
        Total := Index;
        exit(true);
    end;

    // Every API page over one table, in the compact form describe kind "table" embeds as apiRoutes.
    procedure RoutesForTable(TableId: Integer) Routes: JsonArray
    var
        PageMeta: Record "Page Metadata";
        Route: JsonObject;
    begin
        FilterPages(PageMeta, '', TableId);
        if PageMeta.FindSet() then
            repeat
                Clear(Route);
                Route.Add('pageId', PageMeta.ID);
                Route.Add('entitySetName', PageMeta.EntitySetName);
                Route.Add('route', PreferredRoute(PageMeta.APIPublisher, PageMeta.APIGroup, PageMeta.APIVersion, PageMeta.EntitySetName));
                if PageMeta.SourceTableView <> '' then
                    Route.Add('sourceTableView', PageMeta.SourceTableView);
                Routes.Add(Route);
            until PageMeta.Next() = 0;
    end;

    // ---- one API page in detail (describe kind "api") ----------------------------------------------

    // False when PageId is not an API page (the caller answers 404).
    procedure DescribeApi(PageId: Integer; var Value: JsonObject): Boolean
    var
        PageMeta: Record "Page Metadata";
        ControlField: Record "Page Control Field";
        Fields: JsonArray;
        FieldObj: JsonObject;
        Reason: Text;
        TableReadable, Mapped, Routable, Readable: Boolean;
    begin
        if not PageMeta.Get(PageId) then
            exit(false);
        if (PageMeta.PageType <> PageMeta.PageType::API) or IsOwnObject(PageMeta."App ID") then
            exit(false);

        Value := PageRow(PageMeta);
        Value.Add('sourceTableView', PageMeta.SourceTableView);

        // Routable is the governance answer a client must obtain fresh before reading through the API:
        // the switch is on, and the source table is one Wicket itself would let this caller read.
        TableReadable := TableReadableNow(PageMeta.SourceTable);
        Routable := RoutingOn() and TableReadable;
        if not RoutingOn() then
            Reason := 'routing-off'
        else
            if not TableReadable then
                Reason := 'not-exposed';
        Value.Add('routable', Routable);
        if Reason <> '' then
            Value.Add('notRoutableReason', Reason);

        ControlField.SetRange(PageNo, PageId);
        if ControlField.FindSet() then
            repeat
                if ControlField.ControlName <> '' then begin
                    Clear(FieldObj);
                    Mapped := (ControlField.TableNo <> 0) and (ControlField.FieldNo <> 0);
                    FieldObj.Add('name', ControlField.ControlName);
                    FieldObj.Add('mapped', Mapped);
                    if Mapped then begin
                        FieldObj.Add('fieldNo', ControlField.FieldNo);
                        if ControlField.TableNo <> PageMeta.SourceTable then
                            FieldObj.Add('tableId', ControlField.TableNo);
                    end;
                    // A computed control (no table field) can carry anything the page's AL puts in it,
                    // so the pre-check cannot judge it against the field policy: never readable.
                    // (AL evaluates both sides of "and", so the policy is only consulted when mapped.)
                    Readable := false;
                    if Mapped then
                        Readable := FieldReadableNow(PageMeta.SourceTable, TableReadable, ControlField.TableNo, ControlField.FieldNo);
                    FieldObj.Add('readable', Readable);
                    // access explains readable=false for a masked field (it is readable via Wicket, masked).
                    if Mapped then
                        if Readable then
                            FieldObj.Add('access', 'clear')
                        else
                            if FieldPolicy.IsMasked(ControlField.TableNo, ControlField.FieldNo) then
                                FieldObj.Add('access', 'masked');
                    Fields.Add(FieldObj);
                end;
            until ControlField.Next() = 0;
        Value.Add('fields', Fields);
        exit(true);
    end;

    // An API query (for a describe that names one): no column mapping exists, so it is never routable.
    procedure DescribeApiQuery(QueryId: Integer; var Value: JsonObject): Boolean
    var
        QueryMeta: Record "Query Metadata";
    begin
        if not QueryMeta.Get(QueryId) then
            exit(false);
        if (QueryMeta.EntitySetName = '') or IsOwnObject(QueryMeta."App ID") then
            exit(false);
        Value := QueryRow(QueryMeta);
        Value.Add('routable', false);
        Value.Add('notRoutableReason', 'no-field-mapping');
        exit(true);
    end;

    procedure RoutingModeName(): Text
    begin
        ReadSetup();
        case Setup."API Routing" of
            Setup."API Routing"::Off:
                exit('Off');
            Setup."API Routing"::Prefer:
                exit('Prefer');
        end;
        exit('Unknown');
    end;

    // ---- fingerprint ------------------------------------------------------------------------------

    procedure CatalogVersion(): Text
    var
        PageMeta: Record "Page Metadata";
        QueryMeta: Record "Query Metadata";
        CryptographyMgt: Codeunit "Cryptography Management";
        HashAlgorithm: Option MD5,SHA1,SHA256,SHA384,SHA512;
        Content: TextBuilder;
    begin
        FilterPages(PageMeta, '', 0);
        if PageMeta.FindSet() then
            repeat
                // Format(..., 0, 9) throughout: the fingerprint must not depend on the session's
                // regional settings, or two callers would never agree on a version.
                Content.Append(StrSubstNo('P%1|%2|%3|%4|%5|%6|%7|%8|%9|%10;', Format(PageMeta.ID, 0, 9), PageMeta.APIPublisher,
                    PageMeta.APIGroup, PageMeta.APIVersion, PageMeta.EntitySetName, Format(PageMeta.SourceTable, 0, 9),
                    PageMeta.SourceTableView, Format(PageMeta.InsertAllowed, 0, 9), Format(PageMeta.ModifyAllowed, 0, 9),
                    Format(PageMeta.DeleteAllowed, 0, 9)));
            until PageMeta.Next() = 0;
        FilterQueries(QueryMeta, '');
        if QueryMeta.FindSet() then
            repeat
                Content.Append(StrSubstNo('Q%1|%2|%3|%4|%5;', Format(QueryMeta.ID, 0, 9), QueryMeta.APIPublisher, QueryMeta.APIGroup,
                    QueryMeta.APIVersion, QueryMeta.EntitySetName));
            until QueryMeta.Next() = 0;
        if not TryAppendInstalledApps(Content) then
            ClearLastError(); // the page/query rows alone still fingerprint the catalog's shape
        exit(LowerCase(CryptographyMgt.GenerateHash(Content.ToText(), HashAlgorithm::SHA256)));
    end;

    [TryFunction]
    local procedure TryAppendInstalledApps(var Content: TextBuilder)
    var
        InstalledApp: Record "NAV App Installed App";
    begin
        if not InstalledApp.ReadPermission() then
            exit;
        if InstalledApp.FindSet() then
            repeat
                Content.Append(StrSubstNo('A%1;', Format(InstalledApp."Package ID", 0, 9)));
            until InstalledApp.Next() = 0;
    end;

    // ---- rows -------------------------------------------------------------------------------------

    local procedure PageRow(PageMeta: Record "Page Metadata") Row: JsonObject
    var
        Operations: JsonObject;
    begin
        Row.Add('id', PageMeta.ID);
        Row.Add('scope', 'api');
        Row.Add('apiKind', 'page');
        Row.Add('name', PageMeta.Name);
        Row.Add('entitySetName', PageMeta.EntitySetName);
        Row.Add('entityName', PageMeta.EntityName);
        Row.Add('route', PreferredRoute(PageMeta.APIPublisher, PageMeta.APIGroup, PageMeta.APIVersion, PageMeta.EntitySetName));
        Row.Add('routes', AllRoutes(PageMeta.APIPublisher, PageMeta.APIGroup, PageMeta.APIVersion, PageMeta.EntitySetName));
        Row.Add('sourceTableId', PageMeta.SourceTable);
        Operations.Add('read', true);
        Operations.Add('insert', PageMeta.InsertAllowed);
        Operations.Add('modify', PageMeta.Editable and PageMeta.ModifyAllowed);
        Operations.Add('delete', PageMeta.DeleteAllowed);
        Row.Add('operations', Operations);
    end;

    local procedure QueryRow(QueryMeta: Record "Query Metadata") Row: JsonObject
    var
        Operations: JsonObject;
    begin
        Row.Add('id', QueryMeta.ID);
        Row.Add('scope', 'api');
        Row.Add('apiKind', 'query');
        Row.Add('name', QueryMeta.Name);
        Row.Add('entitySetName', QueryMeta.EntitySetName);
        Row.Add('entityName', QueryMeta.EntityName);
        Row.Add('route', PreferredRoute(QueryMeta.APIPublisher, QueryMeta.APIGroup, QueryMeta.APIVersion, QueryMeta.EntitySetName));
        Row.Add('routes', AllRoutes(QueryMeta.APIPublisher, QueryMeta.APIGroup, QueryMeta.APIVersion, QueryMeta.EntitySetName));
        Operations.Add('read', true);
        Operations.Add('insert', false);
        Operations.Add('modify', false);
        Operations.Add('delete', false);
        Row.Add('operations', Operations);
    end;

    // ---- routes -----------------------------------------------------------------------------------

    // The path after /api/ and before /companies(...): "v2.0" for Microsoft's standard APIs (which
    // declare no publisher or group), "<publisher>/<group>/<version>" for everything else.
    local procedure RoutePrefix(Publisher: Text; Group: Text; Version: Text): Text
    begin
        if Publisher = '' then
            exit(Version);
        exit(Publisher + '/' + Group + '/' + Version);
    end;

    // An API may declare several versions ("v1.0,v2.0"); the preferred route uses the highest one, and
    // "beta" ranks below every numbered version.
    local procedure PreferredRoute(Publisher: Text; Group: Text; Versions: Text; EntitySet: Text): Text
    var
        Part, Version, Best: Text;
        BestRank, Rank: Decimal;
    begin
        BestRank := -2;
        foreach Part in Versions.Split(',') do begin
            Version := DelChr(Part, '<>', ' ');
            Rank := VersionRank(Version);
            if (Version <> '') and (Rank > BestRank) then begin
                Best := Version;
                BestRank := Rank;
            end;
        end;
        exit(RoutePrefix(Publisher, Group, Best) + '/' + EntitySet);
    end;

    local procedure AllRoutes(Publisher: Text; Group: Text; Versions: Text; EntitySet: Text) Routes: JsonArray
    var
        Part, Version: Text;
    begin
        foreach Part in Versions.Split(',') do begin
            Version := DelChr(Part, '<>', ' ');
            if Version <> '' then
                Routes.Add(RoutePrefix(Publisher, Group, Version) + '/' + EntitySet);
        end;
    end;

    local procedure VersionRank(Version: Text): Decimal
    var
        Rank: Decimal;
    begin
        if not LowerCase(Version).StartsWith('v') then
            exit(-1);
        // Format 9 is the invariant XML format, so "2.0" parses the same under every regional setting.
        if not Evaluate(Rank, CopyStr(Version, 2), 9) then
            exit(-1);
        exit(Rank);
    end;

    // ---- filters and governance -------------------------------------------------------------------

    // The fixed constraints sit in their own filter group, so the caller's filter on EntitySetName is
    // ANDed with them instead of replacing the non-blank condition on the same field.
    [TryFunction]
    local procedure FilterPages(var PageMeta: Record "Page Metadata"; FilterText: Text; TableId: Integer)
    begin
        PageMeta.FilterGroup(10);
        PageMeta.SetRange(PageType, PageMeta.PageType::API);
        PageMeta.SetFilter(EntitySetName, '<>%1', '');
        PageMeta.SetFilter("App ID", '<>%1', OwnAppId());
        if TableId <> 0 then
            PageMeta.SetRange(SourceTable, TableId);
        PageMeta.FilterGroup(0);
        if FilterText <> '' then
            PageMeta.SetFilter(EntitySetName, FilterText);
    end;

    [TryFunction]
    local procedure FilterQueries(var QueryMeta: Record "Query Metadata"; FilterText: Text)
    begin
        QueryMeta.FilterGroup(10);
        QueryMeta.SetFilter(EntitySetName, '<>%1', '');
        QueryMeta.SetFilter("App ID", '<>%1', OwnAppId());
        QueryMeta.FilterGroup(0);
        if FilterText <> '' then
            QueryMeta.SetFilter(EntitySetName, FilterText);
    end;

    // Wicket's own endpoint is an API page too; it is the transport, not data, so it is never listed.
    local procedure IsOwnObject(AppId: Guid): Boolean
    begin
        exit(AppId = OwnAppId());
    end;

    local procedure OwnAppId(): Guid
    var
        Info: ModuleInfo;
    begin
        NavApp.GetCurrentModuleInfo(Info);
        exit(Info.Id);
    end;

    local procedure RoutingOn(): Boolean
    begin
        ReadSetup();
        exit(Setup."API Routing" = Setup."API Routing"::Prefer);
    end;

    // The same two conditions discover applies before it lists a table: the exposure allowlist (which
    // also answers Open mode and the hard audit-table denylist) and the principal's own read permission.
    local procedure TableReadableNow(TableId: Integer): Boolean
    var
        RecRef: RecordRef;
        Readable: Boolean;
    begin
        if TableId = 0 then
            exit(false);
        if not Exposure.IsAllowed(Exposure."Object Type"::Table, TableId, 'read') then
            exit(false);
        if not TryOpen(RecRef, TableId) then
            exit(false);
        Readable := RecRef.ReadPermission();
        RecRef.Close();
        exit(Readable);
    end;

    local procedure FieldReadableNow(SourceTableId: Integer; SourceReadable: Boolean; TableId: Integer; FieldNo: Integer): Boolean
    begin
        if TableId = SourceTableId then begin
            if not SourceReadable then
                exit(false);
        end else
            if not TableReadableNow(TableId) then
                exit(false);
        // Clear only: a masked field would come back in clear through the tenant API.
        exit(FieldPolicy.IsClear(TableId, FieldNo));
    end;

    [TryFunction]
    local procedure TryOpen(var RecRef: RecordRef; TableId: Integer)
    begin
        RecRef.Open(TableId);
    end;

    // Read on every use, never memoised: the governance answers must follow the switch as it is NOW,
    // and an instance of this codeunit can outlive a change to it.
    local procedure ReadSetup()
    begin
        Setup.GetSingleton();
    end;
}
