enum 94108 "Bcmag Api Routing"
{
    // Whether an agent may read through the tenant's own API pages instead of the dynamic plane.
    // The API catalog (discover kind "apis", describe kind "api") is always visible; this switch only
    // decides whether describe reports an API as routable. Routing itself happens in the client (the
    // MCP server), because AL cannot call an API page, so the switch is advisory to it — and the
    // client's pre-check asks this endpoint, fresh, before every API read.
    Extensible = false;
    Caption = 'Wicket API Routing';

    value(0; Off)    { Caption = 'Off'; }
    value(1; Prefer) { Caption = 'Prefer'; }
}
