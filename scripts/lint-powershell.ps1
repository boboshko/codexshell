param([Parameter(Mandatory = $true, Position = 0)][string]$ScriptPath)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not (Get-Module -ListAvailable -Name PSScriptAnalyzer)) {
    [Console]::Error.WriteLine('SKIP: PSScriptAnalyzer unavailable')
    exit 3
}
try {
    Import-Module PSScriptAnalyzer -ErrorAction Stop
    $findings = @(Invoke-ScriptAnalyzer -Path $ScriptPath -Severity Error, Warning)
    if ($findings.Count -gt 0) {
        $findings | Format-Table -AutoSize | Out-String | Write-Output
        exit 1
    }
    exit 0
} catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
