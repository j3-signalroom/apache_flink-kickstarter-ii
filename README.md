# Apache Flink Kickstarter II

A hands-on project for running **Apache Flink** on **Confluent Platform** locally using Minikube. Includes working examples of Flink's new APIs, starting with the **Process Table Function (PTF)**.

---

## Prerequisites

macOS with Homebrew and Docker Desktop running.

```bash
make install-prereqs   # installs docker, kubectl, minikube, helm, maven, envsubst
```

## Deploy the Platform

Follow the [Minikube Deployment Guide](docs/minikube-deployment.md) for the full reference on all Make targets, configuration variables, and architecture details.

The short version:

### 1. Stand up Confluent Platform

```bash
make cp-up             # Minikube → CFK Operator → Kafka (KRaft) + SR + Connect + ksqlDB + C3 + Kafka UI
make cp-watch          # watch pods come up (Ctrl+C when all Running)
```

### 2. Stand up Apache Flink + CMF

```bash
make flink-up          # cert-manager → Flink Operator → CMF → Flink session cluster
make flink-status      # verify Flink pods are Running
```

## Run Your First Example

Once the platform is up, head to the **PTF UDF** example:

> [cp_java_examples/ptf_udf/README.md](cp_java_examples/ptf_udf/README.md)

It walks through building, deploying, and testing a stateful **ProcessTableFunction** that enriches Kafka events with per-user session tracking. You can build and deploy it in one shot with:

```bash
make deploy-cp-java-ptf-udf   # build JAR → create topics → upload → submit job
```

Then produce sample data and consume the enriched output:

```bash
make produce-ptf-udf-sample       # send 6 test events to user-events
make consume-ptf-udf-output       # read enriched results from enriched-events (Ctrl+C to stop)
```

## Access the UIs

```bash
make c3-open           # Control Center   → http://localhost:9021
make flink-ui          # Flink Dashboard  → http://localhost:8081
make kafka-ui-open     # Kafka UI         → http://localhost:8080
make cmf-open          # CMF REST API     → http://localhost:8080
```

## Teardown

```bash
make confluent-teardown   # removes everything and stops Minikube
```

---

## Documentation

- [Minikube Deployment Guide](docs/minikube-deployment.md) — full reference for all Make targets, configuration variables, and architecture diagrams
- [Manual Deployment](docs/manual_deployment.md) — step-by-step instructions without the Makefile

## Resources

- [Confluent Platform for Apache Flink](https://docs.confluent.io/platform/current/flink/get-started/overview.html)
- [Confluent for Kubernetes](https://docs.confluent.io/operator/current/co-manage-overview.html)
- [Flink Process Table Functions](https://nightlies.apache.org/flink/flink-docs-release-2.1/docs/dev/table/functions/processtablefunctions/)
