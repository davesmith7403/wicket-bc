page 94100 "Bcmag Rpc Endpoint"
{
    PageType = API;
    APIPublisher = 'wicket';
    APIGroup = 'rpc';
    APIVersion = 'v1.0';
    EntityName = 'wicketEndpoint';
    EntitySetName = 'wicketEndpoint';
    // The endpoint is a fixed, stateless address, not a view of any Wicket data: one row of the
    // platform's virtual Integer table, Number = 0, so the documented key segment wicketEndpoint(0)
    // is a valid OData integer key in every company without depending on a setup row existing.
    SourceTable = Integer;
    SourceTableView = where(Number = const(0));
    ODataKeyFields = Number;
    Editable = false;
    InsertAllowed = false;
    ModifyAllowed = false;
    DeleteAllowed = false;

    // Bound actions are invoked over OData as:
    //   POST .../api/wicket/rpc/v1.0/companies({companyId})/wicketEndpoint(0)/Microsoft.NAV.<operation>
    //   body     {"envelope": "<the envelope serialised as a JSON string>"}
    //   response {"value":    "<the result or RFC 7807 problem serialised as a JSON string>"}
    // Text in, Text out is not a style choice: the platform publishes a [ServiceEnabled] procedure as a
    // bound action only for simple parameter/return types. The JsonObject signatures this page had
    // until 2026-09-24 compiled clean and were silently left out of $metadata, so no operation was
    // reachable over HTTP. Every action answers HTTP 200; the logical status lives in the body.

    layout
    {
        area(content)
        {
            field(number; Rec.Number) { Caption = 'Number'; }
        }
    }

    [ServiceEnabled]
    procedure discover(envelope: Text): Text
    begin
        exit(RunDispatch('discover', envelope));
    end;

    [ServiceEnabled]
    procedure describe(envelope: Text): Text
    begin
        exit(RunDispatch('describe', envelope));
    end;

    [ServiceEnabled]
    procedure query(envelope: Text): Text
    begin
        exit(RunDispatch('query', envelope));
    end;

    [ServiceEnabled]
    procedure readBlob(envelope: Text): Text
    begin
        exit(RunDispatch('readBlob', envelope));
    end;

    [ServiceEnabled]
    procedure capabilities(envelope: Text): Text
    begin
        exit(RunDispatch('capabilities', envelope));
    end;

    [ServiceEnabled]
    procedure insert(envelope: Text): Text
    begin
        exit(RunDispatch('insert', envelope));
    end;

    [ServiceEnabled]
    procedure modify(envelope: Text): Text
    begin
        exit(RunDispatch('modify', envelope));
    end;

    [ServiceEnabled]
    procedure delete(envelope: Text): Text
    begin
        exit(RunDispatch('delete', envelope));
    end;

    [ServiceEnabled]
    procedure invoke(envelope: Text): Text
    begin
        exit(RunDispatch('invoke', envelope));
    end;

    [ServiceEnabled]
    procedure status(envelope: Text): Text
    begin
        exit(RunDispatch('status', envelope));
    end;

    [ServiceEnabled]
    procedure cancel(envelope: Text): Text
    begin
        exit(RunDispatch('cancel', envelope));
    end;

    [ServiceEnabled]
    procedure requests(envelope: Text): Text
    begin
        exit(RunDispatch('requests', envelope));
    end;

    [ServiceEnabled]
    procedure action(envelope: Text): Text
    begin
        exit(RunDispatch('action', envelope));
    end;

    [ServiceEnabled]
    procedure skill(envelope: Text): Text
    begin
        exit(RunDispatch('skill', envelope));
    end;

    [ServiceEnabled]
    procedure pageUrl(envelope: Text): Text
    begin
        exit(RunDispatch('pageUrl', envelope));
    end;

    [ServiceEnabled]
    procedure whoAmI(envelope: Text): Text
    begin
        exit(RunDispatch('whoAmI', envelope));
    end;

    local procedure RunDispatch(Operation: Text; EnvelopeText: Text): Text
    var
        Dispatcher: Codeunit "Bcmag Rpc Dispatcher";
    begin
        // A bound action cannot read HTTP headers, so the idempotency key travels in the
        // envelope's optional "idempotencyKey" member; the dispatcher parses and enforces it.
        exit(Dispatcher.RunText(Operation, EnvelopeText));
    end;
}
