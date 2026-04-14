#!/usr/bin/env bash
# upload_samples.sh — Upload synthetic OTM CSV files to the lab S3 data lake
#
# Usage:
#   ./upload_samples.sh --stack-name otm-lab [--region us-east-1] [--profile default]
#
# Prerequisites:
#   - AWS CLI installed and configured
#   - CloudFormation stack already deployed (see cloudformation.yml)
#   - Sample CSV files present in ../samples/

set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
STACK_NAME=""
REGION="us-east-1"
PROFILE="default"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SAMPLES_DIR="${SCRIPT_DIR}/../samples"

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
usage() {
  cat <<EOF
Usage: $(basename "$0") --stack-name <name> [OPTIONS]

Options:
  --stack-name <name>     CloudFormation stack name (required)
  --region <region>       AWS region (default: us-east-1)
  --profile <profile>     AWS CLI profile (default: default)
  --samples-dir <path>    Directory containing sample CSVs (default: ../samples)
  -h, --help              Show this help

Examples:
  $(basename "$0") --stack-name otm-lab
  $(basename "$0") --stack-name otm-lab --region us-west-2 --profile lab-account
EOF
  exit 1
}

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --stack-name)  STACK_NAME="$2";  shift 2 ;;
    --region)      REGION="$2";      shift 2 ;;
    --profile)     PROFILE="$2";     shift 2 ;;
    --samples-dir) SAMPLES_DIR="$2"; shift 2 ;;
    -h|--help)     usage ;;
    *) echo "ERROR: Unknown option: $1" >&2; usage ;;
  esac
done

[[ -z "${STACK_NAME}" ]] && { echo "ERROR: --stack-name is required" >&2; usage; }

# ---------------------------------------------------------------------------
# Verify sample files exist
# ---------------------------------------------------------------------------
GL_USER_CSV="${SAMPLES_DIR}/gl_user_sample.csv"
ROLE_CSV="${SAMPLES_DIR}/user_role_acr_role_sample.csv"

for f in "${GL_USER_CSV}" "${ROLE_CSV}"; do
  [[ -f "$f" ]] || { echo "ERROR: Sample file not found: $f" >&2; exit 1; }
done

echo "Sample files verified:"
echo "  ${GL_USER_CSV}"
echo "  ${ROLE_CSV}"
echo ""

# ---------------------------------------------------------------------------
# Resolve data lake bucket name from CloudFormation outputs
# ---------------------------------------------------------------------------
echo "Fetching CloudFormation stack outputs (stack: ${STACK_NAME}, region: ${REGION}) ..."

BUCKET=$(aws cloudformation describe-stacks \
  --stack-name "${STACK_NAME}" \
  --region "${REGION}" \
  --profile "${PROFILE}" \
  --query "Stacks[0].Outputs[?OutputKey=='DataLakeBucketName'].OutputValue" \
  --output text 2>/dev/null)

if [[ -z "${BUCKET}" || "${BUCKET}" == "None" ]]; then
  echo "ERROR: Could not retrieve DataLakeBucketName from stack '${STACK_NAME}'." >&2
  echo "       Ensure the stack is in CREATE_COMPLETE or UPDATE_COMPLETE state." >&2
  exit 1
fi

echo "Data lake bucket: s3://${BUCKET}"
echo ""

# ---------------------------------------------------------------------------
# Upload
# ---------------------------------------------------------------------------
echo "Uploading gl_user_sample.csv ..."
aws s3 cp "${GL_USER_CSV}" \
  "s3://${BUCKET}/data/gl_user/gl_user_sample.csv" \
  --region "${REGION}" \
  --profile "${PROFILE}"

echo "Uploading user_role_acr_role_sample.csv ..."
aws s3 cp "${ROLE_CSV}" \
  "s3://${BUCKET}/data/user_role_acr_role/user_role_acr_role_sample.csv" \
  --region "${REGION}" \
  --profile "${PROFILE}"

# ---------------------------------------------------------------------------
# Verify
# ---------------------------------------------------------------------------
echo ""
echo "Verifying uploads:"
echo "  s3://${BUCKET}/data/gl_user/"
aws s3 ls "s3://${BUCKET}/data/gl_user/" --region "${REGION}" --profile "${PROFILE}"

echo "  s3://${BUCKET}/data/user_role_acr_role/"
aws s3 ls "s3://${BUCKET}/data/user_role_acr_role/" --region "${REGION}" --profile "${PROFILE}"

echo ""
echo "Done. Sample data is live at:"
echo "  s3://${BUCKET}/data/gl_user/gl_user_sample.csv"
echo "  s3://${BUCKET}/data/user_role_acr_role/user_role_acr_role_sample.csv"
echo ""
echo "Next: configure your ODBC DSN and run the dry-run test."
echo "  See aws-lab-setup/ for ODBC DSN setup instructions."
