#!/usr/bin/env python3

"""kafka_cassandra_streaming_test.py

Usage:
    ./kafka_cassandra_streaming_test.py <dispatcher_file> <infrastructure_file> <submissions_output_file> [options]

Arguments:
    dispatcher_file                     file path to dispatchers list
    infrastructure_file                 file path to infrastructure description
                                        (contains package names, service names
                                        and their configuration)
    submissions_output_file             file path to output `dispatcher name`,`submission ID` pairs

Options:
    --jar <URL>                         hosted JAR URL
    --num-producers-per-kafka <n>       number of producers per Kafka cluster to create [default: 1]
    --num-consumers-per-producer <n>    number of consumers for producer to create [default: 1]
    --producer-number-of-words <n>      number of total words published by producers [default: 1]
    --producer-words-per-second <n>     number of words per second published by producers [default: 1]
    --producer-spark-cores-max <n>      spark.cores.max [default: 2]
    --producer-spark-executor-cores <n> spark.executor.cores [default: 2]
    --producer-must-fail                the producer is passed an invalid command line argument causing it to fail [default: False]
    --consumer-batch-size-seconds <n>   number seconds accumulating entries for each batch request [default: 10]
    --consumer-write-to-cassandra       write to Cassandra [default: False]
    --consumer-spark-cores-max <n>      spark.cores.max [default: 1]
    --consumer-spark-executor-cores <n> spark.executor.cores [default: 1]
    --consumer-must-fail                the consumer is passed an invalid command line argument causing it to fail [default: False]
"""


import json
import logging
import math

from docopt import docopt

import sdk_cmd
import spark_utils
from scale_tests_utils import make_repeater, mapcat, normalize_string

log = logging.getLogger(__name__)
logging.basicConfig(level=logging.INFO, format="%(message)s")


DEFAULT_JAR = 'http://infinity-artifacts.s3.amazonaws.com/scale-tests/dcos-spark-scala-tests-assembly-20180523-fa29ab5.jar'
PRODUCER_CLASS_NAME = 'KafkaRandomFeeder'
CONSUMER_CLASS_NAME = 'KafkaWordCount'
SPARK_PACKAGE_NAME = 'spark'
COMMON_CONF = [
    "--conf", "spark.mesos.containerizer=mesos",
    "--conf", "spark.mesos.driver.failoverTimeout=30",
    "--conf", "spark.port.maxRetries=32",
    "--conf", "spark.mesos.executor.docker.image=mesosphere/spark-dev:7081f3483a0d904992994edbed07abbc5110f003-815904ac6c6604ac82368a44d69f8a7423bcb8dc",
    "--conf", "spark.mesos.executor.home=/opt/spark/dist",
    "--conf", "spark.scheduler.maxRegisteredResourcesWaitingTime=2400s",
    "--conf", "spark.scheduler.minRegisteredResourcesRatio=1.0"
]


def _install_package_cli(package_name):
    cmd = "package install {package_name} --yes --cli".format(package_name=package_name)
    rt, stdout, _ = sdk_cmd.run_raw_cli(cmd)
    assert rt == 0, "Failed to install CLI for {package_name}"


def _service_endpoint_dns(package_name, service_name, endpoint_name):
    cmd = "{package_name} --name={service_name} endpoints {endpoint_name}".format(
        package_name=package_name,
        service_name=service_name,
        endpoint_name=endpoint_name)
    rt, stdout, _ = sdk_cmd.run_raw_cli(cmd)
    assert rt == 0, "Failed to get {endpoint_name} endpoints"
    return json.loads(stdout)["dns"]


def _submit_producer(kafka_broker_dns,
                     service_name,
                     executor_role,
                     kafka_topics,
                     number_of_words,
                     words_per_second,
                     spark_cores_max,
                     spark_executor_cores,
                     must_fail: bool):
    app_args = ["--appName",        PRODUCER_CLASS_NAME,
                "--brokers",        ",".join(kafka_broker_dns),
                "--topics",         kafka_topics,
                "--numberOfWords",  str(number_of_words),
                "--wordsPerSecond", str(words_per_second)]

    if must_fail:
        app_args.extend(["--mustFailDueToInvalidArgument", ])

    app_config = ["--conf",  "spark.cores.max={}".format(spark_cores_max),
                  "--conf",  "spark.executor.cores={}".format(spark_executor_cores),
                  "--class", PRODUCER_CLASS_NAME]

    # `number_of_words == 0` means infinite stream, so we'd like to have it
    # restarted in the case of failures.
    if number_of_words == 0:
        app_config.extend(["--supervise"])

    args = app_config + COMMON_CONF

    submission_id = spark_utils.submit_job(
        app_url=jar,
        app_args=" ".join(str(a) for a in app_args),
        service_name=service_name,
        args=args,
        driver_role=executor_role,
        verbose=False)

    return submission_id


def _submit_consumer(kafka_broker_dns,
                     cassandra_native_client_dns,
                     service_name,
                     executor_role,
                     kafka_topics,
                     kafka_group_id,
                     write_to_cassandra,
                     batch_size_seconds,
                     cassandra_keyspace,
                     cassandra_table,
                     spark_cores_max,
                     spark_executor_cores,
                     must_fail: bool):
    app_args = ["--appName",           CONSUMER_CLASS_NAME,
                "--brokers",           ",".join(kafka_broker_dns),
                "--topics",            kafka_topics,
                "--groupId",           kafka_group_id,
                "--batchSizeSeconds",  str(batch_size_seconds),
                "--cassandraKeyspace", cassandra_keyspace,
                "--cassandraTable",    cassandra_table]

    if must_fail:
        app_args.extend(["--mustFailDueToInvalidArgument"])

    if not write_to_cassandra:
        app_args.extend(["--shouldNotWriteToCassandra"])

    cassandra_hosts = map(lambda x: x.split(':')[0], cassandra_native_client_dns)
    cassandra_port = cassandra_native_client_dns[0].split(':')[1]

    app_config = ["--supervise",
                  "--conf",      "spark.cores.max={}".format(spark_cores_max),
                  "--conf",      "spark.executor.cores={}".format(spark_executor_cores),
                  "--conf",      "spark.cassandra.connection.host={}".format(",".join(cassandra_hosts)),
                  "--conf",      "spark.cassandra.connection.port={}".format(cassandra_port),
                  "--class",     CONSUMER_CLASS_NAME]

    args = app_config + COMMON_CONF

    submission_id = spark_utils.submit_job(
        app_url=jar,
        app_args=" ".join(str(a) for a in app_args),
        service_name=service_name,
        args=args,
        driver_role=executor_role,
        verbose=False)

    return submission_id


def append_submission(output_file: str, dispatcher_service_name: str, submission_id: str):
    with open(output_file, "a") as f:
        f.write("{},{}\n".format(dispatcher_service_name, submission_id))


def parse_dispatcher(dispatcher):
    """Parses dispatcher entries, returns their attributes.
    """
    dispatcher_service_name, driver_role, executor_role = dispatcher.split(',')
    return dispatcher_service_name, driver_role, executor_role


class ProvidingStrategy(object):
    def __init__(self, dispatchers, num_jobs):
        self.dispatchers = dispatchers
        self.num_jobs = num_jobs
        self.slots = self.prepare()


    def prepare(self):
        raise NotImplementedError


    def provide(self):
        raise NotImplementedError


    def report(self):
        raise NotImplementedError


class BlockProvidingStrategy(ProvidingStrategy):
    """This strategy guarantees:

    - Roughly the same amount of jobs will be provided to each scheduler
    - Schedulers are "filled" serially. This increases the chance that related
      jobs will be assigned to the same scheduler.
    """

    def prepare(self):
        self.avg_num_jobs_per_dispatcher = self.num_jobs / len(self.dispatchers)
        self.max_num_jobs_per_dispatcher = math.ceil(self.avg_num_jobs_per_dispatcher)

        return mapcat(make_repeater(self.max_num_jobs_per_dispatcher),
                      self.dispatchers)


    def provide(self):
        return next(self.slots)


    def report(self):
        log.info('Providing strategy: block')
        log.info('Average number of jobs per dispatcher: %s', self.avg_num_jobs_per_dispatcher)
        log.info('Will run at most %s jobs per dispatcher', self.max_num_jobs_per_dispatcher)
        log.info("\nDispatchers: \n%s\n", "\n".join(dispatchers))


class DispatcherProvider(object):
    """Provides dispatchers for jobs in a given strategy.
    """
    def __init__(self, dispatchers, num_jobs, strategy=BlockProvidingStrategy):
        self.strategy = strategy(dispatchers, num_jobs)


    def provide(self):
        return self.strategy.provide()


    def report(self):
        return self.strategy.report()


if __name__ == "__main__":
    args = docopt(__doc__)

    with open(args["<dispatcher_file>"]) as f:
        dispatchers = f.read().splitlines()

    with open(args["<infrastructure_file>"]) as f:
        infrastructure = json.loads(f.read())
        kafkas = infrastructure['kafka']
        # Assuming only 1 Cassandra cluster.
        cassandra = infrastructure['cassandra'][0]

    jar                           = args["--jar"] if args["--jar"] else DEFAULT_JAR
    submissions_output_file       = args["<submissions_output_file>"]
    kafka_package_names           = map(lambda kafka: kafka['package_name'], kafkas)
    cassandra_package_name        = cassandra['package_name']
    cassandra_service_name        = cassandra['service']['name']
    cassandra_num_nodes           = cassandra['nodes']['count']
    num_producers_per_kafka       = int(args['--num-producers-per-kafka'])
    num_consumers_per_producer    = int(args['--num-consumers-per-producer'])
    producer_must_fail            = args['--producer-must-fail']
    producer_number_of_words      = int(args['--producer-number-of-words'])
    producer_words_per_second     = int(args['--producer-words-per-second'])
    producer_spark_cores_max      = int(args['--producer-spark-cores-max'])
    producer_spark_executor_cores = int(args['--producer-spark-executor-cores'])
    consumer_must_fail            = args['--consumer-must-fail']
    consumer_write_to_cassandra   = args['--consumer-write-to-cassandra']
    consumer_batch_size_seconds   = int(args['--consumer-batch-size-seconds'])
    consumer_spark_cores_max      = int(args['--consumer-spark-cores-max'])
    consumer_spark_executor_cores = int(args['--consumer-spark-executor-cores'])

    num_kafkas = len(kafkas)
    num_dispatchers = len(dispatchers)
    num_producers = num_kafkas * num_producers_per_kafka
    num_consumers = num_producers * num_consumers_per_producer
    num_jobs = num_producers + num_consumers

    dispatcher_provider = DispatcherProvider(dispatchers, num_jobs)

    log.info('Number of Kafka clusters: %s', num_kafkas)
    log.info('Number of dispatchers: %s', num_dispatchers)
    log.info('Total number of jobs: %s (%s producers, %s consumers)',
             num_jobs, num_producers, num_consumers)

    dispatcher_provider.report()

    for kafka_package_name in kafka_package_names:
        _install_package_cli(kafka_package_name)
    _install_package_cli(cassandra_package_name)
    _install_package_cli(SPARK_PACKAGE_NAME)

    cassandra_native_client_dns = _service_endpoint_dns(cassandra_package_name, cassandra_service_name, "native-client")

    for kafka in kafkas:
        kafka_package_name = kafka['package_name']
        kafka_service_name = kafka['service']['name']
        kafka_broker_dns = _service_endpoint_dns(kafka_package_name, kafka_service_name, 'broker')

        for producer_idx in range(0, num_producers_per_kafka):
            dispatcher_service_name, _, executor_role = parse_dispatcher(dispatcher_provider.provide())

            producer_name = '{}-{}'.format(normalize_string(kafka_service_name), producer_idx)
            kafka_topics = producer_name
            producer_cassandra_keyspace = normalize_string(producer_name)

            producer_submission_id = _submit_producer(
                kafka_broker_dns,
                dispatcher_service_name,
                executor_role,
                kafka_topics,
                producer_number_of_words,
                producer_words_per_second,
                producer_spark_cores_max,
                producer_spark_executor_cores,
                producer_must_fail)

            append_submission(
                submissions_output_file,
                dispatcher_service_name,
                producer_submission_id)

            for consumer_idx in range(0, num_consumers_per_producer):
                dispatcher_service_name, _, executor_role = parse_dispatcher(dispatcher_provider.provide())

                consumer_name = '{}-{}'.format(producer_name, consumer_idx)
                consumer_kafka_group_id = consumer_name
                consumer_cassandra_table = 'table_{}'.format(consumer_idx)

                consumer_submission_id = _submit_consumer(
                    kafka_broker_dns,
                    cassandra_native_client_dns,
                    dispatcher_service_name,
                    executor_role,
                    kafka_topics,
                    consumer_kafka_group_id,
                    consumer_write_to_cassandra,
                    consumer_batch_size_seconds,
                    producer_cassandra_keyspace,
                    consumer_cassandra_table,
                    consumer_spark_cores_max,
                    consumer_spark_executor_cores,
                    consumer_must_fail)

                append_submission(
                    submissions_output_file,
                    dispatcher_service_name,
                    consumer_submission_id)