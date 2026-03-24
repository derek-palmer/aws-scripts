#!/usr/bin/env bash

set -euo pipefail

AWS_REGION="${AWS_REGION:-us-east-1}"
ECS_CLUSTER_NAME="${ECS_CLUSTER_NAME:-pidash-prod}"
EXPECTED_AWS_ACCOUNT_ID="${EXPECTED_AWS_ACCOUNT_ID:-}"
SKIP_REPO_SCAN=false
SKIP_CUSTOMER_MANAGED_POLICIES=false
SKIP_INLINE_ROLE_POLICIES=false

declare -a ECS_SERVICES=()

readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_SCAN_TARGETS=(
  "terraform"
  "services"
  "jobs"
  "lambdas"
  "etl"
  "buildspec"
  "operations-manual"
  "README.md"
)

actual_aws_account_id=""
repo_scan_output=""
repo_short_hits=""
service_short_hits=""
service_unexpected_hits=""
customer_policy_hits=""
inline_policy_hits=""

log() {
  printf '%s\n' "$*"
}

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage:
  ./scripts/audit-ecs-short-arns.sh [options] [service-name ...]

Options:
  --cluster <name>                     ECS cluster name to audit
  --region <name>                      AWS region to query
  --account-id <id>                    Expected AWS account ID
  --service <name>                     ECS service name to audit; repeat as needed
  --skip-repo-scan                     Skip the repo scan
  --skip-customer-managed-policies     Skip the customer-managed IAM policy scan
  --skip-inline-role-policies          Skip the inline IAM role policy scan
  -h, --help                           Show this help text

Examples:
  ./scripts/audit-ecs-short-arns.sh
  ./scripts/audit-ecs-short-arns.sh --cluster my-ecs-cluster
  ./scripts/audit-ecs-short-arns.sh --cluster my-ecs-cluster --service my-api-service --service my-worker-service
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --cluster)
        [[ $# -ge 2 ]] || fail "Missing value for --cluster"
        ECS_CLUSTER_NAME="$2"
        shift 2
        ;;
      --region)
        [[ $# -ge 2 ]] || fail "Missing value for --region"
        AWS_REGION="$2"
        shift 2
        ;;
      --account-id)
        [[ $# -ge 2 ]] || fail "Missing value for --account-id"
        EXPECTED_AWS_ACCOUNT_ID="$2"
        shift 2
        ;;
      --service)
        [[ $# -ge 2 ]] || fail "Missing value for --service"
        ECS_SERVICES+=("$2")
        shift 2
        ;;
      --skip-repo-scan)
        SKIP_REPO_SCAN=true
        shift
        ;;
      --skip-customer-managed-policies)
        SKIP_CUSTOMER_MANAGED_POLICIES=true
        shift
        ;;
      --skip-inline-role-policies)
        SKIP_INLINE_ROLE_POLICIES=true
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      --)
        shift
        while [[ $# -gt 0 ]]; do
          ECS_SERVICES+=("$1")
          shift
        done
        ;;
      -*)
        fail "Unknown option: $1"
        ;;
      *)
        ECS_SERVICES+=("$1")
        shift
        ;;
    esac
  done
}

require_command() {
  local command_name="$1"

  if ! command -v "$command_name" >/dev/null 2>&1; then
    fail "Required command not found: $command_name"
  fi
}

count_words() {
  printf '%s\n' "$1" | wc -w | tr -d ' '
}

maybe_log_progress() {
  local label="$1"
  local current="$2"
  local total="$3"

  if (( current == 1 || current == total || current % 25 == 0 )); then
    log "${label}: ${current}/${total}"
  fi
}

run_repo_scan() {
  log "== Repo scan: ECS service ARN references =="

  repo_scan_output="$(
    cd "$REPO_ROOT" &&
      rg -o --no-filename --hidden --glob '!**/.git/**' \
        'arn:aws:ecs:[^"[:space:]]*:service/[^"[:space:]]+' \
        "${REPO_SCAN_TARGETS[@]}" | sort -u || true
  )"

  if [[ -n "$repo_scan_output" ]]; then
    printf '%s\n' "$repo_scan_output"
  else
    log "No ECS service ARN references found in repo scan targets."
  fi

  repo_short_hits="$(
    printf '%s\n' "$repo_scan_output" |
      awk -F'service/' '{print $2}' |
      awk -F/ 'NF==1' || true
  )"

  if [[ -n "$repo_short_hits" ]]; then
    log
    log "Short-form ECS service ARN hits found in repo:"
    printf '%s\n' "$repo_short_hits"
    fail "Repo contains short-form ECS service ARN references."
  fi

  log "Repo scan result: no short-form ECS service ARN references found."
}

verify_aws_session() {
  log
  log "== AWS session =="

  local caller_identity
  caller_identity="$(aws sts get-caller-identity --output json)"
  printf '%s\n' "$caller_identity"

  actual_aws_account_id="$(awk -F'"' '/"Account"/{print $4}' <<< "$caller_identity")"

  if [[ -n "$EXPECTED_AWS_ACCOUNT_ID" && "$actual_aws_account_id" != "$EXPECTED_AWS_ACCOUNT_ID" ]]; then
    fail "AWS session account mismatch. Expected $EXPECTED_AWS_ACCOUNT_ID, got $actual_aws_account_id."
  fi

  log "AWS session result: authenticated to account $actual_aws_account_id."
}

discover_cluster_services() {
  if [[ ${#ECS_SERVICES[@]} -gt 0 ]]; then
    log
    log "== ECS service discovery =="
    log "Using explicitly provided services: ${ECS_SERVICES[*]}"
    return
  fi

  log
  log "== ECS service discovery =="

  local service_arn

  while IFS= read -r service_arn; do
    [[ -z "$service_arn" ]] && continue
    ECS_SERVICES+=("${service_arn##*/}")
  done < <(
    aws ecs list-services \
      --region "$AWS_REGION" \
      --cluster "$ECS_CLUSTER_NAME" \
      --query 'serviceArns[]' \
      --output text |
      tr '\t' '\n'
  )

  if [[ ${#ECS_SERVICES[@]} -eq 0 ]]; then
    fail "No ECS services found in cluster $ECS_CLUSTER_NAME."
  fi

  log "Discovered ${#ECS_SERVICES[@]} services in cluster $ECS_CLUSTER_NAME: ${ECS_SERVICES[*]}"
}

verify_cluster_service_arns() {
  log
  log "== ECS service ARN shape =="

  # describe-services accepts at most 10 services per call; batch accordingly.
  local expected_prefix="arn:aws:ecs:${AWS_REGION}:${actual_aws_account_id}:service/${ECS_CLUSTER_NAME}/"
  local batch_size=10
  local i batch batch_arns service_arn

  service_short_hits=""
  service_unexpected_hits=""

  for (( i = 0; i < ${#ECS_SERVICES[@]}; i += batch_size )); do
    batch=("${ECS_SERVICES[@]:$i:$batch_size}")

    aws ecs describe-services \
      --region "$AWS_REGION" \
      --cluster "$ECS_CLUSTER_NAME" \
      --services "${batch[@]}" \
      --query 'services[].{arn:serviceArn,desired:desiredCount,name:serviceName}' \
      --output table

    batch_arns="$(
      aws ecs describe-services \
        --region "$AWS_REGION" \
        --cluster "$ECS_CLUSTER_NAME" \
        --services "${batch[@]}" \
        --query 'services[].serviceArn' \
        --output text
    )"

    for service_arn in $batch_arns; do
      [[ -z "$service_arn" ]] && continue

      if [[ "$service_arn" == "${expected_prefix}"* ]]; then
        continue
      fi

      if [[ "$service_arn" =~ ^arn:aws:ecs:${AWS_REGION}:${actual_aws_account_id}:service/[^/[:space:]]+$ ]]; then
        service_short_hits+="${service_arn}"$'\n'
        continue
      fi

      service_unexpected_hits+="${service_arn}"$'\n'
    done
  done

  if [[ -n "$service_unexpected_hits" ]]; then
    log "ECS service result: unexpected ARN formats found."
    printf '%s' "$service_unexpected_hits"
    fail "Encountered ECS service ARNs that are neither short-form nor long-form."
  fi

  if [[ -n "$service_short_hits" ]]; then
    log "ECS service result: these services are still using short-form ARNs:"
    printf '%s' "$service_short_hits"
    log "This means the services have not been migrated yet. Continue with policy scans to check for hard-coded short ARN dependencies."
    return
  fi

  log "ECS service result: all audited services use long-form ARNs."
}

scan_customer_managed_policies() {
  log
  log "== IAM customer-managed policy scan =="

  local policy_arns
  local policy_arn
  local version_id
  local ecs_matches
  local ecs_arn
  local total_policies
  local index=0

  customer_policy_hits=""
  policy_arns="$(aws iam list-policies --scope Local --query 'Policies[].Arn' --output text)"
  total_policies="$(count_words "$policy_arns")"

  log "Scanning ${total_policies} customer-managed policies..."

  for policy_arn in $policy_arns; do
    [[ -z "$policy_arn" ]] && continue

    index=$((index + 1))
    maybe_log_progress "Customer-managed policies" "$index" "$total_policies"

    version_id="$(aws iam get-policy --policy-arn "$policy_arn" --query 'Policy.DefaultVersionId' --output text)"
    ecs_matches="$(
      aws iam get-policy-version \
        --policy-arn "$policy_arn" \
        --version-id "$version_id" \
        --query 'PolicyVersion.Document' \
        --output json |
        grep -o 'arn:aws:ecs:[^"[:space:]]*:service/[^"[:space:]]*' || true
    )"

    [[ -z "$ecs_matches" ]] && continue

    while read -r ecs_arn; do
      [[ -z "$ecs_arn" ]] && continue

      case "$ecs_arn" in
        arn:aws:ecs:*:service/*/*) ;;
        *) customer_policy_hits+="${policy_arn} -> ${ecs_arn}"$'\n' ;;
      esac
    done <<< "$ecs_matches"
  done

  if [[ -n "$customer_policy_hits" ]]; then
    printf '%s' "$customer_policy_hits"
    fail "Customer-managed IAM policies contain short ECS service ARNs."
  fi

  log "Customer-managed IAM result: no short ECS service ARNs found."
}

scan_inline_role_policies() {
  log
  log "== IAM inline role policy scan =="

  local role_names
  local role_name
  local policy_names
  local policy_name
  local ecs_matches
  local ecs_arn
  local total_roles
  local index=0

  inline_policy_hits=""
  role_names="$(aws iam list-roles --query 'Roles[].RoleName' --output text)"
  total_roles="$(count_words "$role_names")"

  log "Scanning inline policies across ${total_roles} roles..."

  for role_name in $role_names; do
    [[ -z "$role_name" ]] && continue

    index=$((index + 1))
    maybe_log_progress "Roles scanned for inline policies" "$index" "$total_roles"

    policy_names="$(aws iam list-role-policies --role-name "$role_name" --query 'PolicyNames[]' --output text 2>/dev/null || true)"

    for policy_name in $policy_names; do
      [[ -z "$policy_name" ]] && continue

      ecs_matches="$(
        aws iam get-role-policy \
          --role-name "$role_name" \
          --policy-name "$policy_name" \
          --query 'PolicyDocument' \
          --output json |
          grep -o 'arn:aws:ecs:[^"[:space:]]*:service/[^"[:space:]]*' || true
      )"

      [[ -z "$ecs_matches" ]] && continue

      while read -r ecs_arn; do
        [[ -z "$ecs_arn" ]] && continue

        case "$ecs_arn" in
          arn:aws:ecs:*:service/*/*) ;;
          *) inline_policy_hits+="${role_name} / ${policy_name} -> ${ecs_arn}"$'\n' ;;
        esac
      done <<< "$ecs_matches"
    done
  done

  if [[ -n "$inline_policy_hits" ]]; then
    printf '%s' "$inline_policy_hits"
    fail "Inline IAM role policies contain short ECS service ARNs."
  fi

  log "Inline IAM result: no short ECS service ARNs found."
}

main() {
  parse_args "$@"

  require_command aws
  require_command awk
  require_command grep

  if [[ "$SKIP_REPO_SCAN" == false ]]; then
    require_command rg
    run_repo_scan
  fi

  verify_aws_session
  discover_cluster_services
  verify_cluster_service_arns

  if [[ "$SKIP_CUSTOMER_MANAGED_POLICIES" == false ]]; then
    scan_customer_managed_policies
  fi

  if [[ "$SKIP_INLINE_ROLE_POLICIES" == false ]]; then
    scan_inline_role_policies
  fi

  log
  if [[ -n "$service_short_hits" ]]; then
    log "Audit result: audited services are still on short ARNs, but the repo and scanned IAM policies show no hard-coded short ECS service ARN dependencies."
    log "Migration is still pending for the services themselves, but this audit did not find version-controlled or scanned IAM blockers."
    return
  fi

  log "Audit passed: repo and audited AWS resources show no short ECS service ARN usage."
}

main "$@"
