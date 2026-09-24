#!/usr/bin/env bash

main() (
  # Download cluster artifacts. Run with bash; do not use sudo.
  # Usage: curl -fsSL https://bind.kubezt.com | bash -s -- CLUSTER
  set +x
  set -euo pipefail
  umask 077

  if [ "$#" -ne 1 ]; then
    echo "Usage: bash bind.sh CLUSTER" >&2
    exit 1
  fi

  CLUSTER_NAME=$1
  [[ "$CLUSTER_NAME" =~ ^[a-z0-9][a-z0-9-]*$ ]] &&
    [ "${#CLUSTER_NAME}" -le 48 ] || {
      echo "Invalid cluster name." >&2
      exit 1
    }

  PROFILE=$CLUSTER_NAME
  REGION=${AWS_REGION:-${AWS_DEFAULT_REGION:-us-gov-west-1}}
  KUBEZT_DIR=${KUBEZT_HOME:-$HOME/.kubezt}
  CLUSTER_DIR="$KUBEZT_DIR/clusters/$CLUSTER_NAME"
  BUCKET="kubezt-$CLUSTER_NAME-secrets"
  export AWS_SHARED_CREDENTIALS_FILE=${AWS_SHARED_CREDENTIALS_FILE:-$HOME/.aws/credentials}
  CREDENTIALS_FILE=$AWS_SHARED_CREDENTIALS_FILE
  AWS_DIR=$(dirname "$CREDENTIALS_FILE")

  mkdir -p "$CLUSTER_DIR" "$AWS_DIR"
  chmod 0700 "$KUBEZT_DIR" "$KUBEZT_DIR/clusters" "$CLUSTER_DIR" "$AWS_DIR"

  TEMP_DIR=$(mktemp -d "$CLUSTER_DIR/.download.XXXXXXXX")
  CREDENTIALS_LOCK=''
  cleanup() {
    rm -rf "$TEMP_DIR"
    if [ -n "$CREDENTIALS_LOCK" ]; then
      rmdir "$CREDENTIALS_LOCK" 2>/dev/null || true
    fi
  }
  trap cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM

  check_credentials_file() {
    if [ -L "$CREDENTIALS_FILE" ] ||
      { [ -e "$CREDENTIALS_FILE" ] &&
        { [ ! -f "$CREDENTIALS_FILE" ] || [ ! -r "$CREDENTIALS_FILE" ]; }; }; then
      echo "AWS credentials must be a readable regular file: $CREDENTIALS_FILE" >&2
      exit 1
    fi
  }

  profile_exists() {
    [ -f "$CREDENTIALS_FILE" ] || return 1
    awk -v profile="$PROFILE" '
      /^[[:space:]]*\[/ {
        section = $0
        sub(/^[[:space:]]*\[/, "", section)
        sub(/\].*$/, "", section)
        if (section == profile) found = 1
      }
      END { exit !found }
    ' "$CREDENTIALS_FILE"
  }

  check_credentials_file
  if profile_exists; then
    echo "Using existing AWS profile [$PROFILE]."
  else
    # stdin contains the script when invoked through curl | bash.
    if ! { exec 3<>/dev/tty; } 2>/dev/null; then
      echo "AWS profile [$PROFILE] is missing. Run bind from an interactive terminal to enter credentials." >&2
      exit 1
    fi

    printf 'AWS credentials for [%s]\nAccess Key ID: ' "$PROFILE" >&3
    IFS= read -r ACCESS_KEY_ID <&3 || exit 1
    printf 'Access Key Secret: ' >&3
    IFS= read -r -s ACCESS_KEY_SECRET <&3 || { printf '\n' >&3; exit 1; }
    printf '\n' >&3
    exec 3>&-

    if ! [[ "$ACCESS_KEY_ID" =~ ^[A-Za-z0-9]+$ ]] ||
      ! [[ "$ACCESS_KEY_SECRET" =~ ^[A-Za-z0-9/+=]+$ ]]; then
      echo "Credentials must be nonempty and contain only valid key characters." >&2
      exit 1
    fi

    # Serialize writes by bind, then recheck in case another run added the profile.
    if ! mkdir "$CREDENTIALS_FILE.kubezt-lock" 2>/dev/null; then
      echo "AWS credentials are locked by another bind run. Retry after it finishes: $CREDENTIALS_FILE.kubezt-lock" >&2
      exit 1
    fi
    CREDENTIALS_LOCK="$CREDENTIALS_FILE.kubezt-lock"
    check_credentials_file
    if profile_exists; then
      echo "Using existing AWS profile [$PROFILE]; entered credentials were not saved."
    else
      : >> "$CREDENTIALS_FILE"
      chmod 0600 "$CREDENTIALS_FILE"
      # Bash printf keeps credentials out of external process arguments.
      printf '\n[%s]\naws_access_key_id = %s\naws_secret_access_key = %s\n' \
        "$PROFILE" "$ACCESS_KEY_ID" "$ACCESS_KEY_SECRET" >> "$CREDENTIALS_FILE"
      echo "Created AWS profile [$PROFILE] in $CREDENTIALS_FILE."
    fi
    unset ACCESS_KEY_ID ACCESS_KEY_SECRET
    rmdir "$CREDENTIALS_LOCK"
    CREDENTIALS_LOCK=''
  fi

  AWS_BIN=$(command -v aws || true)
  if [ -z "$AWS_BIN" ]; then
    AWS_BIN="$KUBEZT_DIR/tools/bin/aws"
    if [ ! -x "$AWS_BIN" ]; then
      echo "Installing AWS CLI..."
      curl --fail --silent --show-error --location \
        --proto '=https' --proto-redir '=https' \
        https://awscli.amazonaws.com/v2/install.sh \
        --output "$TEMP_DIR/aws-install.sh"
      XDG_DATA_HOME="$KUBEZT_DIR/tools" XDG_BIN_HOME="$KUBEZT_DIR/tools/bin" \
        bash "$TEMP_DIR/aws-install.sh" </dev/null
      [ -x "$AWS_BIN" ] || { echo "AWS CLI installation failed." >&2; exit 1; }
    fi
  fi

  ARTIFACTS=(
    "$CLUSTER_NAME-topology.json"
    "$CLUSTER_NAME"
    "$CLUSTER_NAME.pub"
    "$CLUSTER_NAME.config"
  )

  for artifact in "${ARTIFACTS[@]}"; do
    echo "Downloading $artifact..."
    AWS_PAGER='' AWS_CLI_AUTO_PROMPT=off "$AWS_BIN" \
      --profile "$PROFILE" --region "$REGION" \
      s3 cp "s3://$BUCKET/$artifact" "$TEMP_DIR/$artifact" --only-show-errors
    [ -s "$TEMP_DIR/$artifact" ] || { echo "Empty artifact: $artifact" >&2; exit 1; }
  done

  chmod 0600 "$TEMP_DIR/$CLUSTER_NAME-topology.json" \
    "$TEMP_DIR/$CLUSTER_NAME" "$TEMP_DIR/$CLUSTER_NAME.config"
  chmod 0644 "$TEMP_DIR/$CLUSTER_NAME.pub"

  # Save the files only after all four downloads succeed.
  for artifact in "${ARTIFACTS[@]}"; do
    if [ -L "$CLUSTER_DIR/$artifact" ] ||
      { [ -e "$CLUSTER_DIR/$artifact" ] && [ ! -f "$CLUSTER_DIR/$artifact" ]; }; then
      echo "Destination is not a regular file: $CLUSTER_DIR/$artifact" >&2
      exit 1
    fi
  done
  for artifact in "${ARTIFACTS[@]}"; do
    mv -f "$TEMP_DIR/$artifact" "$CLUSTER_DIR/$artifact"
  done

  echo "Artifacts saved to $CLUSTER_DIR"
)

main "$@"
