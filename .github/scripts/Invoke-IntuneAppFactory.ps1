$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Assert-RequiredValue {
    param([string]$Name, [AllowNull()][string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { throw "Required GitHub secret/variable '$Name' is not configured." }
}

function Invoke-IAFScript {
    param(
        [Parameter(Mandatory)][string]$Path,
        [hashtable]$Arguments = @{},
        [switch]$RequireShouldRunFlag
    )
    Write-Host "`n========== Running $Path =========="
    $captured = @(& $Path @Arguments 2>&1)
    $captured | ForEach-Object { Write-Host $_ }
    if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) { throw "$Path returned exit code $LASTEXITCODE" }
    $flagLine = $captured | ForEach-Object { [string]$_ } | Where-Object { $_ -match '##vso\[task\.setvariable variable=shouldrun;isOutput=true\](true|false)' } | Select-Object -Last 1
    if ($RequireShouldRunFlag -and -not $flagLine) { throw "$Path did not emit the expected shouldrun status." }
    if ($flagLine -match '##vso\[task\.setvariable variable=shouldrun;isOutput=true\](true|false)') {
        return ($Matches[1] -eq 'true')
    }
    return $true
}

function Save-StageArtifact {
    param([Parameter(Mandatory)][string]$Name)
    $destination = Join-Path $env:BUILD_ARTIFACTSTAGINGDIRECTORY $Name
    New-Item -ItemType Directory -Path $destination -Force | Out-Null
    Get-ChildItem -LiteralPath $env:BUILD_BINARIESDIRECTORY -File -ErrorAction SilentlyContinue | Copy-Item -Destination $destination -Force
    Write-Host "Saved stage output to $destination"
}

function Reset-Binaries {
    Get-ChildItem -LiteralPath $env:BUILD_BINARIESDIRECTORY -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force
}

$mode = if ([string]::IsNullOrWhiteSpace($env:IAF_MODE)) { 'Package' } else { $env:IAF_MODE }
if ($mode -notin @('Verify', 'Package', 'Publish')) { throw "Unsupported operational mode '$mode'." }
$archiveMode = if ($env:IAF_ARCHIVE_MODE -eq 'Yes') { 'Yes' } else { 'No' }

$workspace = Join-Path $env:RUNNER_TEMP 'IntuneAppFactory'
$env:PIPELINE_WORKSPACE = $workspace
$env:BUILD_SOURCESDIRECTORY = $env:GITHUB_WORKSPACE
$env:BUILD_BINARIESDIRECTORY = Join-Path $workspace 'Binaries'
$env:BUILD_ARTIFACTSTAGINGDIRECTORY = Join-Path $workspace 'Artifacts'
New-Item -ItemType Directory -Path $env:BUILD_BINARIESDIRECTORY, $env:BUILD_ARTIFACTSTAGINGDIRECTORY -Force | Out-Null

Write-Host "Mode: $mode | Archive: $archiveMode"
Write-Host "Workspace: $workspace"
Write-Host "Runner: $env:COMPUTERNAME | PowerShell: $($PSVersionTable.PSVersion)"

# Stage 1: source/template validation
if (-not (Invoke-IAFScript -Path './Scripts/Test-TemplatesFolder.ps1' -RequireShouldRunFlag)) {
    throw 'Template validation failed. Check the missing template files in the log.'
}

# Stage 2: install required modules and clear stale workspace files
Invoke-IAFScript -Path './Scripts/Install-Modules.ps1' | Out-Null
Invoke-IAFScript -Path './Scripts/Remove-Files.ps1' | Out-Null
New-Item -ItemType Directory -Path $env:BUILD_BINARIESDIRECTORY, $env:BUILD_ARTIFACTSTAGINGDIRECTORY -Force | Out-Null

# Stage 3: validate onboarded apps and create AppsProcessList.json
if (-not (Invoke-IAFScript -Path './Scripts/Test-AppFiles.ps1' -RequireShouldRunFlag)) {
    throw 'One or more app definitions failed validation. Review Apps/<AppFolderName>/App.json and required files.'
}
Save-StageArtifact -Name 'AppsProcessList'
if ($mode -eq 'Verify') {
    Write-Host 'Verify mode completed. No installers downloaded and no Intune changes made.'
    exit 0
}

# All remaining stages need the service principal and storage key.
Assert-RequiredValue -Name 'TENANT_ID' -Value $env:IAF_TENANT_ID
Assert-RequiredValue -Name 'CLIENT_ID' -Value $env:IAF_CLIENT_ID
Assert-RequiredValue -Name 'CLIENT_SECRET' -Value $env:IAF_CLIENT_SECRET
Assert-RequiredValue -Name 'STORAGE_ACCOUNT_ACCESS_KEY' -Value $env:IAF_STORAGE_ACCOUNT_ACCESS_KEY

# Stage 4: discover newer app versions
Reset-Binaries
$runNext = Invoke-IAFScript -Path './Scripts/Test-AppList.ps1' -Arguments @{
    TenantID = $env:IAF_TENANT_ID
    ClientID = $env:IAF_CLIENT_ID
    ClientSecret = $env:IAF_CLIENT_SECRET
    StorageAccountAccessKey = $env:IAF_STORAGE_ACCOUNT_ACCESS_KEY
} -RequireShouldRunFlag
if (-not $runNext) { Write-Host 'No eligible app updates were found. Exiting successfully.'; exit 0 }
Save-StageArtifact -Name 'AppsDownloadList'

# Stage 5: download installer files
Reset-Binaries
$runNext = Invoke-IAFScript -Path './Scripts/Save-Installer.ps1' -Arguments @{
    StorageAccountAccessKey = $env:IAF_STORAGE_ACCOUNT_ACCESS_KEY
} -RequireShouldRunFlag
if (-not $runNext) { throw 'Installer download stage did not complete successfully.' }
Save-StageArtifact -Name 'AppsPrepareList'

# Stage 6: prepare Win32 package source folders
Reset-Binaries
$runNext = Invoke-IAFScript -Path './Scripts/Prepare-AppPackageFolder.ps1' -RequireShouldRunFlag
if (-not $runNext) { throw 'Application package preparation failed.' }
Save-StageArtifact -Name 'AppsPublishList'

if ($archiveMode -eq 'Yes') {
    # Stage 7: archive packages before publishing
    Assert-RequiredValue -Name 'ARCHIVE_STORAGE_ACCOUNT_NAME' -Value $env:IAF_ARCHIVE_STORAGE_ACCOUNT_NAME
    Assert-RequiredValue -Name 'ARCHIVE_CONTAINER_NAME' -Value $env:IAF_ARCHIVE_CONTAINER_NAME
    Invoke-IAFScript -Path './Scripts/New-AppArchive.ps1' -Arguments @{
        StorageAccountName = $env:IAF_ARCHIVE_STORAGE_ACCOUNT_NAME
        ContainerName = $env:IAF_ARCHIVE_CONTAINER_NAME
        StorageAccountKey = $env:IAF_STORAGE_ACCOUNT_ACCESS_KEY
    } | Out-Null
}

if ($mode -eq 'Package') {
    Write-Host 'Package mode completed. Prepared source folders are available under the Publish directory.'
    exit 0
}

# Stage 8: create/upload Win32 apps in Intune and generate AppsAssignList.json
Assert-RequiredValue -Name 'REPORT_WORKSPACE_ID' -Value $env:IAF_LOG_ANALYTICS_WORKSPACE_ID
Assert-RequiredValue -Name 'LOG_ANALYTICS_SHARED_KEY' -Value $env:IAF_LOG_ANALYTICS_SHARED_KEY
Reset-Binaries
$runNext = Invoke-IAFScript -Path './Scripts/New-Win32App.ps1' -Arguments @{
    TenantID = $env:IAF_TENANT_ID
    ClientID = $env:IAF_CLIENT_ID
    ClientSecret = $env:IAF_CLIENT_SECRET
    WorkspaceID = $env:IAF_LOG_ANALYTICS_WORKSPACE_ID
    SharedKey = $env:IAF_LOG_ANALYTICS_SHARED_KEY
} -RequireShouldRunFlag
if (-not $runNext) { throw 'Intune app publish stage did not produce an assignment list. Review the script output.' }
Save-StageArtifact -Name 'AppsPublishedList'

# Stage 9: create assignments defined in each app's Apps/<name>/App.json
Invoke-IAFScript -Path './Scripts/New-AppAssignment.ps1' -Arguments @{
    TenantID = $env:IAF_TENANT_ID
    ClientID = $env:IAF_CLIENT_ID
    ClientSecret = $env:IAF_CLIENT_SECRET
} | Out-Null

Write-Host 'Intune App Factory publish and assignment stages completed. Review Intune and workflow logs for per-app results.'
