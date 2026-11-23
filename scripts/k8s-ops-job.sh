#!/usr/bin/env bash
# Runs an operator command (docs/CONFIGURATION.md, Operator commands) as a one-off Job, with the schema
# owner's credentials and the image the cluster is running now. For migrate-down that is the point: the
# down files come from the image being left, so run this BEFORE the older release is pushed.
#   scripts/k8s-ops-job.sh migrate-status
#   scripts/k8s-ops-job.sh migrate-down --steps 1      (or --to NAME, or --all)
#   scripts/k8s-ops-job.sh rotate-keys
#   IMAGE=<image@digest> scripts/k8s-ops-job.sh --print migrate-down --steps 1    only print the Job
set -euo pipefail
NAMESPACE=${NAMESPACE:-hrms}
PRINT=0
if [ "${1:-}" = --print ]; then PRINT=1; shift; fi
CMD=${1:?usage: k8s-ops-job.sh [--print] <migrate-status|migrate-down ...|rotate-keys>}
case "$CMD" in
  migrate-status|rotate-keys) ;;
  migrate-down) [ "$#" -ge 2 ] || { echo "error: migrate-down has no default: give --steps N, --to NAME or --all" >&2; exit 2; } ;;
  *) echo "error: unknown command $CMD" >&2; exit 2 ;;
esac
IMAGE=${IMAGE:-$(kubectl -n "$NAMESPACE" get deployment hrms-backend -o jsonpath='{.spec.template.spec.containers[0].image}')}
case "$IMAGE" in *@sha256:*) ;; *) echo "error: '$IMAGE' is not pinned by digest" >&2; exit 1 ;; esac
NAME="hrms-ops-$CMD-$(date -u +%Y%m%d%H%M%S)"
ARGS=""
for a in "$@"; do ARGS="$ARGS\"$a\", "; done
manifest() {
  cat <<YAML
apiVersion: batch/v1
kind: Job
metadata:
  name: $NAME
  namespace: $NAMESPACE
  labels:
    app.kubernetes.io/name: hrms-migrate
    app.kubernetes.io/component: database-job
    app.kubernetes.io/part-of: hrms
spec:
  backoffLimit: 0
  activeDeadlineSeconds: 3600
  ttlSecondsAfterFinished: 86400
  template:
    metadata:
      labels:
        app.kubernetes.io/name: hrms-migrate
        app.kubernetes.io/component: database-job
        app.kubernetes.io/part-of: hrms
    spec:
      restartPolicy: Never
      serviceAccountName: hrms-migrate
      automountServiceAccountToken: false
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        runAsGroup: 1000
        fsGroup: 1000
        seccompProfile: { type: RuntimeDefault }
      containers:
        - name: ops
          image: $IMAGE
          imagePullPolicy: IfNotPresent
          args: [${ARGS%, }]
          envFrom:
            - secretRef: { name: hrms-migration }
            - secretRef: { name: hrms-data-key }
          resources:
            requests: { cpu: 100m, memory: 128Mi }
            limits: { cpu: 500m, memory: 512Mi }
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities: { drop: [ALL] }
          volumeMounts:
            - { name: tmp, mountPath: /tmp }
      volumes:
        - name: tmp
          emptyDir: { sizeLimit: 64Mi }
YAML
}
if [ "$PRINT" = 1 ]; then manifest; exit 0; fi
manifest | kubectl apply -f -
echo "waiting for job/$NAME"
while :; do
  state=$(kubectl -n "$NAMESPACE" get job "$NAME" -o jsonpath='{range .status.conditions[?(@.status=="True")]}{.type}{end}')
  case "$state" in *Complete*|*Failed*) break ;; esac
  sleep 5
done
kubectl -n "$NAMESPACE" logs "job/$NAME"
case "$state" in *Complete*) echo "job/$NAME complete" ;; *) echo "error: job/$NAME failed" >&2; exit 1 ;; esac
