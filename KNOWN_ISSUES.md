# Known Issues
All known release issues related to this project will be documented in this file.

> _If you have a known issue that is not listed here, please open an issue on the project's GitHub repository._

## `ArgumentTrait.REQUIRE_ON_TIME` Not Supported in Confluent Cloud Early Access
In the latest release of Confluent Cloud early access, the `ArgumentTrait.REQUIRE_ON_TIME` trait is not functioning correctly within the `session_timeout_detector` function. This trait was originally designed to enforce that SQL queries using the function include an `on_time` descriptor, which is essential for the proper operation of the function's timer mechanics.

The `ArgumentTrait.REQUIRE_ON_TIME` trait serves as a SQL-level contract enforcement — it causes Flink's SQL planner to reject queries at parse time if the function omits the `on_time => DESCRIPTOR(...)` argument.

Without it, if you write:

```sql
SELECT * FROM TABLE(
    session_timeout_detector(
        input => TABLE user_activity PARTITION BY user_id
        -- oops, forgot on_time
    )
);
```

...the query would be accepted by the planner, but then fail at runtime when `ctx.timeContext()` has no time column to work with — a confusing error.

With `ArgumentTrait.REQUIRE_ON_TIME`, you'd get a clear, immediate error: "this function requires an on_time descriptor."

So the trait essentially functions as **documentation-as-enforcement** — it changes the failure from a cryptic runtime error to a clear validation error at query submission. The actual timer mechanics are still connected in `eval()` regardless.

Since Confluent Cloud doesn't support it yet, your SQL query should always include the `on_time => DESCRIPTOR(event_time)` argument by convention. This shifts the responsibility from the planner to the query writer.

The current solution is to ensure that all queries using `session_timeout_detector` include the `on_time` descriptor, and to recognize that the planner won’t detect missing `on_time` arguments until the trait is supported in Confluent Cloud. However, the function will still work as long as the `on_time` argument is included in the SQL query in both OSS Apache Flink, Confluent Platform, and Confluent Cloud.

[`PR #154`](https://github.com/j3-signalroom/apache_flink-kickstarter-ii/pull/154)
