#!/usr/bin/env bash
# Interactive EKS managed nodegroup clone using only the AWS CLI (no Python, no jq).
# Usage: ./clone.sh [--region REGION] [--profile PROFILE] [--dry-run]
set -euo pipefail

DRY_RUN=false
AWS=(aws)
while [ $# -gt 0 ]; do
  case "$1" in
    --region)  AWS+=(--region "$2"); shift 2 ;;
    --profile) AWS+=(--profile "$2"); shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    -h|--help) sed -n '2,3p' "$0"; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

AMI_TYPES="AL2023_x86_64_STANDARD AL2023_ARM_64_STANDARD AL2023_x86_64_NVIDIA AL2023_ARM_64_NVIDIA
AL2_x86_64 AL2_x86_64_GPU AL2_ARM_64 BOTTLEROCKET_x86_64 BOTTLEROCKET_ARM_64"
CHANGES=""

# ---------- prompt helpers ----------
yes_no() {  # yes_no "question" -> returns 0 for yes
  local a
  while true; do
    read -r -p "$1 (y/N): " a
    case "$a" in
      [yY]|[yY][eE][sS]) return 0 ;;
      ""|[nN]|[nN][oO])  return 1 ;;
    esac
    echo "  Please answer y or n." >&2
  done
}

ask() {  # ask "prompt" "default" -> prints answer (Enter keeps default)
  local a
  read -r -p "  $1${2:+ [$2]}: " a
  echo "${a:-${2:-}}"
}

pick() {  # pick "title" option1 option2 ... -> prints chosen option
  local title=$1 c i=1 o
  shift
  if [ $# -eq 0 ]; then echo "No $title found." >&2; exit 1; fi
  echo "$title:" >&2
  for o in "$@"; do echo "  $i) $o" >&2; i=$((i + 1)); done
  while true; do
    read -r -p "  Choice: " c
    if [[ "$c" =~ ^[0-9]+$ ]] && [ "$c" -ge 1 ] && [ "$c" -le $# ]; then
      echo "${!c}"
      return 0
    fi
    echo "  Enter 1-$#." >&2
  done
}

changed() {  # record a change only if the value actually differs
  if [ "$2" != "$3" ]; then CHANGES="${CHANGES}  $1: $2 -> $3\n"; fi
}

# ---------- validators ----------
ami_arch() { case "$1" in *ARM_64*) echo arm64 ;; *) echo x86_64 ;; esac; }

ver_gt() {  # ver_gt 1.32 1.31 -> true if $1 > $2
  local a1=${1%%.*} a2=${1#*.} b1=${2%%.*} b2=${2#*.}
  [ "$a1" -gt "$b1" ] || { [ "$a1" -eq "$b1" ] && [ "$a2" -gt "$b2" ]; }
}

bad_types() {  # bad_types "t3.large,m5.large" arch -> prints types not supporting arch; fails if invalid
  local types
  read -r -a types <<< "$(echo "$1" | tr ',' ' ')"
  "${AWS[@]}" ec2 describe-instance-types --instance-types "${types[@]}" \
    --query "InstanceTypes[?!contains(ProcessorInfo.SupportedArchitectures, '$2')].InstanceType" \
    --output text
}

valid_kv() {  # key=value,key2=value2
  local item items
  IFS=',' read -r -a items <<< "$1"
  for item in "${items[@]}"; do
    if [[ "$item" != ?*=* ]]; then return 1; fi
  done
  return 0
}

taints_json() {  # "k=v:NoSchedule,k2:NoExecute" -> JSON list
  local out="" item kv key value effect items
  IFS=',' read -r -a items <<< "$1"
  for item in "${items[@]}"; do
    if [[ "$item" != *:* ]]; then return 1; fi
    effect=${item##*:}; kv=${item%:*}; key=${kv%%=*}; value=""
    if [[ "$kv" == *=* ]]; then value=${kv#*=}; fi
    case "$effect" in
      NoSchedule|NO_SCHEDULE) effect=NO_SCHEDULE ;;
      NoExecute|NO_EXECUTE) effect=NO_EXECUTE ;;
      PreferNoSchedule|PREFER_NO_SCHEDULE) effect=PREFER_NO_SCHEDULE ;;
      *) return 1 ;;
    esac
    if [ -z "$key" ]; then return 1; fi
    if [ -n "$value" ]; then
      out+="${out:+,}{\"key\":\"$key\",\"value\":\"$value\",\"effect\":\"$effect\"}"
    else
      out+="${out:+,}{\"key\":\"$key\",\"effect\":\"$effect\"}"
    fi
  done
  echo "[$out]"
}

# ---------- select cluster / source / target ----------
CLUSTER=$(pick "Cluster" $("${AWS[@]}" eks list-clusters --query 'clusters[]' --output text))
SOURCE=$(pick "Source nodegroup" $("${AWS[@]}" eks list-nodegroups --cluster-name "$CLUSTER" \
  --query 'nodegroups[]' --output text))
CLUSTER_VERSION=$("${AWS[@]}" eks describe-cluster --name "$CLUSTER" --query cluster.version --output text)

while true; do
  TARGET=$(ask "New nodegroup name" "${SOURCE}-clone")
  if ! [[ "$TARGET" =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,62}$ ]]; then
    echo "  Invalid: 1-63 chars, letters, digits, - or _" >&2; continue
  fi
  if "${AWS[@]}" eks describe-nodegroup --cluster-name "$CLUSTER" --nodegroup-name "$TARGET" \
      >/dev/null 2>&1; then
    echo "  Invalid: nodegroup '$TARGET' already exists" >&2; continue
  fi
  break
done

# ---------- read source config ----------
ngq() {  # ngq <jmespath under nodegroup> [text|json]
  "${AWS[@]}" eks describe-nodegroup --cluster-name "$CLUSTER" --nodegroup-name "$SOURCE" \
    --query "nodegroup.$1" --output "${2:-text}"
}
ngj() { ngq "$1" json | sed 's/^ *//' | tr -d '\n'; }  # compact JSON

IFS=$'\t' read -r ROLE AMI_TYPE VERSION RELEASE CAPACITY DISK LT_ID LT_VERSION <<< \
  "$(ngq '[nodeRole,amiType,version,releaseVersion,capacityType,diskSize,launchTemplate.id,launchTemplate.version]')"
read -r MIN MAX DESIRED <<< \
  "$(ngq '[scalingConfig.minSize,scalingConfig.maxSize,scalingConfig.desiredSize]')"
SUBNETS=$(ngq subnets | tr '\t' ',')
INSTANCE_TYPES=$(ngq instanceTypes | tr '\t' ',')
LABELS=$(ngj labels); TAINTS=$(ngj taints); TAGS=$(ngj tags)
UPDATE=$(ngj updateConfig); REPAIR=$(ngj nodeRepairConfig); REMOTE=$(ngj remoteAccess)

CUSTOM_AMI=false
LT_TYPE=None
lt_info() {
  local ami
  read -r ami LT_TYPE <<< "$("${AWS[@]}" ec2 describe-launch-template-versions \
    --launch-template-id "$LT_ID" --versions "$LT_VERSION" \
    --query 'LaunchTemplateVersions[0].LaunchTemplateData.[ImageId,InstanceType]' --output text)"
  if [ "$ami" != "None" ]; then CUSTOM_AMI=true; else CUSTOM_AMI=false; fi
}

# ---------- questions ----------
echo
echo "=== Choose what to change (Enter = No) ==="

if [ "$LT_ID" != "None" ]; then
  lt_info
  LT_LATEST=$("${AWS[@]}" ec2 describe-launch-templates --launch-template-ids "$LT_ID" \
    --query 'LaunchTemplates[0].LatestVersionNumber' --output text)
  if yes_no "Change launch template version? (current: $LT_VERSION, latest: $LT_LATEST)"; then
    while true; do
      new=$(ask "New version" "$LT_LATEST")
      if [[ "$new" =~ ^[0-9]+$ ]] && [ "$new" -ge 1 ] && [ "$new" -le "$LT_LATEST" ]; then break; fi
      echo "  Invalid: enter 1-$LT_LATEST" >&2
    done
    changed launchTemplateVersion "$LT_VERSION" "$new"; LT_VERSION=$new
    lt_info
  fi
fi

if $CUSTOM_AMI; then
  echo "Launch template uses a custom AMI: Kubernetes/AMI version come from the template."
else
  if yes_no "Change Kubernetes version? (current: $VERSION, cluster: $CLUSTER_VERSION)"; then
    while true; do
      new=$(ask "New version" "$CLUSTER_VERSION")
      if ! [[ "$new" =~ ^[0-9]+\.[0-9]+$ ]]; then echo "  Invalid: format like 1.31" >&2; continue; fi
      if ver_gt "$new" "$CLUSTER_VERSION"; then
        echo "  Invalid: cannot be newer than cluster ($CLUSTER_VERSION)" >&2; continue
      fi
      break
    done
    if [ "$new" != "$VERSION" ]; then
      changed version "$VERSION" "$new"; VERSION=$new; RELEASE=None  # old release won't match
    fi
  fi
  if yes_no "Change AMI release version? (current: ${RELEASE/None/latest})"; then
    new=$(ask "New release version (e.g. 1.31.3-20250115) or 'latest'" "latest")
    [ "$new" = "latest" ] && new=None
    changed releaseVersion "$RELEASE" "$new"; RELEASE=$new
  fi
  if yes_no "Change AMI type? (current: $AMI_TYPE)"; then
    new=$(pick "AMI type" $AMI_TYPES)
    changed amiType "$AMI_TYPE" "$new"; AMI_TYPE=$new; RELEASE=None  # releases are AMI-type specific
  fi
fi

if [ "$LT_TYPE" != "None" ]; then
  echo "Instance type is set in the launch template ($LT_TYPE)."
else
  current=${INSTANCE_TYPES/None/t3.medium}
  arch=""; $CUSTOM_AMI || arch=$(ami_arch "$AMI_TYPE")
  must=false
  if [ -n "$arch" ]; then
    if ! bad=$(bad_types "$current" "$arch" 2>/dev/null) || [ -n "$bad" ]; then
      echo "Current instance types ($current) do not support $arch. You must choose new ones."
      must=true
    fi
  fi
  if $must || yes_no "Change instance types? (current: $current)"; then
    while true; do
      new=$(ask "Instance types (comma-separated)" "$current")
      if ! bad=$(bad_types "$new" "${arch:-x86_64}" 2>/dev/null); then
        echo "  Invalid: unknown instance type in '$new'" >&2; continue
      fi
      if [ -n "$arch" ] && [ -n "$bad" ]; then
        echo "  Invalid: $bad do not support $arch (needed by AMI type)" >&2; continue
      fi
      break
    done
    changed instanceTypes "$current" "$new"; INSTANCE_TYPES=$new
  fi
fi

if yes_no "Change capacity type? (current: $CAPACITY)"; then
  new=$(pick "Capacity type" ON_DEMAND SPOT)
  changed capacityType "$CAPACITY" "$new"; CAPACITY=$new
fi

if [ "$LT_ID" = "None" ] && yes_no "Change disk size? (current: ${DISK/None/20} GiB)"; then
  while true; do
    new=$(ask "Disk size in GiB" "${DISK/None/20}")
    if [[ "$new" =~ ^[0-9]+$ ]] && [ "$new" -ge 1 ]; then break; fi
    echo "  Invalid: must be a positive number" >&2
  done
  changed diskSize "$DISK" "$new"; DISK=$new
fi

if yes_no "Change scaling? (current: min=$MIN, max=$MAX, desired=$DESIRED)"; then
  while true; do
    mn=$(ask "minSize" "$MIN"); mx=$(ask "maxSize" "$MAX"); ds=$(ask "desiredSize" "$DESIRED")
    if [[ "$mn$mx$ds" =~ ^[0-9]+$ ]] && [ "$mn" -le "$ds" ] && [ "$ds" -le "$mx" ] && [ "$mx" -ge 1 ]; then
      break
    fi
    echo "  Need whole numbers with min <= desired <= max, and max >= 1." >&2
  done
  changed scaling "$MIN/$MAX/$DESIRED" "$mn/$mx/$ds"; MIN=$mn; MAX=$mx; DESIRED=$ds
fi

if yes_no "Change subnets? (current: $SUBNETS)"; then
  new=$(ask "Subnet IDs (comma-separated)" "$SUBNETS")
  changed subnets "$SUBNETS" "$new"; SUBNETS=$new
fi

if yes_no "Change node IAM role? (current: $ROLE)"; then
  new=$(ask "Node role ARN" "$ROLE")
  changed nodeRole "$ROLE" "$new"; ROLE=$new
fi

if yes_no "Change labels? (current: $LABELS)"; then
  while true; do
    new=$(ask "New labels key=value,key2=value2 (replaces all; 'none' to remove)" "")
    if [ "$new" = "none" ] || valid_kv "$new"; then break; fi
    echo "  Invalid: use key=value,key2=value2" >&2
  done
  changed labels "$LABELS" "$new"; LABELS=$new
fi

if yes_no "Change tags? (current: $TAGS)"; then
  while true; do
    new=$(ask "New tags key=value,key2=value2 (replaces all; 'none' to remove)" "")
    if [ "$new" = "none" ] || valid_kv "$new"; then break; fi
    echo "  Invalid: use key=value,key2=value2" >&2
  done
  changed tags "$TAGS" "$new"; TAGS=$new
fi

if yes_no "Change taints? (current: $TAINTS)"; then
  while true; do
    new=$(ask "New taints key=value:NoSchedule|NoExecute|PreferNoSchedule, comma-separated (replaces all; 'none' to remove)" "")
    if [ "$new" = "none" ]; then break; fi
    if new=$(taints_json "$new"); then break; fi
    echo "  Invalid: use key=value:Effect,key2:Effect" >&2
  done
  changed taints "$TAINTS" "$new"; TAINTS=$new
fi

# ---------- build create-nodegroup command ----------
ARGS=(eks create-nodegroup --cluster-name "$CLUSTER" --nodegroup-name "$TARGET"
      --node-role "$ROLE" --scaling-config "minSize=$MIN,maxSize=$MAX,desiredSize=$DESIRED")
read -r -a subnet_list <<< "$(echo "$SUBNETS" | tr ',' ' ')"
ARGS+=(--subnets "${subnet_list[@]}")

if [ "$CAPACITY" != "None" ]; then ARGS+=(--capacity-type "$CAPACITY"); fi
if [ "$LT_ID" != "None" ]; then
  ARGS+=(--launch-template "id=$LT_ID,version=$LT_VERSION")
else
  if [ "$DISK" != "None" ]; then ARGS+=(--disk-size "$DISK"); fi
  if [ "$REMOTE" != "null" ]; then ARGS+=(--remote-access "$REMOTE"); fi
fi
if ! $CUSTOM_AMI; then
  if [ "$AMI_TYPE" != "None" ] && [ "$AMI_TYPE" != "CUSTOM" ]; then ARGS+=(--ami-type "$AMI_TYPE"); fi
  if [ "$VERSION" != "None" ]; then ARGS+=(--kubernetes-version "$VERSION"); fi
  if [ "$RELEASE" != "None" ]; then ARGS+=(--release-version "$RELEASE"); fi
fi
if [ "$LT_TYPE" = "None" ] && [ "$INSTANCE_TYPES" != "None" ]; then
  read -r -a type_list <<< "$(echo "$INSTANCE_TYPES" | tr ',' ' ')"
  ARGS+=(--instance-types "${type_list[@]}")
fi
for pair in "--labels:$LABELS" "--tags:$TAGS" "--taints:$TAINTS" "--update-config:$UPDATE"; do
  flag=${pair%%:*}; value=${pair#*:}
  case "$value" in null|none|"{}"|"[]"|"") ;; *) ARGS+=("$flag" "$value") ;; esac
done
if [[ "$REPAIR" == *'"enabled": true'* ]]; then ARGS+=(--node-repair-config "$REPAIR"); fi

echo
echo "=== Changes vs source ==="
if [ -n "$CHANGES" ]; then printf '%b' "$CHANGES"; else echo "  none (exact clone)"; fi
echo
echo "=== Command ==="
printf 'aws'
for a in "${AWS[@]:1}" "${ARGS[@]}"; do  # quote only arguments that need it
  if [[ "$a" =~ ^[A-Za-z0-9_./:=,@-]+$ ]]; then printf ' %s' "$a"; else printf " '%s'" "$a"; fi
done
echo

if $DRY_RUN; then echo "Dry run: not created."; exit 0; fi
if ! yes_no $'\n'"Create nodegroup '$TARGET' now?"; then echo "Not created."; exit 0; fi

"${AWS[@]}" "${ARGS[@]}" --query 'nodegroup.status' --output text
echo "Creating '$TARGET'..."
if yes_no "Wait until it is ACTIVE?"; then
  "${AWS[@]}" eks wait nodegroup-active --cluster-name "$CLUSTER" --nodegroup-name "$TARGET"
  echo "'$TARGET' is ACTIVE."
fi
echo
echo "Next: kubectl cordon/drain -l eks.amazonaws.com/nodegroup=$SOURCE" \
     "--ignore-daemonsets --delete-emptydir-data, then delete '$SOURCE'."
