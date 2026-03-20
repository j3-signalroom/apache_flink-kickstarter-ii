package ptf;

import org.apache.flink.table.api.EnvironmentSettings;
import org.apache.flink.table.api.TableEnvironment;

public class FlinkJob {

    public static void main(String[] args) throws Exception {

        TableEnvironment tEnv = TableEnvironment.create(
                EnvironmentSettings.inStreamingMode()
        );

        // Register the PTF under a SQL-callable name
        tEnv.createTemporarySystemFunction("UserEventEnricher", UserEventEnricher.class);

        // Source table
        tEnv.executeSql("""
            CREATE TABLE events (
                user_id    STRING,
                event_type STRING,
                payload    STRING
            ) WITH (
                'connector'                    = 'kafka',
                'topic'                        = 'user-events',
                'properties.bootstrap.servers' = 'localhost:9092',
                'format'                       = 'json',
                'scan.startup.mode'            = 'latest-offset'
            )
        """);

        // Sink table
        tEnv.executeSql("""
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
                'properties.bootstrap.servers' = 'localhost:9092',
                'format'                       = 'json'
            )
        """);

        // Invoke the PTF from SQL
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