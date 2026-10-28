codeunit 94153 "Bcmag Async Reaper Guard"
{
    // Keeps the reaper chain alive. Two roles, one body:
    //   - the TaskScheduler FAILURE codeunit of every reaper task: it runs after a reaper run failed and
    //     re-arms the chain if the run's own re-arm did not survive (the reaper re-arms first and commits,
    //     so normally a live successor exists and this is a no-op);
    //   - a Codeunit.Run boundary the enqueuer calls on every accepted request, so a chain that died
    //     anyway (task deleted by an administrator, the arming user removed) is restarted by the next
    //     use of async delivery, and a failure to arm it can never fail the caller's request.
    // Ensure is idempotent: it arms only when no reaper task is live.

    Access = Public;

    trigger OnRun()
    var
        Reaper: Codeunit "Bcmag Async Reaper";
    begin
        Reaper.Ensure();
    end;
}
