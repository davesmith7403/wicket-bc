codeunit 94327 "Bcmag Blob Request Probe"
{
    // Test seam for the Azure client: records, per blob name, the destination of the blob requests the
    // client was about to send (there is no Azure in the suite, so the request itself fails; what matters
    // is WHERE it was aimed). Keyed by blob because one reaper run sweeps every pending row, including
    // those sibling tests seeded under codeunit isolation. Bound manually per test — BindSubscription —
    // so only the test that asked observes anything. Stores into instance state only: the delete path
    // raises the event inside a try function, where a database write would be refused on-prem.

    EventSubscriberInstance = Manual;

    var
        Targets: Dictionary of [Text, Text];

    [EventSubscriber(ObjectType::Codeunit, Codeunit::"Bcmag Azure Client", OnBeforeBlobRequest, '', false, false)]
    local procedure Capture(Verb: Text; Account: Text; Container: Text; Endpoint: Text; BlobName: Text)
    begin
        Targets.Set(BlobName, Verb + '|' + Account + '|' + Container + '|' + Endpoint);
    end;

    // True when a request for BlobName was seen; the out parameters describe its destination.
    procedure Seen(BlobName: Text; var Verb: Text; var Account: Text; var Container: Text; var Endpoint: Text): Boolean
    var
        Packed: Text;
        Parts: List of [Text];
    begin
        if not Targets.Get(BlobName, Packed) then
            exit(false);
        Parts := Packed.Split('|');
        Verb := Parts.Get(1);
        Account := Parts.Get(2);
        Container := Parts.Get(3);
        Endpoint := Parts.Get(4);
        exit(true);
    end;
}
