# Sourced by tools/dev/twin.sh. Real drift in one live cell, one check at a time: the checker must fail on
# exactly that check, and pass again once it's restored. It also freezes a cell, which must read as unknown.
# Argo CD and Argo Rollouts are stopped on the AWS cell meanwhile, or they would heal the drift or start a
# canary from it. The checker itself only reads.
parity_ok() { echo "ok   $1"; }
parity_bad() { echo "FAIL $1"; PARITY_FAIL=1; }

parity_run() { # extra arguments for the CLI; JSON into $PARITY_OUT, returns its exit code
  (cd "$REPO" && PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$REPO/control-plane/parity-checker" \
    python3 -m parity check --env local --json "$@") >"$PARITY_OUT" 2>"$PARITY_OUT.err"
}

parity_show() { # one line per finding that isn't a match
  python3 -I -c '
import json, sys
p = json.load(open(sys.argv[1]))
off = [f["check_id"] + "=" + f["status"] for f in p["findings"] if f["status"] != "match"]
print("     score %.3f, %s" % (p["score"], ", ".join(off) or "every check matches"))' "$PARITY_OUT"
}

parity_only() { # the check that must have diverged, alone
  python3 -I -c '
import json, sys
p = json.load(open(sys.argv[1]))
bad = [(f["check_id"], f["status"]) for f in p["findings"] if f["status"] != "match"]
sys.exit(0 if bad == [(sys.argv[2], "diverged")] and p["score"] < 1 and not p["passed"] else 1)' "$PARITY_OUT" "$1"
}

parity_expect_drift() { # label, check id, then CLI arguments
  local label=$1 check=$2 rc=0; shift 2
  parity_run "$@" || rc=$?
  parity_show
  if [ "$rc" -eq 1 ] && parity_only "$check"; then parity_ok "$label fails $check and nothing else"; else parity_bad "$label: exit $rc, wanted $check alone"; head -c 300 "$PARITY_OUT.err"; fi
}

parity_template() { kc aws -n cb-app get rollout "$1" -o json | python3 -I -c 'import json,sys; print(json.dumps({"spec":{"template":json.load(sys.stdin)["spec"]["template"]}}))'; }

parity_restore_now() { # whatever the current step broke
  [ -n "${PARITY_UNDO:-}" ] || return 0
  eval "$PARITY_UNDO"; PARITY_UNDO=""
}

parity_drift() {
  PARITY_FAIL=0
  PARITY_OUT=$(mktemp)
  export CB_CP_TOKEN
  CB_CP_TOKEN=$(sed -n 's/^CB_CP_TOKEN=//p' "$TWIN_DIR/control-plane/api.env")
  local post="http://127.0.0.1:${CB_TWIN_API_PORT:-8010}/parity/snapshots" rc=0 before after
  parity_finish() {
    parity_restore_now || true
    compose unpause cell-gcp >/dev/null 2>&1 || true
    kc aws -n argo-rollouts scale deployment argo-rollouts --replicas=1 >/dev/null 2>&1 || true
    kc aws -n argocd scale statefulset argocd-application-controller --replicas=1 >/dev/null 2>&1 || true
    rm -f "$PARITY_OUT" "$PARITY_OUT.err"
  }
  trap parity_finish EXIT

  parity_run --post "$post" --trigger manual || { parity_show; echo "FAIL the cells differ before anything was injected"; exit 1; }
  parity_show
  parity_ok "clean to begin with, snapshot stored"
  before=$(kc aws -n cb-app get rollout -o jsonpath='{range .items[*]}{.metadata.name}={.status.stableRS} {end}')

  kc aws -n argocd scale statefulset argocd-application-controller --replicas=0 >/dev/null
  kc aws -n argo-rollouts scale deployment argo-rollouts --replicas=0 >/dev/null
  kc aws -n argocd wait pod -l app.kubernetes.io/name=argocd-application-controller --for=delete --timeout=120s >/dev/null 2>&1 || true
  kc aws -n argo-rollouts wait pod -l app.kubernetes.io/name=argo-rollouts --for=delete --timeout=120s >/dev/null 2>&1 || true
  echo "Argo CD and Argo Rollouts stopped on cb-aws-local"

  # The plan's "done when": a chart version changed in one cell. It stores this snapshot too, so the failure shows.
  local revision saved image
  revision=$(kc aws -n argocd get application traefik -o jsonpath='{.spec.source.targetRevision}')
  PARITY_UNDO="kc aws -n argocd patch application traefik --type=merge -p '{\"spec\":{\"source\":{\"targetRevision\":\"$revision\"}}}' >/dev/null"
  kc aws -n argocd patch application traefik --type=merge -p '{"spec":{"source":{"targetRevision":"0.0.1"}}}' >/dev/null
  parity_expect_drift "a chart version changed in one cell" chart.versions --post "$post" --trigger manual
  parity_restore_now

  saved=$(parity_template api-gateway)
  image=$(kc aws -n cb-app get rollout api-gateway -o jsonpath='{.spec.template.spec.containers[0].image}')
  PARITY_UNDO="kc aws -n cb-app patch rollout api-gateway --type=merge -p '$saved' >/dev/null"
  case "$image" in *0) image="${image%0}1" ;; *) image="${image%?}0" ;; esac
  kc aws -n cb-app patch rollout api-gateway --type=json -p "[{\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/image\",\"value\":\"$image\"}]" >/dev/null
  parity_expect_drift "a hotfix image in one cell" images.digests
  parity_restore_now

  saved=$(parity_template order-service)
  PARITY_UNDO="kc aws -n cb-app patch rollout order-service --type=merge -p '$saved' >/dev/null"
  kc aws -n cb-app patch rollout order-service --type=json -p '[{"op":"replace","path":"/spec/template/spec/containers/0/resources/requests/cpu","value":"101m"}]' >/dev/null
  parity_expect_drift "a CPU request changed in one cell" resources.requests
  parity_restore_now

  saved=$(parity_template inventory-service)
  PARITY_UNDO="kc aws -n cb-app patch rollout inventory-service --type=merge -p '$saved' >/dev/null"
  kc aws -n cb-app patch rollout inventory-service --type=json -p '[{"op":"add","path":"/spec/template/spec/containers/0/env/-","value":{"name":"CB_PARITY_DRIFT","value":"1"}}]' >/dev/null
  parity_expect_drift "an env var added in one cell" app.config.hash
  parity_restore_now

  local maximum
  maximum=$(kc aws -n cb-app get hpa order-service -o jsonpath='{.spec.maxReplicas}')
  PARITY_UNDO="kc aws -n cb-app patch hpa order-service --type=merge -p '{\"spec\":{\"maxReplicas\":$maximum}}' >/dev/null"
  kc aws -n cb-app patch hpa order-service --type=merge -p "{\"spec\":{\"maxReplicas\":$(( maximum + 1 ))}}" >/dev/null
  parity_expect_drift "HPA max changed in one cell" hpa.max
  parity_restore_now

  PARITY_UNDO="kc aws -n cb-app delete networkpolicy cb-parity-drift --ignore-not-found >/dev/null"
  kc aws -n cb-app apply -f - >/dev/null <<'YAML'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: cb-parity-drift
spec:
  podSelector:
    matchLabels:
      app: cb-parity-selects-nothing
YAML
  parity_expect_drift "a NetworkPolicy added in one cell" networkpolicy.count
  parity_restore_now

  parity_cell_sql() { kc aws -n cb-app exec -i statefulset/postgres -- sh -c 'psql -q -U "$POSTGRES_USER" -d cell -v ON_ERROR_STOP=1' >/dev/null; }
  PARITY_UNDO="echo \"DELETE FROM orders.flyway_schema_history WHERE installed_rank = 999;\" | parity_cell_sql"
  parity_cell_sql <<'SQL'
INSERT INTO orders.flyway_schema_history (installed_rank, version, description, type, script, installed_by, execution_time, success)
VALUES (999, '999', 'parity drift', 'SQL', 'drift', 'twin', 0, true);
SQL
  parity_expect_drift "a migration applied to one cell" flyway.version
  parity_restore_now

  kc aws -n argo-rollouts scale deployment argo-rollouts --replicas=1 >/dev/null
  kc aws -n argocd scale statefulset argocd-application-controller --replicas=1 >/dev/null
  echo "Argo CD and Argo Rollouts restarted on cb-aws-local"

  echo "freezing cb-gcp-local: the checker can't read it"
  compose pause cell-gcp >/dev/null
  rc=0; parity_run --post "$post" --trigger manual || rc=$?
  parity_show
  if [ "$rc" -eq 1 ] && python3 -I -c '
import json, sys
p = json.load(open(sys.argv[1]))
sys.exit(0 if p["score"] == 0 and all(f["status"] == "unknown" for f in p["findings"]) else 1)' "$PARITY_OUT"; then
    parity_ok "a cell it can't read makes every check unknown, score 0: never a match"
  else
    parity_bad "a frozen cell: exit $rc"
  fi
  compose unpause cell-gcp >/dev/null
  local deadline=$(( $(date +%s) + 120 ))
  until kc gcp -n cb-app get rollout >/dev/null 2>&1; do
    [ "$(date +%s)" -lt "$deadline" ] || { parity_bad "cb-gcp-local didn't answer after unpausing"; break; }
    sleep 3
  done

  rc=0; parity_run --post "$post" --trigger post_sync || rc=$?
  parity_show
  [ "$rc" -eq 0 ] && parity_ok "restored: score 1.0 again, snapshot stored" || parity_bad "still differing after the restore"
  after=$(kc aws -n cb-app get rollout -o jsonpath='{range .items[*]}{.metadata.name}={.status.stableRS} {end}')
  [ "$before" = "$after" ] && parity_ok "no drill started a rollout: $after" || parity_bad "rollouts moved: $before -> $after"
  origin_ok aws && parity_ok "cb-aws-local still serves" || parity_bad "cb-aws-local stopped serving"

  local shown
  shown=$(curl -sS -m 15 -H "Authorization: Bearer $CB_CP_TOKEN" "http://127.0.0.1:${CB_TWIN_API_PORT:-8010}/parity?env=local" | python3 -I -c '
import json, sys
p = json.load(sys.stdin)
print(p["latest"]["score"], p["latest"]["passed"], sum(1 for t in p["trend"] if not t["passed"]))')
  echo "     GET /parity: score, passed, failing snapshots in the trend: $shown"
  case "$shown" in "1.0 True "[1-9]*) parity_ok "the API shows the pass and the failures before it" ;; *) parity_bad "GET /parity: $shown" ;; esac

  parity_finish; trap - EXIT
  [ "$PARITY_FAIL" -eq 0 ] && echo "TWIN PARITY PASSED" || { echo "TWIN PARITY FAILED"; exit 1; }
}
