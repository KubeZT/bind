#requires -Version 5.1
<#
KubeZT administrator tool for PowerShell.

Usage:
  kubezt <command> [arguments]

This script is intended to be called through the function installed by bind.ps1:
  function kubezt { & $env:KUBEZT_ADMIN_SCRIPT @args }
#>

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:KubeZTCliVersion = '1.0.0'
$script:DefaultNamespace = if ($env:KUBEZT_NAMESPACE) { $env:KUBEZT_NAMESPACE } else { 'kubezt' }
$script:CephNamespace = if ($env:KUBEZT_CEPH_NAMESPACE) { $env:KUBEZT_CEPH_NAMESPACE } else { 'rook-ceph' }
$script:ArgoCDNamespace = if ($env:KUBEZT_ARGOCD_NAMESPACE) { $env:KUBEZT_ARGOCD_NAMESPACE } else { 'argocd' }

function Write-Info {
    param([Parameter(ValueFromRemainingArguments = $true)][object[]]$Message)
    if ($Message.Count -eq 0) { Write-Host ''; return }
    Write-Host ($Message -join ' ')
}

function Write-Warn {
    param([Parameter(ValueFromRemainingArguments = $true)][object[]]$Message)
    Write-Warning ($Message -join ' ')
}

function Fail {
    param([string]$Message)
    Write-Error "ERROR: $Message" -ErrorAction Stop
}

function Show-Usage {
@'

KubeZT administrator tool

Usage:
  kubezt <command> [arguments]

Health and inventory:
  context                         Show the active Kubernetes context
  status                          Show unhealthy nodes, pods, and applications
  nodes                           List cluster nodes
  apps                            List Argo CD applications and status
  workloads [namespace]           List common workloads
  pods [namespace]                List pods with node and IP information
  pvc [namespace]                 List persistent volume claims
  events [namespace]              List events in chronological order
  warnings [namespace]            List warning events
  top nodes                       Show node resource usage
  top pods [namespace]            Show pod resource usage

Logs and inspection:
  logs <namespace> <pod|type/name> [options]
  describe <namespace> <resource>
  recovery logs                   Follow the newest recovery pod

Platform services:
  storage status                  Show Ceph health and OSD status
  backups status                  Show Velero backups and backup Jobs
  platform status                 Run the overall platform health check
  platform stop                   Reserved for the approved stop sequence
  platform start                  Reserved for the approved start sequence

Administrative access:
  access token <service> --show
  access credentials <service> --show
  proxy <service> [arguments]

Other:
  help [command]                  Show help
  version                         Show admin tool version

Examples:
  kubezt status
  kubezt apps
  kubezt workloads kubezt
  kubezt logs kubezt deployment/kubezt-api --since 1h
  kubezt logs kubezt kubezt-api-abc123 --previous --no-follow
  kubezt events kubezt
  kubezt storage status
  kubezt access token clusterops --show
  kubezt proxy grafana

Run 'kubezt help <command>' for command-specific help.

'@
}

function Show-LogsUsage {
@'

Usage:
  kubezt logs <namespace> <pod|type/name> [options]

Options:
  --container <name>   Select a container
  --previous           Show the previous container instance
  --no-follow          Print logs and exit instead of following
  --since <duration>   Show logs newer than a duration (default: 1h)
  --tail <lines>       Number of recent lines (default: 200)

Examples:
  kubezt logs kubezt deployment/kubezt-api
  kubezt logs kubezt kubezt-api-abc123 --container api
  kubezt logs kubezt kubezt-api-abc123 --previous --no-follow

'@
}

function Show-ProxyUsage {
@'

Usage:
  kubezt proxy <service> [arguments]

Services:
  openbao                  localhost:8200  -> openbao:8200
  mongo                    localhost:27018 -> MongoDB:27017
  ipa [namespace]          localhost:8443  -> IPA HTTPS:443
  ldaps [namespace]        localhost:1636  -> IPA LDAPS:636
  ldap [namespace]         localhost:1389  -> IPA LDAP:389
  kerberos [namespace]     localhost:1088  -> IPA Kerberos:88
  redis                    localhost:6380  -> Redis:6379
  ceph                     localhost:7000  -> Ceph dashboard:7000
  envoy                    localhost:9001  -> Envoy admin:9001
  pgo                      localhost:8443  -> Postgres operator:8443
  fs <name> [namespace]    localhost:8088  -> fs-<name>:8080
  nfs <service> [namespace]
                           localhost:5555  -> service:5555
  postgres [namespace]     localhost:5432  -> PostgreSQL:5432
  kiali                    localhost:20001 -> Kiali:20001
  kibana                   localhost:5601  -> Kibana:5601
  grafana                  localhost:3000  -> Grafana:80
  yunikorn                 localhost:9889  -> YuniKorn UI:9889
  yunikorn-api             localhost:9080  -> YuniKorn API:9080
  gitea [namespace]        localhost:3333  -> Gitea:3000
  openobserve              localhost:5080  -> OpenObserve:5080
  argo-builds              localhost:10000 -> Argo Events build eventsource
  argo-events              localhost:2746  -> Argo Server:2746
  argo-cd                  localhost:8081  -> Argo CD:80
  ziti                     localhost:1281  -> Ziti management API:1281

'@
}

function Show-AccessUsage {
@'

Usage:
  kubezt access token <service> --show
  kubezt access credentials <service> --show

Token services:
  clusterops
  kiali
  openbao

Credential services:
  ziti
  ceph
  kibana

Sensitive values are printed only when --show is provided.

'@
}

function Invoke-Kubectl {
    & kubectl @args
}

function Get-KubectlJson {
    $kubectlArgs = @($args)
    $raw = & kubectl @kubectlArgs -o json
    if ($LASTEXITCODE -ne 0) { Fail "kubectl $($kubectlArgs -join ' ') failed." }
    ($raw | Out-String | ConvertFrom-Json)
}

function Test-KubectlSucceeded {
    $kubectlArgs = @($args)
    $null = & kubectl @kubectlArgs 2>$null
    return ($LASTEXITCODE -eq 0)
}

function Require-Kubectl {
    if (-not (Get-Command kubectl -ErrorAction SilentlyContinue)) {
        Fail "kubectl was not found. Run the KubeZT bind script first or add kubectl to PATH."
    }
}

function Current-Context {
    Require-Kubectl
    $context = (& kubectl config current-context 2>$null | Select-Object -First 1)
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($context)) {
        Fail "No active Kubernetes context. Run the KubeZT bind script first."
    }
    $context.Trim()
}

function Require-Cluster {
    $null = Current-Context
    $null = & kubectl get nodes --request-timeout=10s 2>$null
    if ($LASTEXITCODE -ne 0) {
        Fail "Unable to reach the Kubernetes API. Confirm the zero trust client is connected and KUBECONFIG is set."
    }
}

function Has-Crd {
    param([string]$Name)
    $null = & kubectl get crd $Name 2>$null
    $LASTEXITCODE -eq 0
}

function Format-TableRows {
    param(
        [Parameter(Mandatory)][string[]]$Headers,
        [Parameter(Mandatory)][object[]]$Rows
    )

    if ($Rows.Count -eq 0) { return }

    $widths = @()
    for ($i = 0; $i -lt $Headers.Count; $i++) { $widths += $Headers[$i].Length }
    foreach ($row in $Rows) {
        for ($i = 0; $i -lt $Headers.Count; $i++) {
            $value = [string]$row[$i]
            if ($value.Length -gt $widths[$i]) { $widths[$i] = $value.Length }
        }
    }

    $line = for ($i = 0; $i -lt $Headers.Count; $i++) { ('{0,-' + $widths[$i] + '}') -f $Headers[$i] }
    Write-Host ($line -join '  ')
    $line = for ($i = 0; $i -lt $Headers.Count; $i++) { '-' * $widths[$i] }
    Write-Host ($line -join '  ')
    foreach ($row in $Rows) {
        $line = for ($i = 0; $i -lt $Headers.Count; $i++) { ('{0,-' + $widths[$i] + '}') -f ([string]$row[$i]) }
        Write-Host ($line -join '  ')
    }
}

function Decode-Base64String {
    param([string]$Value)
    [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Value))
}

function Require-ShowFlag {
    param([string]$Flag)
    if ($Flag -ne '--show') {
        Fail "This command prints sensitive values. Re-run with --show."
    }
}

function Get-LatestPod {
    param(
        [string]$Namespace,
        [string]$Regex
    )
    $pods = (Get-KubectlJson get pods -n $Namespace).items
    $match = @($pods | Where-Object { $_.metadata.name -match $Regex } | Sort-Object { $_.metadata.creationTimestamp } -Descending | Select-Object -First 1)
    if ($match.Count -eq 0) { return $null }
    $match[0].metadata.name
}

function Get-FirstRunningPodBySelector {
    param(
        [string]$Namespace,
        [string]$Selector
    )
    $pods = (Get-KubectlJson get pods -n $Namespace -l $Selector).items
    $match = @($pods | Where-Object { $_.status.phase -eq 'Running' } | Sort-Object { $_.metadata.creationTimestamp } | Select-Object -First 1)
    if ($match.Count -eq 0) { return $null }
    $match[0].metadata.name
}

function Invoke-Context { Current-Context }

function Invoke-Status {
    Require-Cluster
    $context = Current-Context
    Write-Info "Checking cluster health..."
    Write-Info "Context: $context"
    Write-Info ''

    $nodeRows = @()
    $nodes = (Get-KubectlJson get nodes).items
    foreach ($node in $nodes) {
        $ready = @($node.status.conditions | Where-Object { $_.type -eq 'Ready' } | Select-Object -First 1)
        if ($ready.Count -eq 0 -or $ready[0].status -ne 'True') {
            $status = if ($ready.Count -gt 0) { $ready[0].status } else { 'Unknown' }
            $nodeRows += ,@($node.metadata.name, $status)
        }
    }

    $podRows = @()
    $pods = (Get-KubectlJson get pods -A).items
    foreach ($pod in $pods) {
        $phase = [string]$pod.status.phase
        $containers = @($pod.status.containerStatuses)
        $total = $containers.Count
        $ready = @($containers | Where-Object { $_.ready -eq $true }).Count
        $readyText = "$ready/$total"
        $restartCount = 0
        foreach ($container in $containers) { $restartCount += [int]$container.restartCount }
        $statusOk = $phase -in @('Running', 'Succeeded', 'Completed')
        $readyOk = ($phase -in @('Succeeded', 'Completed')) -or ($total -gt 0 -and $ready -eq $total)
        if (-not $statusOk -or -not $readyOk) {
            $podRows += ,@($pod.metadata.namespace, $pod.metadata.name, $readyText, $phase, $restartCount)
        }
    }

    $appRows = @()
    if (Has-Crd 'applications.argoproj.io') {
        $apps = (Get-KubectlJson get applications.argoproj.io -A).items
        foreach ($app in $apps) {
            $sync = if ($app.status.sync.status) { $app.status.sync.status } else { 'Unknown' }
            $health = if ($app.status.health.status) { $app.status.health.status } else { 'Unknown' }
            if ($sync -ne 'Synced' -or $health -ne 'Healthy') {
                $appRows += ,@($app.metadata.namespace, $app.metadata.name, $sync, $health)
            }
        }
    }

    if ($nodeRows.Count -eq 0 -and $podRows.Count -eq 0 -and $appRows.Count -eq 0) {
        Write-Info "Cluster is Healthy"
        return
    }

    if ($nodeRows.Count -gt 0) {
        Write-Info "Nodes requiring attention:"
        Format-TableRows -Headers @('NODE', 'STATUS') -Rows $nodeRows
        Write-Info ''
    }
    if ($podRows.Count -gt 0) {
        Write-Info "Pods requiring attention:"
        Format-TableRows -Headers @('NAMESPACE', 'POD', 'READY', 'STATUS', 'RESTARTS') -Rows $podRows
        Write-Info ''
    }
    if ($appRows.Count -gt 0) {
        Write-Info "Applications requiring attention:"
        Format-TableRows -Headers @('NAMESPACE', 'APPLICATION', 'SYNC', 'HEALTH') -Rows $appRows
        Write-Info ''
    }

    Write-Warn "Cluster requires attention."
    exit 1
}

function Invoke-Nodes { Require-Cluster; Invoke-Kubectl get nodes -o wide }

function Invoke-Apps {
    Require-Cluster
    if (-not (Has-Crd 'applications.argoproj.io')) { Fail "The Argo CD Application resource is not installed." }
    Invoke-Kubectl get applications.argoproj.io -A -o 'custom-columns=NAMESPACE:.metadata.namespace,NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status,REVISION:.status.sync.revision'
}

function Invoke-Workloads {
    param([string[]]$Rest)
    Require-Cluster
    $namespace = if ($Rest.Count -gt 0 -and $Rest[0]) { $Rest[0] } else { $script:DefaultNamespace }
    Invoke-Kubectl get deploy,sts,ds,job,cronjob -n $namespace -o wide
}

function Invoke-Pods {
    param([string[]]$Rest)
    Require-Cluster
    $namespace = if ($Rest.Count -gt 0 -and $Rest[0]) { $Rest[0] } else { $script:DefaultNamespace }
    Invoke-Kubectl get pods -n $namespace -o wide
}

function Invoke-Pvc {
    param([string[]]$Rest)
    Require-Cluster
    $namespace = if ($Rest.Count -gt 0 -and $Rest[0]) { $Rest[0] } else { $script:DefaultNamespace }
    Invoke-Kubectl get pvc -n $namespace
}

function Invoke-Events {
    param([string[]]$Rest)
    Require-Cluster
    $namespace = if ($Rest.Count -gt 0 -and $Rest[0]) { $Rest[0] } else { $script:DefaultNamespace }
    Invoke-Kubectl get events -n $namespace --sort-by=.metadata.creationTimestamp
}

function Invoke-Warnings {
    param([string[]]$Rest)
    Require-Cluster
    $namespace = if ($Rest.Count -gt 0 -and $Rest[0]) { $Rest[0] } else { $script:DefaultNamespace }
    Invoke-Kubectl get events -n $namespace --field-selector type=Warning --sort-by=.metadata.creationTimestamp
}

function Invoke-Top {
    param([string[]]$Rest)
    Require-Cluster
    $kind = if ($Rest.Count -gt 0) { $Rest[0] } else { '' }
    switch ($kind) {
        'nodes' { Invoke-Kubectl top nodes }
        'pods' {
            $namespace = if ($Rest.Count -gt 1 -and $Rest[1]) { $Rest[1] } else { $script:DefaultNamespace }
            Invoke-Kubectl top pods -n $namespace
        }
        default { Fail "Usage: kubezt top <nodes|pods> [namespace]" }
    }
}

function Invoke-Logs {
    param([string[]]$Rest)
    Require-Cluster
    if ($Rest.Count -lt 2) { Show-LogsUsage; Fail "Missing namespace or resource." }

    $namespace = $Rest[0]
    $resource = $Rest[1]
    $container = $null
    $previous = $false
    $follow = $true
    $since = '1h'
    $tail = '200'

    $i = 2
    while ($i -lt $Rest.Count) {
        switch ($Rest[$i]) {
            '--container' {
                $i++
                if ($i -ge $Rest.Count) { Fail "--container requires a value." }
                $container = $Rest[$i]
            }
            '--previous' { $previous = $true }
            '--no-follow' { $follow = $false }
            '--since' {
                $i++
                if ($i -ge $Rest.Count) { Fail "--since requires a value." }
                $since = $Rest[$i]
            }
            '--tail' {
                $i++
                if ($i -ge $Rest.Count) { Fail "--tail requires a value." }
                $tail = $Rest[$i]
            }
            '-h' { Show-LogsUsage; return }
            '--help' { Show-LogsUsage; return }
            default { Fail "Unknown logs option: $($Rest[$i])" }
        }
        $i++
    }

    $kubectlArgs = @('logs', '-n', $namespace, $resource, '--since', $since, '--tail', $tail)
    if ($container) { $kubectlArgs += @('-c', $container) }
    if ($previous) { $kubectlArgs += '--previous' }
    if ($follow) { $kubectlArgs += '-f' }
    Invoke-Kubectl @kubectlArgs
}

function Invoke-Describe {
    param([string[]]$Rest)
    Require-Cluster
    if ($Rest.Count -lt 2) { Fail "Usage: kubezt describe <namespace> <resource>" }
    Invoke-Kubectl describe -n $Rest[0] $Rest[1]
}

function Invoke-Recovery {
    param([string[]]$Rest)
    $sub = if ($Rest.Count -gt 0) { $Rest[0] } else { '' }
    if ($sub -ne 'logs') { Fail "Usage: kubezt recovery logs" }
    Require-Cluster
    $pod = Get-LatestPod -Namespace $script:DefaultNamespace -Regex '^recovery-'
    if (-not $pod) { Fail "No recovery pod was found in namespace $($script:DefaultNamespace)." }
    Invoke-Kubectl logs -n $script:DefaultNamespace $pod --since 1h --tail 200 -f
}

function Invoke-Storage {
    param([string[]]$Rest)
    $sub = if ($Rest.Count -gt 0) { $Rest[0] } else { '' }
    if ($sub -ne 'status') { Fail "Usage: kubezt storage status" }
    Require-Cluster
    $pod = Get-FirstRunningPodBySelector -Namespace $script:CephNamespace -Selector 'app=rook-ceph-tools'
    if (-not $pod) { Fail "No running rook-ceph-tools pod was found." }
    Write-Info "Ceph status:"
    Invoke-Kubectl exec -n $script:CephNamespace $pod -- ceph status
    Write-Info ''
    Write-Info "Ceph OSD status:"
    Invoke-Kubectl exec -n $script:CephNamespace $pod -- ceph osd status
}

function Invoke-Backups {
    param([string[]]$Rest)
    $sub = if ($Rest.Count -gt 0) { $Rest[0] } else { '' }
    if ($sub -ne 'status') { Fail "Usage: kubezt backups status" }
    Require-Cluster
    if (Has-Crd 'backups.velero.io') {
        Write-Info "Velero backups:"
        Invoke-Kubectl get backups.velero.io -A
        Write-Info ''
    }
    Write-Info "Backup Jobs:"
    Invoke-Kubectl get jobs -A
}

function Invoke-Platform {
    param([string[]]$Rest)
    $sub = if ($Rest.Count -gt 0) { $Rest[0] } else { '' }
    switch ($sub) {
        'status' { Invoke-Status }
        'stop' { Fail "Platform stop is not configured. Add only the approved service shutdown sequence." }
        'start' { Fail "Platform start is not configured. Add only the approved service startup sequence." }
        default { Fail "Usage: kubezt platform <status|stop|start>" }
    }
}

function Invoke-AccessToken {
    param([string[]]$Rest)
    $service = if ($Rest.Count -gt 0) { $Rest[0] } else { '' }
    $showFlag = if ($Rest.Count -gt 1) { $Rest[1] } else { '' }
    Require-ShowFlag $showFlag
    Require-Cluster
    switch ($service) {
        'clusterops' { Invoke-Kubectl get secret headlamp-admin-user --namespace kube-system --output 'go-template={{index .data "token" | base64decode}}{{"\n"}}' }
        'kiali' { Invoke-Kubectl -n istio-system create token kiali-service-account }
        'openbao' {
            $value = (& kubectl get secret openbao-keys -n $script:DefaultNamespace -o 'jsonpath={.data.root_token}')
            if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($value)) { Fail "Unable to read OpenBao token." }
            Write-Host (Decode-Base64String $value)
        }
        default { Fail "Supported token services: clusterops, kiali, openbao" }
    }
}

function Invoke-AccessCredentials {
    param([string[]]$Rest)
    $service = if ($Rest.Count -gt 0) { $Rest[0] } else { '' }
    $showFlag = if ($Rest.Count -gt 1) { $Rest[1] } else { '' }
    Require-ShowFlag $showFlag
    Require-Cluster
    switch ($service) {
        'ziti' {
            Write-Info "Username: admin"
            Invoke-Kubectl get secret ziti-controller-admin-secret -n $script:DefaultNamespace --output 'go-template={{index .data "admin-password" | base64decode}}{{"\n"}}'
        }
        'ceph' {
            Write-Info "Username: admin"
            $value = (& kubectl get secret rook-ceph-dashboard-password -n $script:CephNamespace -o 'jsonpath={.data.password}')
            if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($value)) { Fail "Unable to read Ceph dashboard password." }
            Write-Host (Decode-Base64String $value)
        }
        'kibana' {
            Write-Info "Username: elastic"
            $value = (& kubectl get secret kubezt-es-elastic-user -n $script:DefaultNamespace -o 'jsonpath={.data.elastic}')
            if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($value)) { Fail "Unable to read Kibana password." }
            Write-Host (Decode-Base64String $value)
        }
        'openobserve' { Fail "OpenObserve credential retrieval is not configured because the supplied admin tool referenced the Ziti Secret." }
        default { Fail "Supported credential services: ziti, ceph, kibana" }
    }
}

function Invoke-Access {
    param([string[]]$Rest)
    $kind = if ($Rest.Count -gt 0) { $Rest[0] } else { '' }
    $remaining = if ($Rest.Count -gt 1) { $Rest[1..($Rest.Count - 1)] } else { @() }
    switch ($kind) {
        'token' { Invoke-AccessToken -Rest $remaining }
        'credentials' { Invoke-AccessCredentials -Rest $remaining }
        '' { Show-AccessUsage }
        'help' { Show-AccessUsage }
        '-h' { Show-AccessUsage }
        '--help' { Show-AccessUsage }
        default { Fail "Usage: kubezt access <token|credentials> <service> --show" }
    }
}

function Start-PortForward {
    param(
        [string]$Namespace,
        [string]$Resource,
        [string]$Mapping
    )
    Write-Info "Context: $(Current-Context)"
    Write-Info "Namespace: $Namespace"
    Write-Info "Forwarding $Resource on $Mapping"
    Write-Info "Press Ctrl+C to stop."
    Invoke-Kubectl port-forward -n $Namespace $Resource $Mapping
}

function Invoke-Proxy {
    param([string[]]$Rest)
    Require-Cluster
    $service = if ($Rest.Count -gt 0) { $Rest[0] } else { '' }
    $a = if ($Rest.Count -gt 1) { $Rest[1..($Rest.Count - 1)] } else { @() }

    switch ($service) {
        'openbao' { Start-PortForward $script:DefaultNamespace 'service/openbao' '8200:8200' }
        'mongo' { Start-PortForward $script:DefaultNamespace 'service/kubezt-mongodb-psmdb-mongos' '27018:27017' }
        'ipa' { Start-PortForward ($(if ($a.Count -gt 0) { $a[0] } else { $script:DefaultNamespace })) 'service/ipa' '8443:443' }
        'ldaps' { Start-PortForward ($(if ($a.Count -gt 0) { $a[0] } else { $script:DefaultNamespace })) 'service/ipa' '1636:636' }
        'ldap' { Start-PortForward ($(if ($a.Count -gt 0) { $a[0] } else { $script:DefaultNamespace })) 'service/ipa' '1389:389' }
        'kerberos' { Start-PortForward ($(if ($a.Count -gt 0) { $a[0] } else { $script:DefaultNamespace })) 'service/ipa' '1088:88' }
        'redis' { Start-PortForward $script:DefaultNamespace 'service/redis-master' '6380:6379' }
        'ceph' { Start-PortForward $script:CephNamespace 'service/rook-ceph-mgr-dashboard' '7000:7000' }
        'envoy' {
            $pod = Get-FirstRunningPodBySelector -Namespace 'projectcontour' -Selector 'app=envoy'
            if (-not $pod) { Fail "No running Envoy pod was found." }
            Start-PortForward 'projectcontour' "pod/$pod" '9001:9001'
        }
        'pgo' { Start-PortForward 'pgo' 'service/postgres-operator' '8443:8443' }
        'fs' {
            if ($a.Count -lt 1 -or -not $a[0]) { Fail "Usage: kubezt proxy fs <name> [namespace]" }
            $namespace = if ($a.Count -gt 1 -and $a[1]) { $a[1] } else { $script:DefaultNamespace }
            Start-PortForward $namespace "service/fs-$($a[0])" '8088:8080'
        }
        'nfs' {
            if ($a.Count -lt 1 -or -not $a[0]) { Fail "Usage: kubezt proxy nfs <service> [namespace]" }
            $namespace = if ($a.Count -gt 1 -and $a[1]) { $a[1] } else { $script:DefaultNamespace }
            Start-PortForward $namespace "service/$($a[0])" '5555:5555'
        }
        'postgres' { Start-PortForward ($(if ($a.Count -gt 0) { $a[0] } else { $script:DefaultNamespace })) 'service/kubezt-postgres-primary' '5432:5432' }
        'kiali' { Start-PortForward 'istio-system' 'service/kiali' '20001:20001' }
        'kibana' { Start-PortForward $script:DefaultNamespace 'service/quickstart-kb-http' '5601:5601' }
        'grafana' { Start-PortForward 'monitoring' 'service/kubezt-prom-grafana' '3000:80' }
        'yunikorn' { Start-PortForward 'yunikorn' 'service/yunikorn-service' '9889:9889' }
        'yunikorn-api' { Start-PortForward 'yunikorn' 'service/yunikorn-service' '9080:9080' }
        'gitea' { Start-PortForward ($(if ($a.Count -gt 0) { $a[0] } else { $script:DefaultNamespace })) 'service/gitea' '3333:3000' }
        'openobserve' { Start-PortForward $script:DefaultNamespace 'service/openobserve-querier' '5080:5080' }
        'argo-builds' { Start-PortForward 'argo-events' 'service/builds-eventsource-svc' '10000:10000' }
        'argo-events' { Start-PortForward 'argo' 'deployment/argo-server' '2746:2746' }
        'argo-cd' { Start-PortForward $script:ArgoCDNamespace 'service/argocd-server' '8081:80' }
        'ziti' {
            Write-Info "Ziti console: https://127.0.0.1:1281/zac/"
            Start-PortForward $script:DefaultNamespace 'service/ziti-controller-mgmt' '1281:1281'
        }
        '' { Show-ProxyUsage }
        'help' { Show-ProxyUsage }
        '-h' { Show-ProxyUsage }
        '--help' { Show-ProxyUsage }
        default { Fail "Unknown proxy service: $service" }
    }
}

function Invoke-LegacyApiLogs {
    param([string[]]$Rest)
    Require-Cluster
    $number = if ($Rest.Count -gt 0 -and $Rest[0]) { $Rest[0] } else { '' }
    $pods = @((Get-KubectlJson get pods -n $script:DefaultNamespace).items | Where-Object { $_.metadata.name -match 'api' } | Sort-Object { $_.metadata.name })
    if ($pods.Count -eq 0) { Fail "No API pods were found in namespace $($script:DefaultNamespace)." }
    if ($number -match '^\d+$') {
        $index = [int]$number - 1
        if ($index -lt 0 -or $index -ge $pods.Count) { Fail "API pod number out of range." }
        $pod = $pods[$index].metadata.name
    } else {
        $pod = $pods[0].metadata.name
    }
    Invoke-Kubectl logs -n $script:DefaultNamespace $pod --since 1h --tail 200 -f
}

function Invoke-LegacyCertManagerLogs {
    Require-Cluster
    $pod = Get-FirstRunningPodBySelector -Namespace 'cert-manager' -Selector 'app.kubernetes.io/instance=cert-manager'
    if (-not $pod) { Fail "No running cert-manager pod was found." }
    Invoke-Kubectl logs -n cert-manager $pod --since 1h --tail 200 -f
}

function Invoke-Help {
    param([string[]]$Rest)
    $topic = if ($Rest.Count -gt 0) { $Rest[0] } else { '' }
    switch ($topic) {
        'logs' { Show-LogsUsage }
        'proxy' { Show-ProxyUsage }
        'access' { Show-AccessUsage }
        default { Show-Usage }
    }
}

function Invoke-KubeZT {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)

    $command = if ($Arguments.Count -gt 0) { $Arguments[0] } else { '' }
    $rest = if ($Arguments.Count -gt 1) { $Arguments[1..($Arguments.Count - 1)] } else { @() }

    switch ($command) {
        'context' { Invoke-Context }
        'status' { Invoke-Status }
        'nodes' { Invoke-Nodes }
        'apps' { Invoke-Apps }
        'workloads' { Invoke-Workloads -Rest $rest }
        'pods' { Invoke-Pods -Rest $rest }
        'pvc' { Invoke-Pvc -Rest $rest }
        'events' { Invoke-Events -Rest $rest }
        'warnings' { Invoke-Warnings -Rest $rest }
        'top' { Invoke-Top -Rest $rest }
        'logs' { Invoke-Logs -Rest $rest }
        'describe' { Invoke-Describe -Rest $rest }
        'recovery' { Invoke-Recovery -Rest $rest }
        'storage' { Invoke-Storage -Rest $rest }
        'backups' { Invoke-Backups -Rest $rest }
        'platform' { Invoke-Platform -Rest $rest }
        'access' { Invoke-Access -Rest $rest }
        'proxy' { Invoke-Proxy -Rest $rest }
        'api' {
            if ($rest.Count -lt 1 -or $rest[0] -ne 'logs') { Fail "Usage: kubezt api logs [pod number]" }
            $r = if ($rest.Count -gt 1) { $rest[1..($rest.Count - 1)] } else { @() }
            Invoke-LegacyApiLogs -Rest $r
        }
        'cert-manager' {
            if ($rest.Count -lt 1 -or $rest[0] -ne 'logs') { Fail "Usage: kubezt cert-manager logs" }
            Invoke-LegacyCertManagerLogs
        }
        'ceph' {
            if ($rest.Count -lt 1 -or $rest[0] -ne 'status') { Fail "Usage: kubezt ceph status" }
            Invoke-Storage -Rest @('status')
        }
        'clusterops' {
            if ($rest.Count -lt 1 -or $rest[0] -ne 'token') { Fail "Usage: kubezt clusterops token" }
            Write-Warn "Legacy command. Prefer 'kubezt access token clusterops --show'."
            Invoke-AccessToken -Rest @('clusterops', '--show')
        }
        'kiali' {
            if ($rest.Count -lt 1 -or $rest[0] -ne 'token') { Fail "Usage: kubezt kiali token" }
            Write-Warn "Legacy command. Prefer 'kubezt access token kiali --show'."
            Invoke-AccessToken -Rest @('kiali', '--show')
        }
        'openbao' {
            if ($rest.Count -lt 1 -or $rest[0] -ne 'token') { Fail "Usage: kubezt openbao token" }
            Write-Warn "Legacy command. Prefer 'kubezt access token openbao --show'."
            Invoke-AccessToken -Rest @('openbao', '--show')
        }
        'ziti' {
            if ($rest.Count -lt 1 -or $rest[0] -ne 'token') { Fail "Usage: kubezt ziti token" }
            Write-Warn "Legacy command. Prefer 'kubezt access credentials ziti --show'."
            Invoke-AccessCredentials -Rest @('ziti', '--show')
        }
        'build' { Fail "'build' is an engineering/release action and is intentionally excluded from the administrator helper." }
        'deploy' { Fail "'deploy' is an engineering/release action and is intentionally excluded from the administrator helper." }
        'version' { Write-Info $script:KubeZTCliVersion }
        'help' { Invoke-Help -Rest $rest }
        '-h' { Show-Usage }
        '--help' { Show-Usage }
        '' { Show-Usage }
        default { Fail "Unknown command: $command. Run 'kubezt help'." }
    }
}

Invoke-KubeZT @args
