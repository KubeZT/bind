$ErrorActionPreference = "Stop"
Set-StrictMode -Version 2.0

function Write-Step {
    param([string] $Message)
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Write-Ok {
    param([string] $Message)
    Write-Host "[ok] $Message" -ForegroundColor Green
}

function Write-Fail {
    param([string] $Message)
    Write-Host "[error] $Message" -ForegroundColor Red
}

function Fail {
    param([string] $Message)
    Write-Fail $Message
    throw $Message
}

function Show-Banner {
    Write-Host ""
    Write-Host "KubeZT Bind Tool" -ForegroundColor White
    Write-Host "Binding to cluster $ClusterName" -ForegroundColor DarkGray
    Write-Host ""
}

function Test-ClusterName {
    param([string] $Name)
    if ($Name -notmatch '^[a-z0-9][a-z0-9-]*$' -or $Name.Length -gt 48) {
        Fail "Invalid cluster name."
    }
}

function New-PrivateDirectory {
    param([string] $Path)
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
}

function Test-RegularDestination {
    param([string] $Path)
    if (Test-Path -LiteralPath $Path) {
        $item = Get-Item -LiteralPath $Path -Force
        if ($item.PSIsContainer) {
            Fail "Destination is not a regular file: $Path"
        }
    }
}

function ConvertTo-HexString {
    param([byte[]] $Bytes)
    -join ($Bytes | ForEach-Object { $_.ToString("x2") })
}

function Get-HmacSha256Bytes {
    param(
        [byte[]] $Key,
        [string] $Data
    )
    $hmac = [System.Security.Cryptography.HMACSHA256]::new($Key)
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Data)
        $hmac.ComputeHash($bytes)
    } finally {
        $hmac.Dispose()
    }
}

function Get-Sha256Hex {
    param([string] $Text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        ConvertTo-HexString ($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Text)))
    } finally {
        $sha.Dispose()
    }
}

function Get-FileSha256Hex {
    param([string] $Path)
    (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}

function Get-AwsCredentialsPath {
    if ($env:AWS_SHARED_CREDENTIALS_FILE) {
        return $env:AWS_SHARED_CREDENTIALS_FILE
    }
    Join-Path $HOME ".aws\credentials"
}

function Get-AwsProfile {
    param(
        [string] $Path,
        [string] $Profile
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }

    $current = $null
    $values = @{}
    foreach ($line in Get-Content -LiteralPath $Path) {
        $trimmed = $line.Trim()
        if ($trimmed -match '^\[([^\]]+)\]') {
            $current = $Matches[1]
            continue
        }
        if ($current -eq $Profile -and $trimmed -match '^([^#;][^=]*?)\s*=\s*(.*)$') {
            $values[$Matches[1].Trim()] = $Matches[2].Trim()
        }
    }

    if ($values.Count -eq 0) {
        return $null
    }
    [pscustomobject]@{
        AccessKeyId     = $values["aws_access_key_id"]
        SecretAccessKey = $values["aws_secret_access_key"]
        SessionToken    = $values["aws_session_token"]
    }
}

function Add-AwsProfile {
    param(
        [string] $Path,
        [string] $Profile
    )

    $awsDir = Split-Path -Parent $Path
    New-PrivateDirectory $awsDir

    Write-Step "AWS credentials"
    Write-Host "Profile: [$Profile]"
    $accessKeyId = Read-Host "Access Key ID"
    $secureSecret = Read-Host "Access Key Secret" -AsSecureString
    $secretPtr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureSecret)
    try {
        $secretAccessKey = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($secretPtr)
    } finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($secretPtr)
    }

    if ($accessKeyId -notmatch '^[A-Za-z0-9]+$' -or $secretAccessKey -notmatch '^[A-Za-z0-9/+=]+$') {
        Fail "Credentials must be nonempty and contain only valid key characters."
    }

    $lockPath = "$Path.kubezt-lock"
    try {
        New-Item -ItemType Directory -Path $lockPath -ErrorAction Stop | Out-Null
    } catch {
        Fail "AWS credentials are locked by another bind run. Retry after it finishes: $lockPath"
    }

    try {
        if (Get-AwsProfile -Path $Path -Profile $Profile) {
            Write-Ok "Using existing AWS profile [$Profile]; entered credentials were not saved"
            return
        }

        if (-not (Test-Path -LiteralPath $Path)) {
            New-Item -ItemType File -Path $Path -Force | Out-Null
        }

        Add-Content -LiteralPath $Path -Value ""
        Add-Content -LiteralPath $Path -Value "[$Profile]"
        Add-Content -LiteralPath $Path -Value "aws_access_key_id = $accessKeyId"
        Add-Content -LiteralPath $Path -Value "aws_secret_access_key = $secretAccessKey"
        Write-Ok "Created AWS profile [$Profile]"
    } finally {
        Remove-Item -LiteralPath $lockPath -Force -Recurse -ErrorAction SilentlyContinue
    }
}

function Get-S3Object {
    param(
        [string] $Bucket,
        [string] $Key,
        [string] $Region,
        [string] $Destination,
        [object] $Credentials
    )

    $hostName = "$Bucket.s3.$Region.amazonaws.com"
    $canonicalUri = "/" + ($Key -replace ' ', '%20')
    $now = [DateTime]::UtcNow
    $amzDate = $now.ToString("yyyyMMddTHHmmssZ")
    $dateStamp = $now.ToString("yyyyMMdd")
    $payloadHash = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

    $headers = @{
        "host" = $hostName
        "x-amz-content-sha256" = $payloadHash
        "x-amz-date" = $amzDate
    }
    if ($Credentials.SessionToken) {
        $headers["x-amz-security-token"] = $Credentials.SessionToken
    }

    $signedHeaderNames = ($headers.Keys | Sort-Object) -join ";"
    $canonicalHeaders = (($headers.Keys | Sort-Object | ForEach-Object { "$($_):$($headers[$_])`n" }) -join "")
    $canonicalRequest = "GET`n$canonicalUri`n`n$canonicalHeaders`n$signedHeaderNames`n$payloadHash"
    $credentialScope = "$dateStamp/$Region/s3/aws4_request"
    $stringToSign = "AWS4-HMAC-SHA256`n$amzDate`n$credentialScope`n$(Get-Sha256Hex $canonicalRequest)"

    $kSecret = [System.Text.Encoding]::UTF8.GetBytes("AWS4$($Credentials.SecretAccessKey)")
    $kDate = Get-HmacSha256Bytes $kSecret $dateStamp
    $kRegion = Get-HmacSha256Bytes $kDate $Region
    $kService = Get-HmacSha256Bytes $kRegion "s3"
    $kSigning = Get-HmacSha256Bytes $kService "aws4_request"
    $signature = ConvertTo-HexString (Get-HmacSha256Bytes $kSigning $stringToSign)

    $headers["Authorization"] = "AWS4-HMAC-SHA256 Credential=$($Credentials.AccessKeyId)/$credentialScope, SignedHeaders=$signedHeaderNames, Signature=$signature"
    $uri = "https://$hostName$canonicalUri"
    Invoke-WebRequest -Uri $uri -Headers $headers -OutFile $Destination -UseBasicParsing
    if (-not (Test-Path -LiteralPath $Destination) -or (Get-Item -LiteralPath $Destination).Length -eq 0) {
        Fail "Empty artifact: $Key"
    }
}

function Download-File {
    param(
        [string] $Uri,
        [string] $Destination
    )
    Invoke-WebRequest -Uri $Uri -OutFile $Destination -UseBasicParsing
    if (-not (Test-Path -LiteralPath $Destination) -or (Get-Item -LiteralPath $Destination).Length -eq 0) {
        Fail "Downloaded file is empty: $Uri"
    }
}

function Get-WindowsArchitecture {
    switch ($env:PROCESSOR_ARCHITECTURE) {
        "ARM64" { "arm64" }
        default { "amd64" }
    }
}

function Get-ClusterKubernetesVersion {
    param(
        [string] $TopologyPath,
        [string] $ClusterName
    )
    $topology = Get-Content -LiteralPath $TopologyPath -Raw | ConvertFrom-Json
    if ($topology -isnot [System.Array]) {
        Fail "Topology must be an array of clusters."
    }
    $matches = @($topology | Where-Object { $_.name -eq $ClusterName })
    if ($matches.Count -ne 1) {
        Fail "Topology must contain exactly one matching cluster."
    }
    $version = [string]$matches[0].version.rke2.version
    if (-not $version) {
        Fail "Missing cluster Kubernetes version."
    }
    $version = $version.TrimStart("v")
    $version = ($version -split "\+")[0]
    if ($version -notmatch '^(\d+)\.(\d+)\.(\d+)$') {
        Fail "Invalid Kubernetes version in the topology."
    }
    $version
}

function Test-CompatibleKubectl {
    param(
        [string] $KubectlPath,
        [string] $ServerVersion
    )
    if (-not (Test-Path -LiteralPath $KubectlPath)) {
        return $false
    }

    try {
        $clientJson = & $KubectlPath version --client --output=json 2>$null | ConvertFrom-Json
        $clientVersion = [string]$clientJson.clientVersion.gitVersion
    } catch {
        return $false
    }

    if ($clientVersion -notmatch '^v(\d+)\.(\d+)\.') {
        return $false
    }
    $clientMajor = [int]$Matches[1]
    $clientMinor = [int]$Matches[2]

    if ($ServerVersion -notmatch '^(\d+)\.(\d+)\.') {
        return $false
    }
    $serverMajor = [int]$Matches[1]
    $serverMinor = [int]$Matches[2]

    ($clientMajor -eq $serverMajor) -and ([Math]::Abs($clientMinor - $serverMinor) -le 1)
}

function Find-CompatibleKubectl {
    param([string] $ServerVersion)
    $command = Get-Command kubectl.exe -ErrorAction SilentlyContinue
    if ($command -and (Test-CompatibleKubectl -KubectlPath $command.Source -ServerVersion $ServerVersion)) {
        return $command.Source
    }
    $null
}

function Install-Kubectl {
    param(
        [string] $Version,
        [string] $Destination,
        [string] $TempDir
    )
    $arch = Get-WindowsArchitecture
    $baseUrl = "https://dl.k8s.io/release/v$Version/bin/windows/$arch/kubectl.exe"
    $candidate = Join-Path $TempDir "kubectl.exe"
    $checksumFile = Join-Path $TempDir "kubectl.exe.sha256"
    Download-File $baseUrl $candidate
    Download-File "$baseUrl.sha256" $checksumFile
    $expected = ((Get-Content -LiteralPath $checksumFile -Raw).Trim() -split '\s+')[0].ToLowerInvariant()
    $actual = Get-FileSha256Hex $candidate
    if ($expected -notmatch '^[a-fA-F0-9]{64}$' -or $actual -ne $expected) {
        Fail "SHA-256 verification failed for kubectl.exe."
    }
    Test-RegularDestination $Destination
    Move-Item -LiteralPath $candidate -Destination $Destination -Force
    Write-Ok "kubectl installed"
}

function Activate-KubeZT {
    param(
        [string] $KubeztHome,
        [string] $ClusterName,
        [string] $ToolsBin
    )
    $env:KUBEZT_HOME = $KubeztHome
    $env:CLUSTER_NAME = $ClusterName
    $env:KUBECONFIG = Join-Path (Join-Path $KubeztHome "clusters\$ClusterName") "$ClusterName.config"
    $env:KUBEZT_ADMIN_SCRIPT = Join-Path $KubeztHome "kubezt.ps1"
    if (($env:PATH -split ';') -notcontains $ToolsBin) {
        $env:PATH = "$ToolsBin;$env:PATH"
    }
    function global:kubezt {
        & $env:KUBEZT_ADMIN_SCRIPT @args
    }
    function global:prompt {
        "KubeZT ($env:CLUSTER_NAME) [$((Get-Location).Path)]> "
    }
}

function Bind-KubeZT {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string] $ClusterName,

        [Parameter(Mandatory = $false, Position = 1)]
        [string] $Region = $(if ($env:AWS_REGION) { $env:AWS_REGION } elseif ($env:AWS_DEFAULT_REGION) { $env:AWS_DEFAULT_REGION } else { "us-gov-west-1" })
    )

Test-ClusterName $ClusterName
Show-Banner

$profile = $ClusterName
$kubeztHome = if ($env:KUBEZT_HOME) { $env:KUBEZT_HOME } else { Join-Path $HOME ".kubezt" }
$kubeztHome = [System.IO.Path]::GetFullPath($kubeztHome)
$clusterDir = Join-Path $kubeztHome "clusters\$ClusterName"
$toolsBin = Join-Path $kubeztHome "tools\bin"
$bucket = "kubezt-$ClusterName-secrets"
$credentialsPath = Get-AwsCredentialsPath

New-PrivateDirectory $clusterDir
New-PrivateDirectory $toolsBin
New-PrivateDirectory (Split-Path -Parent $credentialsPath)

$credentials = Get-AwsProfile -Path $credentialsPath -Profile $profile
if ($credentials) {
    Write-Ok "Using existing AWS profile [$profile]"
} else {
    Add-AwsProfile -Path $credentialsPath -Profile $profile
    $credentials = Get-AwsProfile -Path $credentialsPath -Profile $profile
}
if (-not $credentials -or -not $credentials.AccessKeyId -or -not $credentials.SecretAccessKey) {
    Fail "AWS profile [$profile] is missing required keys."
}

$tempDir = Join-Path $clusterDir ".download.$([Guid]::NewGuid().ToString('N'))"
New-PrivateDirectory $tempDir
try {
    $artifacts = @(
        "$ClusterName-topology.json",
        "$ClusterName",
        "$ClusterName.pub",
        "$ClusterName.config"
    )

    foreach ($artifact in $artifacts) {
        Write-Step "Downloading $artifact"
        Get-S3Object -Bucket $bucket -Key $artifact -Region $Region -Destination (Join-Path $tempDir $artifact) -Credentials $credentials
        Write-Ok "Downloading $artifact"
    }

    Write-Step "Downloading kubezt.ps1"
    $kubeztToolTemp = Join-Path $tempDir "kubezt.ps1"
    Download-File "https://bind.kubezt.com/kubezt.ps1" $kubeztToolTemp
    Write-Ok "Downloading kubezt.ps1"

    $topologyPath = Join-Path $tempDir "$ClusterName-topology.json"
    $kubernetesVersion = Get-ClusterKubernetesVersion -TopologyPath $topologyPath -ClusterName $ClusterName

    $kubectlBin = Join-Path $toolsBin "kubectl.exe"
    if (-not (Test-CompatibleKubectl -KubectlPath $kubectlBin -ServerVersion $kubernetesVersion)) {
        $existingKubectl = Find-CompatibleKubectl -ServerVersion $kubernetesVersion
        if ($existingKubectl) {
            Write-Ok "Using installed kubectl"
            Copy-Item -LiteralPath $existingKubectl -Destination $kubectlBin -Force
        } else {
            Write-Step "Installing kubectl v$kubernetesVersion"
            Install-Kubectl -Version $kubernetesVersion -Destination $kubectlBin -TempDir $tempDir
        }
    } else {
        Write-Ok "Using cached kubectl"
    }

    Write-Step "Validating kubeconfig"
    & $kubectlBin --kubeconfig (Join-Path $tempDir "$ClusterName.config") config view --minify -o 'jsonpath={.current-context}' | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Fail "Kubeconfig validation failed."
    }
    Write-Ok "Kubeconfig validated"

    foreach ($artifact in $artifacts) {
        Test-RegularDestination (Join-Path $clusterDir $artifact)
    }
    Test-RegularDestination (Join-Path $kubeztHome "kubezt.ps1")

    foreach ($artifact in $artifacts) {
        Move-Item -LiteralPath (Join-Path $tempDir $artifact) -Destination (Join-Path $clusterDir $artifact) -Force
    }
    Move-Item -LiteralPath $kubeztToolTemp -Destination (Join-Path $kubeztHome "kubezt.ps1") -Force

    Write-Ok "Artifacts saved to $clusterDir"
    Write-Ok "KubeZT administrator tool installed at $(Join-Path $kubeztHome 'kubezt.ps1')"
} finally {
    Remove-Item -LiteralPath $tempDir -Force -Recurse -ErrorAction SilentlyContinue
}

Activate-KubeZT -KubeztHome $kubeztHome -ClusterName $ClusterName -ToolsBin $toolsBin
Write-Host ""
Write-Host "KubeZT ($ClusterName) is active." -ForegroundColor White
Write-Host "Run: kubezt status" -ForegroundColor White
}

if ($PSCommandPath) {
    Bind-KubeZT @args
}
