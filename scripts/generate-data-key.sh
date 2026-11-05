#!/usr/bin/env bash
# One time per installation: creates the data key inside KMS and stores only its encrypted form in
# Secrets Manager. The plaintext is never seen by this script, Terraform or anyone. Refuses to run
# again, because replacing the key would make encrypted data unreadable.
#   scripts/generate-data-key.sh <kms-key-id> <region>
set -euo pipefail
KEY=${1:?usage: generate-data-key.sh <kms-key-id> <region>}; REGION=${2:?region required}
SECRET=hrms/data-key-ciphertext
if aws secretsmanager get-secret-value --region "$REGION" --secret-id "$SECRET" --query VersionId --output text >/dev/null 2>&1; then
  echo "error: $SECRET already has a value. Replacing it would make encrypted data unreadable." >&2; exit 1
fi
CIPHERTEXT=$(aws kms generate-data-key-without-plaintext --region "$REGION" --key-id "$KEY" --key-spec AES_256 --query CiphertextBlob --output text)
aws secretsmanager put-secret-value --region "$REGION" --secret-id "$SECRET" --secret-string "$CIPHERTEXT" >/dev/null
echo "stored the encrypted data key in $SECRET"
