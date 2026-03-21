/**
 * Copyright (c) 2026 Jeffrey Jonathan Jennings
 * 
 * @author Jeffrey Jonathan Jennings (J3)
 * 
 * 
 */
package ptf;

import org.apache.flink.configuration.ConfigOptions;
import org.apache.flink.table.api.EnvironmentSettings;
import org.apache.flink.table.api.TableEnvironment;

public class FlinkJob {

    private static final String DEFAULT_BOOTSTRAP_SERVERS = "localhost:9092";

    /**
     * Entry point for the Flink job that enriches user events using a Polymorphic Table
     * Function (PTF).  It sets up a streaming Table API environment, resolves the Kafka
     * bootstrap servers, registers the {@link UserEventEnricher} PTF, creates Kafka source
     * and sink tables, and executes a continuous SQL query that partitions incoming events
     * by {@code user_id} and writes the enriched results to an output topic.
     *
     * @param args command-line arguments (currently unused).
     * @throws Exception forwarded to the Flink runtime, which aborts the task and lets the
     *                   fail-over logic decide whether to retry execution.
     */
    public static void main(String[] args) throws Exception {

        TableEnvironment tEnv = TableEnvironment.create(
                EnvironmentSettings.inStreamingMode()
        );

        // Resolve bootstrap servers: env var → Flink config → default (localhost:9092)
        String bootstrapServers = System.getenv("KAFKA_BOOTSTRAP_SERVERS");
        if (bootstrapServers == null || bootstrapServers.isBlank()) {
            bootstrapServers = tEnv.getConfig().get(
                    ConfigOptions.key("kafka.bootstrap.servers")
                            .stringType()
                            .defaultValue(DEFAULT_BOOTSTRAP_SERVERS));
        }

        // --- Register the PTF under a SQL-callable name
        tEnv.createTemporarySystemFunction("UserEventEnricher", UserEventEnricher.class);

        // --- Source table
        tEnv.executeSql(String.format("""
            CREATE TABLE events (
                user_id    STRING,
                event_type STRING,
                payload    STRING
            ) WITH (
                'connector'                    = 'kafka',
                'topic'                        = 'user-events',
                'properties.bootstrap.servers' = '%s',
                'format'                       = 'json',
                'scan.startup.mode'            = 'latest-offset'
            )
        """, bootstrapServers));

        // --- Sink table
        tEnv.executeSql(String.format("""
            CREATE TABLE enriched_events (
                user_id     STRING,
                event_type  STRING,
                payload     STRING,
                session_id  BIGINT,
                event_count BIGINT,
                last_event  STRING
            ) WITH (
                'connector'                    = 'kafka',
                'topic'                        = 'enriched-events',
                'properties.bootstrap.servers' = '%s',
                'format'                       = 'json'
            )
        """, bootstrapServers));

        // --- Invoke the PTF from SQL
        tEnv.executeSql("""
            INSERT INTO enriched_events
            SELECT *
            FROM TABLE(
                UserEventEnricher(
                    input => TABLE events PARTITION BY user_id
                )
            )
        """);
    }
}