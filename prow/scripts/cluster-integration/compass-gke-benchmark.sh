#!/usr/bin/env bash

set -o errexit
set -o pipefail  # Fail a pipe if any sub-command fails.

export TEST_INFRA_SOURCES_DIR="${KYMA_PROJECT_DIR}/test-infra"
export KYMA_SOURCES_DIR="${KYMA_PROJECT_DIR}/kyma"
export COMPASS_SOURCES_DIR="/home/prow/go/src/github.com/kyma-incubator/compass"
export TEST_INFRA_CLUSTER_INTEGRATION_SCRIPTS="${TEST_INFRA_SOURCES_DIR}/prow/scripts/cluster-integration/helpers"

# shellcheck source=prow/scripts/lib/utils.sh
source "${TEST_INFRA_SOURCES_DIR}/prow/scripts/lib/utils.sh"
# shellcheck source=prow/scripts/lib/log.sh
source "${TEST_INFRA_SOURCES_DIR}/prow/scripts/lib/log.sh"
# shellcheck source=prow/scripts/lib/docker.sh
source "${TEST_INFRA_SOURCES_DIR}/prow/scripts/lib/docker.sh"
# shellcheck source=prow/scripts/lib/gcp.sh
source "${TEST_INFRA_SOURCES_DIR}/prow/scripts/lib/gcp.sh"
# shellcheck source=prow/scripts/lib/kyma.sh
source "${TEST_INFRA_SOURCES_DIR}/prow/scripts/lib/kyma.sh"

requiredVars=(
    REPO_OWNER
    REPO_NAME
    DOCKER_PUSH_REPOSITORY
    KYMA_PROJECT_DIR
    CLOUDSDK_CORE_PROJECT
    CLOUDSDK_COMPUTE_REGION
    CLOUDSDK_COMPUTE_ZONE
    CLOUDSDK_DNS_ZONE_NAME
    GOOGLE_APPLICATION_CREDENTIALS
)

utils::check_required_vars "${requiredVars[@]}"

export GCLOUD_SERVICE_KEY_PATH="${GOOGLE_APPLICATION_CREDENTIALS}"

# Enforce lowercase
readonly REPO_OWNER=${REPO_OWNER,,}
export REPO_OWNER
readonly REPO_NAME=${REPO_NAME,,}
export REPO_NAME

readonly RANDOM_NAME_SUFFIX=$(LC_ALL=C tr -dc 'a-z0-9' < /dev/urandom | head -c10)

if [[ "$BUILD_TYPE" == "pr" ]]; then
  # In case of PR, operate on PR number
  readonly COMMON_NAME_PREFIX="gkecompint-pr"
  COMMON_NAME=$(echo "${COMMON_NAME_PREFIX}-${PULL_NUMBER}-${RANDOM_NAME_SUFFIX}")
  export JOBGUARD_TIMEOUT="30m"
else
  # Otherwise (main), operate on triggering commit id
  readonly COMMON_NAME_PREFIX="gkecompint-commit"
  readonly COMMIT_ID=$(cd "$COMPASS_SOURCES_DIR" && git rev-parse --short HEAD)
  COMMON_NAME=$(echo "${COMMON_NAME_PREFIX}-${COMMIT_ID}-${RANDOM_NAME_SUFFIX}")
fi

### Cluster name must be less than 40 characters!
COMMON_NAME=$(echo "${COMMON_NAME}" | tr "[:upper:]" "[:lower:]")

gcp::set_vars_for_network \
  -n "$JOB_NAME"
export GCLOUD_NETWORK_NAME="${gcp_set_vars_for_network_return_net_name:?}"
export GCLOUD_SUBNET_NAME="${gcp_set_vars_for_network_return_subnet_name:?}"

#Local variables
DNS_SUBDOMAIN="${COMMON_NAME}"
COMPASS_SCRIPTS_DIR="${COMPASS_SOURCES_DIR}/installation/scripts"

function createCluster() {
  #Used to detect errors for logging purposes
  ERROR_LOGGING_GUARD="true"

  log::info "Authenticate"
  gcp::authenticate \
    -c "${GOOGLE_APPLICATION_CREDENTIALS}"
  docker::start
  DNS_DOMAIN="$(gcloud dns managed-zones describe "${CLOUDSDK_DNS_ZONE_NAME}" --format="value(dnsName)")"
  export DNS_DOMAIN
  DOMAIN="${DNS_SUBDOMAIN}.${DNS_DOMAIN%?}"
  export DOMAIN

  log::info "Reserve IP Address for Ingressgateway"
  GATEWAY_IP_ADDRESS_NAME="${COMMON_NAME}"
  gcp::reserve_ip_address \
    -n "${GATEWAY_IP_ADDRESS_NAME}" \
    -p "$CLOUDSDK_CORE_PROJECT" \
    -r "$CLOUDSDK_COMPUTE_REGION"
  GATEWAY_IP_ADDRESS="${gcp_reserve_ip_address_return_ip_address:?}"
  CLEANUP_GATEWAY_IP_ADDRESS="true"
  echo "Created IP Address for Ingressgateway: ${GATEWAY_IP_ADDRESS}"

  log::info "Create DNS Record for Ingressgateway IP"
  gcp::create_dns_record \
    -a "$GATEWAY_IP_ADDRESS" \
    -h "*" \
    -s "$COMMON_NAME" \
    -p "$CLOUDSDK_CORE_PROJECT" \
    -z "$CLOUDSDK_DNS_ZONE_NAME"
  CLEANUP_GATEWAY_DNS_RECORD="true"

  log::info "Create ${GCLOUD_NETWORK_NAME} network with ${GCLOUD_SUBNET_NAME} subnet"
  gcp::create_network \
    -n "${GCLOUD_NETWORK_NAME}" \
    -s "${GCLOUD_SUBNET_NAME}" \
    -p "$CLOUDSDK_CORE_PROJECT"

  log::info "Provision cluster: \"${COMMON_NAME}\""
  export GCLOUD_SERVICE_KEY_PATH="${GOOGLE_APPLICATION_CREDENTIALS}"
  gcp::provision_k8s_cluster \
        -c "$COMMON_NAME" \
        -p "$CLOUDSDK_CORE_PROJECT" \
        -v "$GKE_CLUSTER_VERSION" \
        -j "$JOB_NAME" \
        -J "$PROW_JOB_ID" \
        -z "$CLOUDSDK_COMPUTE_ZONE" \
        -R "$CLOUDSDK_COMPUTE_REGION" \
        -N "$GCLOUD_NETWORK_NAME" \
        -S "$GCLOUD_SUBNET_NAME" \
        -P "$TEST_INFRA_SOURCES_DIR"
  CLEANUP_CLUSTER="true"

  utils::generate_self_signed_cert \
      -d "$DNS_DOMAIN" \
      -s "$COMMON_NAME" \
      -v "$SELF_SIGN_CERT_VALID_DAYS"
  export TLS_CERT="${utils_generate_self_signed_cert_return_tls_cert:?}"
  export TLS_KEY="${utils_generate_self_signed_cert_return_tls_key:?}"

  # TODO
  # Prepare Docker external registry overrides
  export DOCKER_PASSWORD=""
  DOCKER_PASSWORD=$(tr -d '\n' < "${GOOGLE_APPLICATION_CREDENTIALS}")

  export DOCKER_REPOSITORY_ADDRESS=""
  DOCKER_REPOSITORY_ADDRESS=$(echo "$DOCKER_PUSH_REPOSITORY" | cut -d'/' -f1)

  export DNS_DOMAIN_TRAILING=${DNS_DOMAIN%.}
  envsubst < "${TEST_INFRA_SOURCES_DIR}/prow/scripts/resources/compass-gke-kyma-overrides.tpl.yaml" > "$PWD/kyma_overrides.yaml"
}

function installYQ() {
  utils:install_yq
}

function installKyma() {
  kyma::install_cli

  KYMA_VERSION=$(<"${COMPASS_SOURCES_DIR}/installation/resources/KYMA_VERSION")
  MINIMAL_KYMA="${COMPASS_SOURCES_DIR}/installation/resources/kyma/kyma-components-minimal.yaml"
  kyma deploy --ci --source="${KYMA_VERSION}" --workspace "$KYMA_SOURCES_DIR" --verbose -c "${MINIMAL_KYMA}" --values-file "$PWD/kyma_overrides.yaml"
}

function installCompassOld() {
  cd "$COMPASS_SOURCES_DIR"
  readonly LATEST_VERSION=$(git rev-parse --short main~1)
  echo "Checkout $LATEST_VERSION"
  git checkout "${LATEST_VERSION}"

  COMPASS_OVERRIDES="${COMPASS_SOURCES_DIR}/installation/resources/compass-overrides-gke-benchmark.yaml"
  bash "${COMPASS_SCRIPTS_DIR}"/install-compass.sh --overrides-file "${COMPASS_OVERRIDES}" --timeout 30m0s
  STATUS=$(helm status compass -n compass-system -o json | jq .info.status)
  echo "Compass installation status ${STATUS}"
}

function installCompassNew() {
  compassUnsetVar=false

  # shellcheck disable=SC2043
  for var in GATEWAY_IP_ADDRESS ; do
    if [ -z "${!var}" ] ; then
      echo "ERROR: $var is not set"
      compassUnsetVar=true
    fi
  done
  if [ "${compassUnsetVar}" = true ] ; then
    exit 1
  fi

  COMPASS_OVERRIDES="${COMPASS_SOURCES_DIR}/installation/resources/compass-overrides-gke-benchmark.yaml"
  bash "${COMPASS_SCRIPTS_DIR}"/install-compass.sh --overrides-file "${COMPASS_OVERRIDES}" --timeout 30m0s
  STATUS=$(helm status compass -n compass-system -o json | jq .info.status)
  echo "Compass installation status ${STATUS}"

  if [ -n "$(kubectl get service -n kyma-system apiserver-proxy-ssl --ignore-not-found)" ]; then
    log::info "Create DNS Record for Apiserver proxy IP"
    APISERVER_IP_ADDRESS=$(kubectl get service -n kyma-system apiserver-proxy-ssl -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
    gcp::create_dns_record \
        -a "$APISERVER_IP_ADDRESS" \
        -h "apiserver" \
        -s "$COMMON_NAME" \
        -p "$CLOUDSDK_CORE_PROJECT" \
        -z "$CLOUDSDK_DNS_ZONE_NAME"
    CLEANUP_APISERVER_DNS_RECORD="true"
  fi
}

# Using set -f to prevent path globing in post_hook arguments.
# utils::post_hook call set +f at the beginning.
trap 'EXIT_STATUS=$?; set -f; utils::post_hook -n "$COMMON_NAME" -p "$CLOUDSDK_CORE_PROJECT" -c "$CLEANUP_CLUSTER" -g "$CLEANUP_GATEWAY_DNS_RECORD" -G "$INGRESS_GATEWAY_HOSTNAME" -a "$CLEANUP_APISERVER_DNS_RECORD" -A "$APISERVER_HOSTNAME" -I "$CLEANUP_GATEWAY_IP_ADDRESS" -l "$ERROR_LOGGING_GUARD" -z "$CLOUDSDK_COMPUTE_ZONE" -R "$CLOUDSDK_COMPUTE_REGION" -r "$PROVISION_REGIONAL_CLUSTER" -d "$DISABLE_ASYNC_DEPROVISION" -s "$COMMON_NAME" -e "$GATEWAY_IP_ADDRESS" -f "$APISERVER_IP_ADDRESS" -N "$COMMON_NAME" -Z "$CLOUDSDK_DNS_ZONE_NAME" -E "$EXIT_STATUS" -j "$JOB_NAME"; ' EXIT INT

if [[ "${BUILD_TYPE}" == "pr" ]]; then
    log::info "Execute Job Guard"
    export JOB_NAME_PATTERN="(pre-compass-components-.*)|(pre-compass-tests-.*)"
    export JOBGUARD_TIMEOUT="30m"
    "${TEST_INFRA_SOURCES_DIR}/development/jobguard/scripts/run.sh"
fi

log::info "Create new cluster"
createCluster

log::info "Choose node for benchmarks execution"
NODE=$(kubectl get nodes | tail -n 1 | cut -d ' ' -f 1)

log::info "Benchmarks will be executed on node: $NODE. Will make it unschedulable."
kubectl label node "$NODE" benchmark=true
kubectl cordon "$NODE"

log::info "Install yq"
installYQ

log::info "Install Kyma"
installKyma

log::info "Install Compass version from main"
installCompassOld

readonly SUITE_NAME="testsuite-all"

log::info "Execute benchmarks on the current main"
kubectl uncordon "$NODE"
CONCURRENCY=1 "${TEST_INFRA_SOURCES_DIR}"/prow/scripts/kyma-testing.sh -l "benchmark=true"
kubectl cordon "$NODE"

PODS=$(kubectl get cts $SUITE_NAME -o=go-template --template='{{range .status.results}}{{range .executions}}{{printf "%s\n" .id}}{{end}}{{end}}')
for POD in $PODS; do
  CONTAINER=$(kubectl -n kyma-system get pod "$POD" -o jsonpath='{.spec.containers[*].name}' | sed s/istio-proxy//g | awk '{$1=$1};1')
  kubectl logs -n kyma-system "$POD" -c "$CONTAINER" > "$CONTAINER"-old
done

kubectl delete cts $SUITE_NAME

# Because of sequential compass installation, the second one fails due to compass-migration job patching failure. K8s job's fields are immutable.
log::info "Deleting the old compass-migration job"
kubectl delete jobs -n compass-system compass-migration

log::info "Install New Compass version"
installCompassNew

log::info "Execute benchmarks on the new release"
kubectl uncordon "$NODE"
CONCURRENCY=1 "${TEST_INFRA_SOURCES_DIR}"/prow/scripts/kyma-testing.sh -l "benchmark=true"
kubectl cordon "$NODE"

PODS=$(kubectl get cts $SUITE_NAME -o=go-template --template='{{range .status.results}}{{range .executions}}{{printf "%s\n" .id}}{{end}}{{end}}')

CHECK_FAILED=false
FAILED_TESTS=''

for POD in $PODS; do
  CONTAINER=$(kubectl -n kyma-system get pod "$POD" -o jsonpath='{.spec.containers[*].name}' | sed s/istio-proxy//g | awk '{$1=$1};1')
  kubectl logs -n kyma-system "$POD" -c "$CONTAINER" > "$CONTAINER"-new

  if [ -f "$CONTAINER"-old ]; then
    log::info "Stats of the main installation"
    benchstat "$CONTAINER"-old

    log::info "Stats of the new installation"
    benchstat "$CONTAINER"-new

    STATS=$(benchstat "$CONTAINER"-old "$CONTAINER"-new)
    log::info "Performance comparison statistics"
    echo "$STATS"

    DELTA=$(echo -n "$STATS" | tail +2 | { grep -v '~' || true; } | awk '{print $(NF-2)}')
    if [[ $DELTA == +* ]]; then # If delta is positive
      log::error "There is significant performance degradation in the new release!"
      CHECK_FAILED=true
      FAILED_TESTS="$CONTAINER\\n$FAILED_TESTS"
    fi
  else
    benchstat "$CONTAINER"-new
  fi
done

if [ $CHECK_FAILED = true ]; then
  log::error "The following benchmark tests failed:\\n $FAILED_TESTS"
  exit 1
fi

log::success "Success"

#!!! Must be at the end of the script !!!
ERROR_LOGGING_GUARD="false"
