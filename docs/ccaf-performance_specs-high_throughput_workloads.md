# Confluent Cloud for Apache Flink — Performance Specifications for High Throughput Workloads

**Table of Contents**
<!-- toc -->
+ [**1.0 Confluent Flink Units (CFUs)**](#10-confluent-flink-units-cfus)
+ [**2.0 Scaling & Parallelism**](#20-scaling--parallelism)
+ [**3.0 Documented Limits**](#30-documented-limits)
+ [**4.0 Latency & Delivery Guarantees**](#40-latency--delivery-guarantees)
+ [**5.0 Best Practices for High Throughput**](#50-best-practices-for-high-throughput)
+ [**6.0 Private Networking**](#60-private-networking)
+ [**7.0 CCAF PTF UDF Example Performance Notes**](#70-ccaf-ptf-udf-example-performance-notes)
<!-- tocstop -->

## **1.0 Confluent Flink Units (CFUs)**

A **CFU** is the logical unit of processing power in Confluent Cloud for Flink. Key points:

- Each SQL statement consumes a **minimum of 1 CFU-minute**, scaling with workload complexity and input throughput.
- Confluent does **not** publish a direct CFU-to-physical-resource mapping — the platform auto-provisions infrastructure.
- **Pricing**: ~$0.21 per CFU-hour. You pay only for active processing time.
- Up to **4 UDF instances** can consolidate into a single CFU.

---

## **2.0 Scaling & Parallelism**

**Flink SQL Autopilot** automatically manages scaling by monitoring a "Messages Behind" metric (Kafka consumer lag) and adjusting parallelism per statement.

| Pool Type | Max CFUs |
|---|---|
| Standard compute pool | **50 CFUs** |
| Limited Availability program | **1,000 CFUs** |
| Per-statement maximum | **50 CFUs** (regardless of pool size) |

Pools scale down to **zero** when idle. For higher aggregate throughput, distribute statements across **multiple compute pools**.

---

## **3.0 Documented Limits**

| Limit | Value |
|---|---|
| Max CFUs per pool (standard) | 50 |
| Max CFUs per pool (LA program) | 1,000 |
| Max CFUs per statement | 50 |
| Query text size | 4 MB |
| State size soft limit per statement | 500 GB |
| State size hard limit per statement | 1,000 GB (exceeding = permanent failure) |
| Target state per task manager | ~10 GB |

---

## **4.0 Latency & Delivery Guarantees**

- **Exactly-once**: ~1 minute end-to-end latency (Kafka transaction commit intervals). Requires `isolation.level: read_committed`.
- **At-least-once**: Sub-100ms latency achievable with `isolation.level: read_uncommitted` (trade-off: possible duplicates).

---

## **5.0 Best Practices for High Throughput**

1. [**Use the Query Profiler**](https://docs.confluent.io/cloud/current/flink/operate-and-deploy/query-profiler.html) — real-time dashboard showing backpressure, busyness, data skew, and per-operator metrics
2. **Monitor data skew** — uneven partition distribution limits effective parallelism
3. **Increase MAX_CFU** on the compute pool so Autopilot can scale up bottleneck tasks
4. **Isolate workloads** — use separate compute pools for different priorities
5. **Optimize expensive operations** — regex, complex JSON parsing, and large UNNESTs are common bottlenecks
6. **Partition strategy** — distribute messages evenly across topic partitions
7. **Use lz4 compression** over gzip for best throughput

---

## **6.0 Private Networking**

- Cross-cluster, cross-environment queries supported **within the same region**
- Cross-region queries are **not supported**
- Private networking via PrivateLink, VPC peering, Transit Gateway on AWS/Azure/GCP

---

## **7.0 CCAF PTF UDF Example Performance Notes**

In `setup-confluent-flink.tf`, your compute pool is set to `max_cfu = 10`. For high throughput production workloads, you may want to increase this up to 50 (standard) or request access to the Limited Availability program for up to 1,000 CFUs.
