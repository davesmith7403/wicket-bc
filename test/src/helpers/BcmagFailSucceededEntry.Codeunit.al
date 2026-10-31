codeunit 94347 "Bcmag Fail Succeeded Entry"
{
    // Test-only, bound manually: fails the insert of a "Succeeded" change entry, so a test can make an
    // error escape after an action's wrapper returned (the wrapper may already have committed).
    EventSubscriberInstance = Manual;

    [EventSubscriber(ObjectType::Table, Database::"Bcmag Change Entry", 'OnBeforeInsertEvent', '', false, false)]
    local procedure FailSucceeded(var Rec: Record "Bcmag Change Entry"; RunTrigger: Boolean)
    begin
        if Rec.Outcome = 'Succeeded' then
            Error('the success entry could not be written');
    end;
}
