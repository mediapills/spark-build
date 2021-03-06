#!/usr/bin/env bash

set -eu -o pipefail
export TZ=UTC

function usage () {
  echo 'Usage: ./run.sh \\'
  echo '         <path to test configuration file> \\'
  echo '         <test name> \\'
  echo '         <test S3 bucket> \\'
  echo '         <test S3 folder> \\'
  echo '         <path to cluster SSH private key> \\'
  echo '         <DCOS username> \\'
  echo '         <DCOS password> \\'
  echo '         [<non interactive>] (optional, defaults to "interactive")'
  echo
  echo 'Example: ./run.sh \\'
  echo '           scale-tests/configs/2018-01-01.env \\'
  echo '           scale-tests-2018-01-01 \\'
  echo '           infinity-artifacts \\'
  echo '           scale-tests/2018-01-01 \\'
  echo '           ~/.ssh/dcos \\'
  echo '           john \\'
  echo '           john123 \\'
  echo '           non-interactive \\'
}

if [ "${#}" -lt 7 ]; then
  echo -e "run.sh needs at least 7 arguments but was given ${#}\\n"
  usage
  exit 1
fi

readonly REQUIREMENTS='git docker maws tee'

for requirement in ${REQUIREMENTS}; do
  if ! [[ -x $(command -v "${requirement}") ]]; then
    echo "You need to install '${requirement}' to run this script"
    exit 1
  fi
done

readonly TEST_CONFIG="${1:-}"
readonly TEST_NAME="${2:-}"
readonly TEST_S3_BUCKET="${3:-}"
readonly TEST_S3_FOLDER="${4:-}"
readonly CLUSTER_SSH_KEY="${5:-}"
readonly DCOS_USERNAME="${6:-}"
readonly DCOS_PASSWORD="${7:-}"
readonly MODE="${8:-non-interactive}"

for file in "${CLUSTER_SSH_KEY}" "${TEST_CONFIG}"; do
  if ! [[ -s ${file} ]]; then
    echo "File '${file}' doesn't exist or is empty"
    exit 1
  fi
done

if [ "${MODE}" != "interactive" ] && [ "${MODE}" != "non-interactive" ]; then
  echo "MODE must be either 'interactive' or 'non-interactive', is '${MODE}'"
  exit 1
fi

function is_interactive () {
  [ "${MODE}" = "interactive" ]
}

readonly AWS_ACCOUNT='Team 10'
readonly CONTAINER_NAME="${TEST_NAME}"
readonly CONTAINER_SSH_AGENT_EXPORTS=/tmp/ssh-agent-exports
readonly CONTAINER_SSH_KEY=/ssh/key
readonly CONTAINER_FINISHED_SETTING_UP_FILE=/tmp/finished-setting-up
readonly IMAGE_NAME="mesosphere/dcos-commons:${TEST_NAME}"
readonly SCALE_TESTS_DIRECTORY="scale-tests"
readonly TEST_DIRECTORY="${SCALE_TESTS_DIRECTORY}/runs/${TEST_NAME}"
readonly TEST_REPOSITORY_DIRECTORY="${SCALE_TESTS_DIRECTORY}/checkouts/${TEST_NAME}"
readonly TEST_S3_DIRECTORY_URL="s3://${TEST_S3_BUCKET}/${TEST_S3_FOLDER}/"
readonly LOGS_DIRECTORY="${TEST_DIRECTORY}/script_logs"
readonly LOG_FILE="${LOGS_DIRECTORY}/$(date +%Y%m%dT%H%M%SZ)_$(whoami).log"
readonly DCOS_CLI_REFRESH_INTERVAL_SEC=600 # 10 minutes.

source "${TEST_CONFIG}"

mkdir -p "${TEST_DIRECTORY}"
mkdir -p "${LOGS_DIRECTORY}"

if [ "${SECURITY}" != "permissive" ] && [ "${SECURITY}" != "strict" ]; then
  echo "SECURITY must be either 'permissive' or 'strict', is '${SECURITY}'"
  exit 1
fi

for boolean_option in SHOULD_INSTALL_INFRASTRUCTURE \
                        SHOULD_INSTALL_NON_GPU_DISPATCHERS \
                        SHOULD_INSTALL_GPU_DISPATCHERS \
                        SHOULD_RUN_FAILING_STREAMING_JOBS \
                        SHOULD_RUN_FINITE_STREAMING_JOBS \
                        SHOULD_RUN_INFINITE_STREAMING_JOBS \
                        SHOULD_RUN_BATCH_JOBS \
                        SHOULD_RUN_GPU_BATCH_JOBS \
                        SHOULD_UNINSTALL_INFRASTRUCTURE_AT_THE_END; do
  if [ "${!boolean_option}" != "true" ] && [ "${!boolean_option}" != "false" ]; then
    echo "${boolean_option} must be either 'true' or 'false', is '${!boolean_option}'"
    exit 1
  fi
done

function log {
  local -r message="${*:-}"
  echo "$(date "+%Y-%m-%d %H:%M:%S") | ${message}" 2>&1 | tee -a "${LOG_FILE}"
}

function container_exec () {
  local -r command="${*:-}"
  log "${command}"
  docker exec "${CONTAINER_NAME}" \
    bash -l -c "${command}" 2>&1 | tee -a "${LOG_FILE}"
}

declare -x AWS_PROFILE
eval "$(maws li "${AWS_ACCOUNT}")"

readonly FINITE_NUM_PRODUCERS=$((KAFKA_CLUSTER_COUNT * FINITE_NUM_PRODUCERS_PER_KAFKA))
readonly FINITE_NUM_CONSUMERS=$((FINITE_NUM_PRODUCERS * FINITE_NUM_CONSUMERS_PER_PRODUCER))
readonly FINITE_NUM_JOBS=$((FINITE_NUM_PRODUCERS + FINITE_NUM_CONSUMERS))
readonly INFINITE_NUM_PRODUCERS=$((KAFKA_CLUSTER_COUNT * INFINITE_NUM_PRODUCERS_PER_KAFKA))
readonly INFINITE_NUM_CONSUMERS=$((INFINITE_NUM_PRODUCERS * INFINITE_NUM_CONSUMERS_PER_PRODUCER))
readonly INFINITE_NUM_JOBS=$((INFINITE_NUM_PRODUCERS + INFINITE_NUM_CONSUMERS))
readonly STREAMING_NUM_JOBS=$((FINITE_NUM_JOBS + INFINITE_NUM_JOBS))

readonly NON_GPU_TOTAL_QUOTA_DRIVERS_CPUS=$((NON_GPU_NUM_DISPATCHERS * NON_GPU_QUOTA_DRIVERS_CPUS))
readonly NON_GPU_TOTAL_QUOTA_DRIVERS_MEM=$((NON_GPU_NUM_DISPATCHERS * NON_GPU_QUOTA_DRIVERS_MEM))
readonly NON_GPU_TOTAL_QUOTA_EXECUTORS_CPUS=$((NON_GPU_NUM_DISPATCHERS * NON_GPU_QUOTA_EXECUTORS_CPUS))
readonly NON_GPU_TOTAL_QUOTA_EXECUTORS_MEM=$((NON_GPU_NUM_DISPATCHERS * NON_GPU_QUOTA_EXECUTORS_MEM))

readonly GPU_TOTAL_QUOTA_DRIVERS_CPUS=$((GPU_NUM_DISPATCHERS * GPU_QUOTA_DRIVERS_CPUS))
readonly GPU_TOTAL_QUOTA_DRIVERS_MEM=$((GPU_NUM_DISPATCHERS * GPU_QUOTA_DRIVERS_MEM))
readonly GPU_TOTAL_QUOTA_DRIVERS_GPUS=$((GPU_NUM_DISPATCHERS * GPU_QUOTA_DRIVERS_GPUS))
readonly GPU_TOTAL_QUOTA_EXECUTORS_CPUS=$((GPU_NUM_DISPATCHERS * GPU_QUOTA_EXECUTORS_CPUS))
readonly GPU_TOTAL_QUOTA_EXECUTORS_MEM=$((GPU_NUM_DISPATCHERS * GPU_QUOTA_EXECUTORS_MEM))
readonly GPU_TOTAL_QUOTA_EXECUTORS_GPUS=$((GPU_NUM_DISPATCHERS * GPU_QUOTA_EXECUTORS_GPUS))

readonly NON_GPU_QUOTA_CPUS=$((NON_GPU_TOTAL_QUOTA_DRIVERS_CPUS + NON_GPU_TOTAL_QUOTA_EXECUTORS_CPUS))
readonly NON_GPU_QUOTA_MEM=$((NON_GPU_TOTAL_QUOTA_DRIVERS_MEM + NON_GPU_TOTAL_QUOTA_EXECUTORS_MEM))
readonly GPU_QUOTA_CPUS=$((GPU_TOTAL_QUOTA_DRIVERS_CPUS + GPU_TOTAL_QUOTA_EXECUTORS_CPUS))
readonly GPU_QUOTA_MEM=$((GPU_TOTAL_QUOTA_DRIVERS_MEM + GPU_TOTAL_QUOTA_EXECUTORS_MEM))

echo
echo    "Test '${TEST_NAME}' parameters:"
echo
echo    "KAFKA_CLUSTER_COUNT: ${KAFKA_CLUSTER_COUNT}"
echo    "CASSANDRA_CLUSTER_COUNT: ${CASSANDRA_CLUSTER_COUNT}"
echo
echo    "NON_GPU_NUM_DISPATCHERS: ${NON_GPU_NUM_DISPATCHERS}"
echo    " Quota cpus/mem:"
echo -n "   Each:"
echo -n " driver ${NON_GPU_QUOTA_DRIVERS_CPUS}/${NON_GPU_QUOTA_DRIVERS_MEM},"
echo    " executor ${NON_GPU_QUOTA_EXECUTORS_CPUS}/${NON_GPU_QUOTA_EXECUTORS_MEM}"
echo -n "   Total:"
echo -n " driver ${NON_GPU_TOTAL_QUOTA_DRIVERS_CPUS}/${NON_GPU_TOTAL_QUOTA_DRIVERS_MEM},"
echo    " executor ${NON_GPU_TOTAL_QUOTA_EXECUTORS_CPUS}/${NON_GPU_TOTAL_QUOTA_EXECUTORS_MEM}"
echo
echo    "GPU_NUM_DISPATCHERS: ${GPU_NUM_DISPATCHERS}"
echo    " Quota cpus/mem/gpus:"
echo -n "   Each:"
echo -n " driver ${GPU_QUOTA_DRIVERS_CPUS}/${GPU_QUOTA_DRIVERS_MEM}/${GPU_QUOTA_DRIVERS_GPUS:--},"
echo    " executor ${GPU_QUOTA_EXECUTORS_CPUS:--}/${GPU_QUOTA_EXECUTORS_MEM:--}/${GPU_QUOTA_EXECUTORS_GPUS:--}"
echo -n "   Total:"
echo -n " driver ${GPU_TOTAL_QUOTA_DRIVERS_CPUS:--}/${GPU_TOTAL_QUOTA_DRIVERS_MEM:--}/${GPU_TOTAL_QUOTA_DRIVERS_GPUS:--},"
echo    " executor ${GPU_TOTAL_QUOTA_EXECUTORS_CPUS:--}/${GPU_TOTAL_QUOTA_EXECUTORS_MEM:--}/${GPU_TOTAL_QUOTA_EXECUTORS_GPUS:--}"
echo
echo    "FINITE_NUM_JOBS:       ${FINITE_NUM_JOBS}"
echo    "INFINITE_NUM_JOBS:     ${INFINITE_NUM_JOBS}"
echo    "STREAMING_NUM_JOBS:    ${STREAMING_NUM_JOBS}"
echo    "BATCH_SUBMITS_PER_MIN: ${BATCH_SUBMITS_PER_MIN}"
echo    "GPU_SUBMITS_PER_MIN:   ${GPU_SUBMITS_PER_MIN}"
echo
echo "Total CPU quota: $((NON_GPU_QUOTA_CPUS + GPU_QUOTA_CPUS))"
echo "Total MEM quota: $((NON_GPU_QUOTA_MEM + GPU_QUOTA_MEM))"
echo

echo "Existing S3 artifacts for ${TEST_NAME}:"
container_exec \
  aws s3 ls --recursive "${TEST_S3_DIRECTORY_URL}" || true

echo
read -p "Proceed? [y/N]: " ANSWER
case "${ANSWER}" in
  [Yy]* ) ;;
  * )     log 'Exiting...' && exit 0;;
esac

if is_interactive; then
  for boolean_option in SHOULD_INSTALL_INFRASTRUCTURE \
                          SHOULD_INSTALL_NON_GPU_DISPATCHERS \
                          SHOULD_INSTALL_GPU_DISPATCHERS \
                          SHOULD_RUN_FAILING_STREAMING_JOBS \
                          SHOULD_RUN_FINITE_STREAMING_JOBS \
                          SHOULD_RUN_INFINITE_STREAMING_JOBS \
                          SHOULD_RUN_BATCH_JOBS \
                          SHOULD_RUN_GPU_BATCH_JOBS \
                          SHOULD_UNINSTALL_INFRASTRUCTURE_AT_THE_END; do
    echo
    read -p "${boolean_option}? [y/N]: " ANSWER
    case "${ANSWER}" in
      [Yy]* ) eval "${boolean_option}"=true;;
      * )     eval "${boolean_option}"=false;;
    esac
  done
fi

set +e
docker inspect -f {{.State.Running}} "${CONTAINER_NAME}" > /dev/null 2>&1
readonly container_running=$?

docker exec -it "${CONTAINER_NAME}" test -f "${CONTAINER_FINISHED_SETTING_UP_FILE}"
readonly container_finished_setting_up=$?
set -e

if [ ${container_running} -ne 0 ] || [ ${container_finished_setting_up} -ne 0 ]; then
  log "Building Docker image for ${TEST_NAME}"

  log "Cleaning up possibly pre-existing containers"
  docker kill "${CONTAINER_NAME}" > /dev/null 2>&1 || true
  docker rm -f "${CONTAINER_NAME}" > /dev/null 2>&1 || true

  rm -rf "${TEST_REPOSITORY_DIRECTORY}"
  git clone git@github.com:mesosphere/spark-build.git "${TEST_REPOSITORY_DIRECTORY}" | tee -a "${LOG_FILE}"

  docker build -t "${IMAGE_NAME}" "${TEST_REPOSITORY_DIRECTORY}/scale-tests" | tee -a "${LOG_FILE}"

  docker run \
    --rm \
    -it \
    -d \
    --name="${CONTAINER_NAME}" \
    --net=host \
    -v "$(pwd):/spark-build" \
    -v "${CLUSTER_SSH_KEY}:${CONTAINER_SSH_KEY}:ro" \
    -v "${HOME}/.aws/credentials:/root/.aws/credentials:ro" \
    -e AWS_PROFILE="${AWS_PROFILE}" \
    -e SECURITY="${SECURITY}" \
    "${IMAGE_NAME}" \
    bash | tee -a "${LOG_FILE}"

  # This circumvents a warning shown due to container_exec running with a login bash shell.
  docker exec "${CONTAINER_NAME}" \
    bash -c 'sed -i "/mesg/d" ~/.profile' | tee -a "${LOG_FILE}"

  docker exec "${CONTAINER_NAME}" \
    bash -c "ssh-agent | grep -v echo > ${CONTAINER_SSH_AGENT_EXPORTS}" | tee -a "${LOG_FILE}"

  docker exec "${CONTAINER_NAME}" \
    bash -c "echo source ${CONTAINER_SSH_AGENT_EXPORTS} >> ~/.profile" | tee -a "${LOG_FILE}"

  container_exec \
    ssh-add -k "${CONTAINER_SSH_KEY}"

  container_exec \
    dcos cluster setup \
      --insecure \
      --username="${DCOS_USERNAME}" \
      --password="${DCOS_PASSWORD}" \
      "${CLUSTER_URL}"

  # This will refresh the DC/OS CLI authentication periodically in the background.
  docker exec -d "${CONTAINER_NAME}" \
    bash -c "while sleep ${DCOS_CLI_REFRESH_INTERVAL_SEC}; do
      date
      echo 'Refreshing DC/OS CLI authentication (interval: ${DCOS_CLI_REFRESH_INTERVAL_SEC}s)'
      dcos auth login --username=${DCOS_USERNAME} --password=${DCOS_PASSWORD}
      echo
    done | tee -a /tmp/dcos-auth-login-refresh.log" | tee -a "${LOG_FILE}"

  container_exec \
    dcos package install --yes dcos-enterprise-cli

  if [ -n "${ZOOKEEPER_PACKAGE_REPO}" ]; then
    container_exec \
      dcos package repo add --index=0 zk-aws "${ZOOKEEPER_PACKAGE_REPO}" || true
  fi
  if [ -n "${KAFKA_PACKAGE_REPO}" ]; then
    container_exec \
      dcos package repo add --index=0 kafka-aws "${KAFKA_PACKAGE_REPO}" || true
  fi
  if [ -n "${CASSANDRA_PACKAGE_REPO}" ]; then
    container_exec \
      dcos package repo add --index=0 cassandra-aws "${CASSANDRA_PACKAGE_REPO}" || true
  fi
  if [ -n "${SPARK_PACKAGE_REPO}" ]; then
    container_exec \
      dcos package repo add --index=0 spark-aws "${SPARK_PACKAGE_REPO}" || true
  fi

  container_exec \
    touch "${CONTAINER_FINISHED_SETTING_UP_FILE}"
fi

if [ "${SHOULD_INSTALL_INFRASTRUCTURE}" = true ]; then
  log 'Installing infrastructure'
  start_time=$(date +%s)
  container_exec \
    ./scale-tests/setup_streaming.py "${TEST_DIRECTORY}/${INFRASTRUCTURE_OUTPUT_FILE}" \
      --service-names-prefix "${SERVICE_NAMES_PREFIX}" \
      --kafka-zookeeper-config "${KAFKA_ZOOKEEPER_CONFIG}" \
      --kafka-cluster-count "${KAFKA_CLUSTER_COUNT}" \
      --kafka-config "${KAFKA_CONFIG}" \
      --cassandra-cluster-count "${CASSANDRA_CLUSTER_COUNT}" \
      --cassandra-config "${CASSANDRA_CONFIG}"
  end_time=$(date +%s)
  runtime=$(($end_time - $start_time))
  log "Installed infrastructure in ${runtime} seconds"

  log 'Uploading infrastructure file to S3'
  container_exec \
    aws s3 cp --acl public-read \
      "${TEST_DIRECTORY}/${INFRASTRUCTURE_OUTPUT_FILE}" \
      "${TEST_S3_DIRECTORY_URL}"
else
  log 'Skipping infrastructure installation'
fi

if [ "${SHOULD_INSTALL_NON_GPU_DISPATCHERS}" = true ]; then
  log 'Installing non-GPU dispatchers'
  start_time=$(date +%s)
  container_exec \
    ./scale-tests/deploy-dispatchers.py \
      --quota-drivers-cpus "${NON_GPU_QUOTA_DRIVERS_CPUS}" \
      --quota-drivers-mem "${NON_GPU_QUOTA_DRIVERS_MEM}" \
      --quota-executors-cpus "${NON_GPU_QUOTA_EXECUTORS_CPUS}" \
      --quota-executors-mem "${NON_GPU_QUOTA_EXECUTORS_MEM}" \
      "${NON_GPU_NUM_DISPATCHERS}" \
      "${SERVICE_NAMES_PREFIX}" \
      "${TEST_DIRECTORY}/${NON_GPU_DISPATCHERS_OUTPUT_FILE}"
  end_time=$(date +%s)
  runtime=$(($end_time - $start_time))
  log "Installed non-GPU dispatchers in ${runtime} seconds"

  log 'Uploading non-GPU dispatcher list to S3'
  container_exec \
    aws s3 cp --acl public-read \
      "${TEST_DIRECTORY}/${NON_GPU_DISPATCHERS_OUTPUT_FILE}" \
      "${TEST_S3_DIRECTORY_URL}"

  log 'Uploading non-GPU JSON dispatcher list to S3'
  container_exec \
    aws s3 cp --acl public-read \
      "${TEST_DIRECTORY}/${NON_GPU_DISPATCHERS_JSON_OUTPUT_FILE}" \
      "${TEST_S3_DIRECTORY_URL}"
else
  log 'Skipping non-GPU dispatchers installation'
fi

if [ "${SHOULD_INSTALL_GPU_DISPATCHERS}" = true ]; then
  log 'Installing GPU dispatchers'
  start_time=$(date +%s)
  container_exec \
    ./scale-tests/deploy-dispatchers.py \
      --quota-drivers-cpus "${GPU_QUOTA_DRIVERS_CPUS}" \
      --quota-drivers-mem "${GPU_QUOTA_DRIVERS_MEM}" \
      "${GPU_NUM_DISPATCHERS}" \
      "${SERVICE_NAMES_PREFIX}gpu-" \
      "${TEST_DIRECTORY}/${GPU_DISPATCHERS_OUTPUT_FILE}"
  end_time=$(date +%s)
  runtime=$(($end_time - $start_time))
  log "Installed GPU dispatchers in ${runtime} seconds"

  if [ "${GPU_REMOVE_EXECUTORS_ROLES_QUOTAS}" = true ]; then
    log 'Removing GPU executors roles quotas'
    last_gpu_index=$(($GPU_NUM_DISPATCHERS - 1))
    for i in $(seq 0 "${last_gpu_index}"); do
      container_exec \
        dcos spark quota remove "${TEST_NAME}__gpu-spark-0${i}-executors-role"
    done
  fi

  log 'Uploading GPU dispatcher list to S3'
  container_exec \
    aws s3 cp --acl public-read \
      "${TEST_DIRECTORY}/${GPU_DISPATCHERS_OUTPUT_FILE}" \
      "${TEST_S3_DIRECTORY_URL}"

  log 'Uploading GPU JSON dispatcher list to S3'
  container_exec \
    aws s3 cp --acl public-read \
      "${TEST_DIRECTORY}/${GPU_DISPATCHERS_JSON_OUTPUT_FILE}" \
      "${TEST_S3_DIRECTORY_URL}"
else
  log 'Skipping GPU dispatchers installation'
fi

if [[ -s ${TEST_DIRECTORY}/${NON_GPU_DISPATCHERS_JSON_OUTPUT_FILE} && -s ${TEST_DIRECTORY}/${GPU_DISPATCHERS_JSON_OUTPUT_FILE} ]]; then
  log 'Merging non-GPU and GPU dispatcher list files'
  container_exec "\
    jq -s \
      '{spark: (.[0].spark + .[1].spark)}' \
      ${TEST_DIRECTORY}/${NON_GPU_DISPATCHERS_JSON_OUTPUT_FILE} \
      ${TEST_DIRECTORY}/${GPU_DISPATCHERS_JSON_OUTPUT_FILE} \
      > ${TEST_DIRECTORY}/${DISPATCHERS_JSON_OUTPUT_FILE} \
  "

  log 'Uploading merged dispatcher list file'
  container_exec \
    aws s3 cp --acl public-read \
      "${TEST_DIRECTORY}/${DISPATCHERS_JSON_OUTPUT_FILE}" \
      "${TEST_S3_DIRECTORY_URL}"
else
  log 'Skipping merging of non-GPU and GPU dispatcher list files'
fi

if [ "${SHOULD_RUN_FAILING_STREAMING_JOBS}" = true ]; then
  log 'Starting failing jobs'
  start_time=$(date +%s)
  container_exec \
    ./scale-tests/kafka_cassandra_streaming_test.py \
      "${TEST_DIRECTORY}/${NON_GPU_DISPATCHERS_JSON_OUTPUT_FILE}" \
      "${TEST_DIRECTORY}/${INFRASTRUCTURE_OUTPUT_FILE}" \
      "${TEST_DIRECTORY}/${FAILING_SUBMISSIONS_OUTPUT_FILE}" \
      --spark-executor-docker-image \""${SPARK_EXECUTOR_DOCKER_IMAGE}"\" \
      --jar "${TEST_ASSEMBLY_JAR_URL}" \
      --num-producers-per-kafka "${FAILING_NUM_PRODUCERS_PER_KAFKA}" \
      --num-consumers-per-producer "${FAILING_NUM_CONSUMERS_PER_PRODUCER}" \
      --producer-must-fail \
      --producer-number-of-words "${FAILING_PRODUCER_NUMBER_OF_WORDS}" \
      --producer-words-per-second "${FAILING_PRODUCER_WORDS_PER_SECOND}" \
      --producer-spark-cores-max "${FAILING_PRODUCER_SPARK_CORES_MAX}" \
      --producer-spark-executor-cores "${FAILING_PRODUCER_SPARK_EXECUTOR_CORES}" \
      --consumer-must-fail \
      --consumer-write-to-cassandra \
      --consumer-batch-size-seconds "${FAILING_CONSUMER_BATCH_SIZE_SECONDS}" \
      --consumer-spark-cores-max "${FAILING_CONSUMER_SPARK_CORES_MAX}" \
      --consumer-spark-executor-cores "${FAILING_CONSUMER_SPARK_EXECUTOR_CORES}"
  end_time=$(date +%s)
  runtime=$(($end_time - $start_time))
  log "Started failing jobs in ${runtime} seconds"

  log 'Uploading failing jobs submissions file'
  container_exec \
    aws s3 cp --acl public-read \
      "${TEST_DIRECTORY}/${FAILING_SUBMISSIONS_OUTPUT_FILE}" \
      "${TEST_S3_DIRECTORY_URL}"
else
  log 'Skipping running of failing streaming jobs'
fi

if [ "${SHOULD_RUN_FINITE_STREAMING_JOBS}" = true ]; then
  log 'Starting finite jobs. Consumers write to Cassandra'
  start_time=$(date +%s)
  container_exec \
    ./scale-tests/kafka_cassandra_streaming_test.py \
      "${TEST_DIRECTORY}/${NON_GPU_DISPATCHERS_JSON_OUTPUT_FILE}" \
      "${TEST_DIRECTORY}/${INFRASTRUCTURE_OUTPUT_FILE}" \
      "${TEST_DIRECTORY}/${FINITE_SUBMISSIONS_OUTPUT_FILE}" \
      --spark-executor-docker-image \""${SPARK_EXECUTOR_DOCKER_IMAGE}"\" \
      --jar "${TEST_ASSEMBLY_JAR_URL}" \
      --num-producers-per-kafka "${FINITE_NUM_PRODUCERS_PER_KAFKA}" \
      --num-consumers-per-producer "${FINITE_NUM_CONSUMERS_PER_PRODUCER}" \
      --producer-number-of-words "${FINITE_PRODUCER_NUMBER_OF_WORDS}" \
      --producer-words-per-second "${FINITE_PRODUCER_WORDS_PER_SECOND}" \
      --producer-spark-cores-max "${FINITE_PRODUCER_SPARK_CORES_MAX}" \
      --producer-spark-executor-cores "${FINITE_PRODUCER_SPARK_EXECUTOR_CORES}" \
      --consumer-write-to-cassandra \
      --consumer-batch-size-seconds "${FINITE_CONSUMER_BATCH_SIZE_SECONDS}" \
      --consumer-spark-cores-max "${FINITE_CONSUMER_SPARK_CORES_MAX}" \
      --consumer-spark-executor-cores "${FINITE_CONSUMER_SPARK_EXECUTOR_CORES}"
  end_time=$(date +%s)
  runtime=$(($end_time - $start_time))
  log "Started finite jobs in ${runtime} seconds"

  log 'Uploading finite jobs submissions file'
  container_exec \
    aws s3 cp --acl public-read \
      "${TEST_DIRECTORY}/${FINITE_SUBMISSIONS_OUTPUT_FILE}" \
      "${TEST_S3_DIRECTORY_URL}"
else
  log 'Skipping running of finite streaming jobs'
fi

if [ "${SHOULD_RUN_INFINITE_STREAMING_JOBS}" = true ]; then
  log 'Starting infinite jobs. Consumers do not write to Cassandra'
  start_time=$(date +%s)
  container_exec \
    ./scale-tests/kafka_cassandra_streaming_test.py \
      "${TEST_DIRECTORY}/${NON_GPU_DISPATCHERS_JSON_OUTPUT_FILE}" \
      "${TEST_DIRECTORY}/${INFRASTRUCTURE_OUTPUT_FILE}" \
      "${TEST_DIRECTORY}/${INFINITE_SUBMISSIONS_OUTPUT_FILE}" \
      --spark-executor-docker-image \""${SPARK_EXECUTOR_DOCKER_IMAGE}"\" \
      --jar "${TEST_ASSEMBLY_JAR_URL}" \
      --num-producers-per-kafka "${INFINITE_NUM_PRODUCERS_PER_KAFKA}" \
      --num-consumers-per-producer "${INFINITE_NUM_CONSUMERS_PER_PRODUCER}" \
      --producer-number-of-words 0 \
      --producer-words-per-second "${INFINITE_PRODUCER_WORDS_PER_SECOND}" \
      --producer-spark-cores-max "${INFINITE_PRODUCER_SPARK_CORES_MAX}" \
      --producer-spark-executor-cores "${INFINITE_PRODUCER_SPARK_EXECUTOR_CORES}" \
      --consumer-batch-size-seconds "${INFINITE_CONSUMER_BATCH_SIZE_SECONDS}" \
      --consumer-spark-cores-max "${INFINITE_CONSUMER_SPARK_CORES_MAX}" \
      --consumer-spark-executor-cores "${INFINITE_CONSUMER_SPARK_EXECUTOR_CORES}"
  end_time=$(date +%s)
  runtime=$(($end_time - $start_time))
  log "Started infinite jobs in ${runtime} seconds"

  log 'Uploading infinite jobs submissions file'
  container_exec \
    aws s3 cp --acl public-read \
      "${TEST_DIRECTORY}/${INFINITE_SUBMISSIONS_OUTPUT_FILE}" \
      "${TEST_S3_DIRECTORY_URL}"
else
  log 'Skipping running of infinite streaming jobs'
fi

if [ "${SHOULD_RUN_BATCH_JOBS}" = true ]; then
  log 'Starting batch jobs'
  start_time=$(date +%s)
  container_exec \
    ./scale-tests/deploy-batch-marathon-app.py \
      --app-id "${BATCH_APP_ID}" \
      --dcos-username "${DCOS_USERNAME}" \
      --dcos-password "${DCOS_PASSWORD}" \
      --security "${SECURITY}" \
      --input-file-uri "${NON_GPU_DISPATCHERS_JSON_OUTPUT_FILE_URL}" \
      --script-cpus "${BATCH_SCRIPT_CPUS}" \
      --script-mem "${BATCH_SCRIPT_MEM}" \
      --spark-build-branch "${BATCH_SPARK_BUILD_BRANCH}" \
      --script-args "\"\
        ${NON_GPU_DISPATCHERS_JSON_OUTPUT_FILE} \
        --submits-per-min ${BATCH_SUBMITS_PER_MIN} \
      \""
  end_time=$(date +%s)
  runtime=$(($end_time - $start_time))
  log "Started batch jobs in ${runtime} seconds"
else
  log 'Skipping running of batch jobs'
fi

if [ "${SHOULD_RUN_GPU_BATCH_JOBS}" = true ]; then
  log 'Starting GPU batch jobs'
  start_time=$(date +%s)
  container_exec \
    ./scale-tests/deploy-batch-marathon-app.py \
      --app-id "${GPU_APP_ID}" \
      --dcos-username "${DCOS_USERNAME}" \
      --dcos-password "${DCOS_PASSWORD}" \
      --security "${SECURITY}" \
      --input-file-uri "${GPU_DISPATCHERS_JSON_OUTPUT_FILE_URL}" \
      --script-cpus "${GPU_SCRIPT_CPUS}" \
      --script-mem "${GPU_SCRIPT_MEM}" \
      --spark-build-branch "${GPU_SPARK_BUILD_BRANCH}" \
      --script-args "\"\
        ${GPU_DISPATCHERS_JSON_OUTPUT_FILE} \
        --submits-per-min ${GPU_SUBMITS_PER_MIN} \
        --docker-image ${GPU_DOCKER_IMAGE} \
        --max-num-dispatchers ${GPU_MAX_NUM_DISPATCHERS} \
        --spark-cores-max ${GPU_SPARK_CORES_MAX} \
        --spark-mesos-executor-gpus ${GPU_SPARK_MESOS_EXECUTOR_GPUS} \
        --spark-mesos-max-gpus ${GPU_SPARK_MESOS_MAX_GPUS} \
      \""
  end_time=$(date +%s)
  runtime=$(($end_time - $start_time))
  log "Started GPU batch jobs in ${runtime} seconds"
else
  log 'Skipping running of GPU batch jobs'
fi

if [ "${SHOULD_UNINSTALL_INFRASTRUCTURE_AT_THE_END}" = true ]; then
  log 'Uninstalling infrastructure'
  start_time=$(date +%s)
  container_exec \
    ./scale-tests/setup_streaming.py "${TEST_DIRECTORY}/${INFRASTRUCTURE_OUTPUT_FILE}" --cleanup
  end_time=$(date +%s)
  runtime=$(($end_time - $start_time))
  log "Uninstalled infrastructure in ${runtime} seconds"
else
  log 'Skipping uninstalling of infrastructure'
fi

log 'Uploading log file to S3'
container_exec \
  aws s3 cp --acl public-read \
    "${LOG_FILE}" \
    "${TEST_S3_DIRECTORY_URL}script_logs/"

log 'Listing S3 artifacts'
container_exec \
  aws s3 ls --recursive "${TEST_S3_DIRECTORY_URL}"

log "Test output files can also be found under ${TEST_DIRECTORY}"
ls "${TEST_DIRECTORY}"
