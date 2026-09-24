#!/bin/bash

set -Eeuo pipefail
IFS=$'\n\t'

readonly KUBEZT_CLI_VERSION="1.0.0"
readonly DEFAULT_NAMESPACE="${KUBEZT_NAMESPACE:-kubezt}"
readonly CEPH_NAMESPACE="${KUBEZT_CEPH_NAMESPACE:-rook-ceph}"
readonly ARGOCD_NAMESPACE="${KUBEZT_ARGOCD_NAMESPACE:-argocd}"

info() {
  printf '%s\n' "$*"
}

warn() {
  printf 'WARNING: %s\n' "$*" >&2
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'

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
  logs <namespace> <resource> [options]
  describe <namespace> <resource>
  recovery logs                  Follow the newest recovery pod

Platform services:
  storage status                 Show Ceph health and OSD status
  backups status                 Show Velero backups and backup Jobs
  platform status                Run the overall platform health check
  platform stop                  Reserved for the approved stop sequence
  platform start                 Reserved for the approved start sequence

Administrative access:
  access token <service> --show
  access credentials <service> --show
  proxy <service> [arguments]

Other:
  help [command]                 Show help
  version                        Show admin tool version

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

EOF
}

logs_usage() {
  cat <<'EOF'

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

EOF
}

proxy_usage() {
  cat <<'EOF'

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
  argo-builds              localhost:10000 -> Argo builds:10000
  argo-events              localhost:2746  -> Argo Events UI:2746
  argo-cd                  localhost:8081  -> Argo CD:80
  ziti                     localhost:1281  -> Ziti management:1281

The proxy remains active until Ctrl+C is pressed.

EOF
}

access_usage() {
  cat <<'EOF'

Usage:
  kubezt access token clusterops --show
  kubezt access token kiali --show
  kubezt access token openbao --show
  kubezt access credentials ziti --show
  kubezt access credentials ceph --show
  kubezt access credentials kibana --show

Credential output is disabled unless --show is supplied. Never save the
output in shell history, screenshots, tickets, chat, or reports.

EOF
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

current_context() {
  kubectl config current-context 2>/dev/null || true
}

require_context() {
  require_command kubectl

  local context
  context="$(current_context)"
  [[ -n "$context" ]] || die "No Kubernetes context is selected. Run '. ./config.sh <cluster name>' first."
}

require_cluster() {
  require_context
  kubectl get nodes --request-timeout=10s >/dev/null 2>&1 ||
    die "Cannot reach the selected cluster or list its nodes."
}

cmd_context() {
  require_context

  local context namespace server
  context="$(current_context)"
  namespace="$(kubectl config view --minify -o jsonpath='{..namespace}' 2>/dev/null || true)"
  server="$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || true)"
  [[ -n "$namespace" ]] || namespace="default"

  printf '%-14s %s\n' "CONTEXT" "$context"
  printf '%-14s %s\n' "NAMESPACE" "$namespace"
  printf '%-14s %s\n' "API SERVER" "${server:-unknown}"
}

cmd_status() {
  require_cluster

  local context unhealthy_nodes unhealthy_pods unhealthy_apps
  context="$(current_context)"

  info "Checking cluster health..."
  info "Context: $context"
  info ""

  unhealthy_nodes="$(
    kubectl get nodes --no-headers |
      awk '$2 != "Ready" { printf "%-45s %-24s\n", $1, $2 }'
  )"

  unhealthy_pods="$(
    kubectl get pods -A --no-headers |
      awk '
        {
          split($3, ready, "/")
          status_ok = ($4 == "Running" || $4 == "Completed" || $4 == "Succeeded")
          ready_ok = ($4 == "Completed" || $4 == "Succeeded" ||
                      (ready[1] == ready[2] && ready[2] != ""))

          if (!status_ok || !ready_ok) {
            printf "%-20s %-55s %-10s %-22s %s\n", $1, $2, $3, $4, $5
          }
        }'
  )"

  unhealthy_apps=""
  if kubectl get crd applications.argoproj.io >/dev/null 2>&1; then
    unhealthy_apps="$(
      kubectl get applications.argoproj.io -A --no-headers \
        -o custom-columns='NAMESPACE:.metadata.namespace,NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status' |
        awk '$3 != "Synced" || $4 != "Healthy" {
          printf "%-20s %-45s %-14s %s\n", $1, $2, $3, $4
        }'
    )"
  fi

  if [[ -z "$unhealthy_nodes" && -z "$unhealthy_pods" && -z "$unhealthy_apps" ]]; then
    info "Cluster is Healthy"
    return 0
  fi

  if [[ -n "$unhealthy_nodes" ]]; then
    info "Nodes requiring attention:"
    printf '%-45s %-24s\n' "NODE" "STATUS"
    printf '%-45s %-24s\n' "----" "------"
    printf '%s\n\n' "$unhealthy_nodes"
  fi

  if [[ -n "$unhealthy_pods" ]]; then
    info "Pods requiring attention:"
    printf '%-20s %-55s %-10s %-22s %s\n' \
      "NAMESPACE" "POD" "READY" "STATUS" "RESTARTS"
    printf '%-20s %-55s %-10s %-22s %s\n' \
      "---------" "---" "-----" "------" "--------"
    printf '%s\n\n' "$unhealthy_pods"
  fi

  if [[ -n "$unhealthy_apps" ]]; then
    info "Applications requiring attention:"
    printf '%-20s %-45s %-14s %s\n' "NAMESPACE" "APPLICATION" "SYNC" "HEALTH"
    printf '%-20s %-45s %-14s %s\n' "---------" "-----------" "----" "------"
    printf '%s\n\n' "$unhealthy_apps"
  fi

  warn "Cluster requires attention."
  return 1
}

cmd_nodes() {
  require_cluster
  kubectl get nodes -o wide
}

cmd_apps() {
  require_cluster
  kubectl get crd applications.argoproj.io >/dev/null 2>&1 ||
    die "The Argo CD Application resource is not installed."

  kubectl get applications.argoproj.io -A \
    -o custom-columns='NAMESPACE:.metadata.namespace,NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status,OPERATION:.status.operationState.phase'
}

cmd_workloads() {
  require_cluster

  local namespace="${1:-}"
  if [[ -n "$namespace" ]]; then
    kubectl get deployments,statefulsets,daemonsets,jobs,pods -n "$namespace"
  else
    kubectl get deployments,statefulsets,daemonsets,jobs,pods -A
  fi
}

cmd_pods() {
  require_cluster

  local namespace="${1:-}"
  if [[ -n "$namespace" ]]; then
    kubectl get pods -n "$namespace" -o wide
  else
    kubectl get pods -A -o wide
  fi
}

cmd_pvc() {
  require_cluster

  local namespace="${1:-}"
  if [[ -n "$namespace" ]]; then
    kubectl get pvc -n "$namespace"
  else
    kubectl get pvc -A
  fi
}

cmd_events() {
  require_cluster

  local namespace="${1:-}"
  if [[ -n "$namespace" ]]; then
    kubectl get events -n "$namespace" --sort-by=.metadata.creationTimestamp
  else
    kubectl get events -A --sort-by=.metadata.creationTimestamp
  fi
}

cmd_warnings() {
  require_cluster

  local namespace="${1:-}"
  if [[ -n "$namespace" ]]; then
    kubectl get events -n "$namespace" \
      --field-selector type=Warning \
      --sort-by=.metadata.creationTimestamp
  else
    kubectl get events -A \
      --field-selector type=Warning \
      --sort-by=.metadata.creationTimestamp
  fi
}

cmd_top() {
  require_cluster

  local resource="${1:-}"
  local namespace="${2:-}"

  case "$resource" in
    nodes)
      kubectl top nodes
      ;;
    pods)
      if [[ -n "$namespace" ]]; then
        kubectl top pods -n "$namespace"
      else
        kubectl top pods -A
      fi
      ;;
    *)
      die "Usage: kubezt top nodes | kubezt top pods [namespace]"
      ;;
  esac
}

cmd_logs() {
  require_cluster
  [[ $# -ge 2 ]] || {
    logs_usage
    exit 1
  }

  local namespace="$1"
  local resource="$2"
  shift 2

  local container=""
  local follow="true"
  local previous="false"
  local since="1h"
  local tail_lines="200"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --container)
        shift
        [[ $# -gt 0 ]] || die "--container requires a name."
        container="$1"
        ;;
      --previous)
        previous="true"
        ;;
      --no-follow)
        follow="false"
        ;;
      --since)
        shift
        [[ $# -gt 0 ]] || die "--since requires a duration."
        since="$1"
        ;;
      --tail)
        shift
        [[ $# -gt 0 ]] || die "--tail requires a line count."
        tail_lines="$1"
        ;;
      -h|--help)
        logs_usage
        return 0
        ;;
      *)
        die "Unknown logs option: $1"
        ;;
    esac
    shift
  done

  local -a args
  args=(-n "$namespace" "$resource" "--since=$since" "--tail=$tail_lines")

  if [[ -n "$container" ]]; then
    args+=(--container "$container")
  else
    args+=(--all-containers=true)
  fi

  [[ "$previous" == "true" ]] && args+=(--previous)
  [[ "$follow" == "true" ]] && args+=(--follow)

  kubectl logs "${args[@]}"
}

cmd_describe() {
  require_cluster
  [[ $# -eq 2 ]] || die "Usage: kubezt describe <namespace> <resource>"
  kubectl describe -n "$1" "$2"
}

latest_pod() {
  local namespace="$1"
  local name_pattern="$2"

  kubectl get pods -n "$namespace" \
    --sort-by=.metadata.creationTimestamp \
    -o custom-columns='NAME:.metadata.name' \
    --no-headers |
    awk -v pattern="$name_pattern" '$1 ~ pattern { pod=$1 } END { print pod }'
}

first_running_pod_by_selector() {
  local namespace="$1"
  local selector="$2"

  kubectl get pods -n "$namespace" -l "$selector" \
    -o custom-columns='NAME:.metadata.name,PHASE:.status.phase' \
    --no-headers |
    awk '$2 == "Running" { print $1; exit }'
}

cmd_recovery() {
  local action="${1:-}"
  [[ "$action" == "logs" ]] || die "Usage: kubezt recovery logs"
  require_cluster

  local pod
  pod="$(latest_pod "$DEFAULT_NAMESPACE" '^recovery-')"
  [[ -n "$pod" ]] || die "No recovery pod was found in namespace '$DEFAULT_NAMESPACE'."

  info "Following recovery pod: $pod"
  kubectl logs -n "$DEFAULT_NAMESPACE" "$pod" --all-containers=true --since=1h --tail=200 --follow
}

cmd_storage() {
  local action="${1:-}"
  [[ "$action" == "status" ]] || die "Usage: kubezt storage status"
  require_cluster

  local pod
  pod="$(first_running_pod_by_selector "$CEPH_NAMESPACE" 'app=rook-ceph-tools')"
  [[ -n "$pod" ]] || die "No running Ceph tools pod was found in namespace '$CEPH_NAMESPACE'."

  info "Ceph cluster status:"
  kubectl exec -n "$CEPH_NAMESPACE" "$pod" -- ceph status
  info ""
  info "Ceph OSD status:"
  kubectl exec -n "$CEPH_NAMESPACE" "$pod" -- ceph osd status
}

cmd_backups() {
  local action="${1:-}"
  [[ "$action" == "status" ]] || die "Usage: kubezt backups status"
  require_cluster

  if kubectl get crd backups.velero.io >/dev/null 2>&1; then
    info "Velero backups:"
    kubectl get backups.velero.io -A
  else
    warn "Velero Backup resources are not installed."
  fi

  info ""
  info "Jobs with backup-related names:"
  local jobs
  jobs="$(kubectl get jobs -A --no-headers | awk 'tolower($2) ~ /(backup|velero)/')"
  if [[ -n "$jobs" ]]; then
    printf '%s\n' "$jobs"
  else
    info "No backup-related Jobs were found."
  fi
}

cmd_platform() {
  local action="${1:-}"

  case "$action" in
    status)
      cmd_status
      ;;
    stop)
      die "Platform stop is not configured. Add only the Government-approved service shutdown sequence."
      ;;
    start)
      die "Platform start is not configured. Add only the Government-approved service startup sequence."
      ;;
    *)
      die "Usage: kubezt platform <status|stop|start>"
      ;;
  esac
}

require_show_flag() {
  [[ "${1:-}" == "--show" ]] ||
    die "Credential output is protected. Re-run with --show after confirming the terminal is private."
  warn "The following output is an administrative credential. Do not record or share it."
}

cmd_access_token() {
  local service="${1:-}"
  local show_flag="${2:-}"
  require_show_flag "$show_flag"
  require_cluster

  case "$service" in
    clusterops)
      kubectl get secret headlamp-admin-user \
        --namespace kube-system \
        --output go-template='{{index .data "token" | base64decode}}{{"\n"}}'
      ;;
    kiali)
      kubectl -n istio-system create token kiali-service-account
      ;;
    openbao)
      kubectl get secret openbao-keys -n "$DEFAULT_NAMESPACE" \
        -o jsonpath='{.data.root_token}' | base64 --decode
      printf '\n'
      ;;
    *)
      die "Supported token services: clusterops, kiali, openbao"
      ;;
  esac
}

cmd_access_credentials() {
  local service="${1:-}"
  local show_flag="${2:-}"
  require_show_flag "$show_flag"
  require_cluster

  case "$service" in
    ziti)
      info "Username: admin"
      kubectl get secret ziti-controller-admin-secret -n "$DEFAULT_NAMESPACE" \
        --output go-template='{{index .data "admin-password" | base64decode}}{{"\n"}}'
      ;;
    ceph)
      info "Username: admin"
      kubectl get secret rook-ceph-dashboard-password -n "$CEPH_NAMESPACE" \
        -o jsonpath='{.data.password}' | base64 --decode
      printf '\n'
      ;;
    kibana)
      info "Username: elastic"
      kubectl get secret kubezt-es-elastic-user -n "$DEFAULT_NAMESPACE" \
        -o jsonpath='{.data.elastic}' | base64 --decode
      printf '\n'
      ;;
    openobserve)
      die "OpenObserve credential retrieval is not configured because the supplied admin tool referenced the Ziti Secret."
      ;;
    *)
      die "Supported credential services: ziti, ceph, kibana"
      ;;
  esac
}

cmd_access() {
  local kind="${1:-}"
  shift || true

  case "$kind" in
    token)
      cmd_access_token "$@"
      ;;
    credentials)
      cmd_access_credentials "$@"
      ;;
    -h|--help|help|"")
      access_usage
      ;;
    *)
      die "Usage: kubezt access <token|credentials> <service> --show"
      ;;
  esac
}

port_forward() {
  local namespace="$1"
  local resource="$2"
  local mapping="$3"

  info "Context: $(current_context)"
  info "Namespace: $namespace"
  info "Forwarding $resource on $mapping"
  info "Press Ctrl+C to stop."
  exec kubectl port-forward -n "$namespace" "$resource" "$mapping"
}

cmd_proxy() {
  require_cluster

  local service="${1:-}"
  shift || true

  local namespace pod name
  case "$service" in
    openbao)
      port_forward "$DEFAULT_NAMESPACE" service/openbao 8200:8200
      ;;
    mongo)
      port_forward "$DEFAULT_NAMESPACE" service/kubezt-mongodb-psmdb-mongos 27018:27017
      ;;
    ipa)
      namespace="${1:-$DEFAULT_NAMESPACE}"
      port_forward "$namespace" service/ipa 8443:443
      ;;
    ldaps)
      namespace="${1:-$DEFAULT_NAMESPACE}"
      port_forward "$namespace" service/ipa 1636:636
      ;;
    ldap)
      namespace="${1:-$DEFAULT_NAMESPACE}"
      port_forward "$namespace" service/ipa 1389:389
      ;;
    kerberos)
      namespace="${1:-$DEFAULT_NAMESPACE}"
      port_forward "$namespace" service/ipa 1088:88
      ;;
    redis)
      port_forward "$DEFAULT_NAMESPACE" service/redis-master 6380:6379
      ;;
    ceph)
      port_forward "$CEPH_NAMESPACE" service/rook-ceph-mgr-dashboard 7000:7000
      ;;
    envoy)
      pod="$(first_running_pod_by_selector projectcontour 'app=envoy')"
      [[ -n "$pod" ]] || die "No running Envoy pod was found."
      port_forward projectcontour "pod/$pod" 9001:9001
      ;;
    pgo)
      port_forward pgo service/postgres-operator 8443:8443
      ;;
    fs)
      name="${1:-}"
      namespace="${2:-$DEFAULT_NAMESPACE}"
      [[ -n "$name" ]] || die "Usage: kubezt proxy fs <name> [namespace]"
      port_forward "$namespace" "service/fs-$name" 8088:8080
      ;;
    nfs)
      name="${1:-}"
      namespace="${2:-$DEFAULT_NAMESPACE}"
      [[ -n "$name" ]] || die "Usage: kubezt proxy nfs <service> [namespace]"
      port_forward "$namespace" "service/$name" 5555:5555
      ;;
    postgres)
      namespace="${1:-$DEFAULT_NAMESPACE}"
      port_forward "$namespace" service/kubezt-postgres-primary 5432:5432
      ;;
    kiali)
      port_forward istio-system service/kiali 20001:20001
      ;;
    kibana)
      port_forward "$DEFAULT_NAMESPACE" service/quickstart-kb-http 5601:5601
      ;;
    grafana)
      port_forward monitoring service/kubezt-prom-grafana 3000:80
      ;;
    yunikorn)
      port_forward yunikorn service/yunikorn-service 9889:9889
      ;;
    yunikorn-api)
      port_forward yunikorn service/yunikorn-service 9080:9080
      ;;
    gitea)
      namespace="${1:-$DEFAULT_NAMESPACE}"
      port_forward "$namespace" service/gitea 3333:3000
      ;;
    openobserve)
      port_forward "$DEFAULT_NAMESPACE" service/openobserve-querier 5080:5080
      ;;
    argo-builds)
      port_forward argo-events service/builds-eventsource-svc 10000:10000
      ;;
    argo-events)
      port_forward argo deployment/argo-server 2746:2746
      ;;
    argo-cd)
      port_forward "$ARGOCD_NAMESPACE" service/argocd-server 8081:80
      ;;
    ziti)
      info "Ziti console: https://localhost:1281/zac/"
      port_forward "$DEFAULT_NAMESPACE" service/ziti-controller-mgmt 1281:1281
      ;;
    -h|--help|help|"")
      proxy_usage
      ;;
    *)
      die "Unknown proxy service: $service. Run 'kubezt help proxy'."
      ;;
  esac
}

legacy_api_logs() {
  require_cluster

  local position="${1:-1}"
  [[ "$position" =~ ^[0-9]+$ ]] || die "API pod position must be a positive number."
  (( position > 0 )) || die "API pod position must be greater than zero."

  local pod
  pod="$(
    kubectl get pods -n "$DEFAULT_NAMESPACE" \
      -o custom-columns='NAME:.metadata.name' --no-headers |
      awk '/^kubezt-api-/ { print }' |
      sed -n "${position}p"
  )"
  [[ -n "$pod" ]] || die "No KubeZT API pod was found at position $position."

  warn "'kubezt api logs <number>' is retained for compatibility. Prefer 'kubezt logs'."
  kubectl logs -n "$DEFAULT_NAMESPACE" "$pod" --all-containers=true --since=1h --tail=200 --follow
}

legacy_cert_manager_logs() {
  require_cluster

  local pod
  pod="$(first_running_pod_by_selector cert-manager 'app=cert-manager')"
  [[ -n "$pod" ]] || die "No running cert-manager pod was found."
  kubectl logs -n cert-manager "$pod" --all-containers=true --since=1h --tail=200 --follow
}

cmd_help() {
  local command="${1:-}"
  case "$command" in
    logs)
      logs_usage
      ;;
    proxy)
      proxy_usage
      ;;
    access)
      access_usage
      ;;
    "")
      usage
      ;;
    *)
      usage
      ;;
  esac
}

main() {
  local command="${1:-}"
  if [[ $# -gt 0 ]]; then
    shift
  fi

  case "$command" in
    context)
      cmd_context "$@"
      ;;
    status)
      cmd_status "$@"
      ;;
    nodes)
      cmd_nodes "$@"
      ;;
    apps)
      cmd_apps "$@"
      ;;
    workloads)
      cmd_workloads "$@"
      ;;
    pods)
      cmd_pods "$@"
      ;;
    pvc)
      cmd_pvc "$@"
      ;;
    events)
      cmd_events "$@"
      ;;
    warnings)
      cmd_warnings "$@"
      ;;
    top)
      cmd_top "$@"
      ;;
    logs)
      cmd_logs "$@"
      ;;
    describe)
      cmd_describe "$@"
      ;;
    recovery)
      cmd_recovery "$@"
      ;;
    storage)
      cmd_storage "$@"
      ;;
    backups)
      cmd_backups "$@"
      ;;
    platform)
      cmd_platform "$@"
      ;;
    access)
      cmd_access "$@"
      ;;
    proxy)
      cmd_proxy "$@"
      ;;

    # Compatibility with the original tool.
    api)
      [[ "${1:-}" == "logs" ]] || die "Usage: kubezt api logs [pod number]"
      shift
      legacy_api_logs "$@"
      ;;
    cert-manager)
      [[ "${1:-}" == "logs" ]] || die "Usage: kubezt cert-manager logs"
      legacy_cert_manager_logs
      ;;
    ceph)
      [[ "${1:-}" == "status" ]] || die "Usage: kubezt ceph status"
      cmd_storage status
      ;;
    clusterops)
      [[ "${1:-}" == "token" ]] || die "Usage: kubezt clusterops token"
      warn "Legacy command. Prefer 'kubezt access token clusterops --show'."
      cmd_access_token clusterops --show
      ;;
    kiali)
      [[ "${1:-}" == "token" ]] || die "Usage: kubezt kiali token"
      warn "Legacy command. Prefer 'kubezt access token kiali --show'."
      cmd_access_token kiali --show
      ;;
    openbao)
      [[ "${1:-}" == "token" ]] || die "Usage: kubezt openbao token"
      warn "Legacy command. Prefer 'kubezt access token openbao --show'."
      cmd_access_token openbao --show
      ;;
    ziti)
      [[ "${1:-}" == "token" ]] || die "Usage: kubezt ziti token"
      warn "Legacy command. Prefer 'kubezt access credentials ziti --show'."
      cmd_access_credentials ziti --show
      ;;
    build|deploy)
      die "'$command' is an engineering/release action and is intentionally excluded from the administrator helper."
      ;;
    help|-h|--help|"")
      cmd_help "$@"
      ;;
    version|-V|--version)
      info "kubezt administrator tool $KUBEZT_CLI_VERSION"
      ;;
    *)
      die "Unknown command: $command. Run 'kubezt help'."
      ;;
  esac
}

main "$@"
