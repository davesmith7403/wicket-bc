# AL-Go override (Run-AlPipeline honours a NewBcContainer.ps1 in the .AL-Go folder).
# The CI test container is an ON-PREMISES Business Central server, which by
# default refuses database writes inside try functions (DisableWriteInsideTryFunctions = true).
# Business Central ONLINE — the only target this extension ships to — has no such restriction, and
# Wicket's write plane and best-effort audit logger rely on it (TryInsert/TryModify/TryDelete, the
# Logger's TryInsert*). An early CI run failed 17 tests on exactly this rule. Align the
# container with SaaS semantics so the suite tests the product, not the container. BcContainerHelper
# merges an existing "--env customNavSettings=" entry with its own settings instead of duplicating it.
Param([Hashtable] $parameters)

$tryFunctionWrites = "--env customNavSettings=DisableWriteInsideTryFunctions=false"
if ($parameters.ContainsKey('additionalParameters') -and $null -ne $parameters.additionalParameters) {
    $parameters.additionalParameters = @($parameters.additionalParameters) + @($tryFunctionWrites)
}
else {
    $parameters.additionalParameters = @($tryFunctionWrites)
}

New-BcContainer @parameters
Invoke-ScriptInBcContainer -containerName $parameters.ContainerName -scriptblock { $progressPreference = 'SilentlyContinue' }
