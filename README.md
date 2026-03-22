# ![apache-flink-logo](docs/images/apache-flink_squirrel-logo.png) Apache Flink Kickstarter II **[UNDER CONSTRUCTION]**

**Apache Flink Kickstarter II** is the 2026 evolution of my original Kickstarter project; rebuilt to showcase the cutting edge of **Apache Flink 2.1.x**.

Designed as a hands-on, production-minded accelerator, it brings Flink to life _locally_ on **Confluent Platform + Minikube**, while drawing direct comparisons to **Confluent Cloud for Apache Flink**--so you can clearly see what’s possible across environments.

Every **example** is delivered end-to-end--from schema design to fully operational streaming pipelines--with implementations in **both Java and Python** where it matters, bridging real-world developer workflows with modern streaming architecture.

**Table of Contents**
<!-- toc -->
+ [**1.0 Prerequisites**](#10-prerequisites)
+ [**2.0 Deploy the Platform**](#20-deploy-the-platform)
  - [**2.1 Stand up Confluent Platform**](#21-stand-up-confluent-platform)
  - [**2.2 Stand up Apache Flink + CMF**](#22-stand-up-apache-flink--cmf)
+ [**3.0 The Examples**](#30-the-examples)
+ [**4.0 Teardown**](#40-teardown)
+ [**5.0 Documentation**](#50-documentation)
+ [**6.0 Resources**](#60-resources)
<!-- tocstop -->
---

## **1.0 Prerequisites**

macOS with Homebrew and Docker Desktop running.

```bash
make install-prereqs   # installs docker, kubectl, minikube, helm, gradle, envsubst
```

## **2.0 Deploy the Platform**

Follow the [Minikube Deployment Guide](docs/minikube-deployment.md) for the full reference on all Make targets, configuration variables, and architecture details.

The short version:

### **2.1 Stand up Confluent Platform**

```bash
make cp-up             # Minikube → CFK Operator → Kafka (KRaft) + SR + Connect + ksqlDB + C3 + Kafka UI
make cp-watch          # watch pods come up (Ctrl+C when all Running)
```

### **2.2 Stand up Apache Flink + CMF**

```bash
make flink-up          # cert-manager → Flink Operator → CMF → Flink session cluster
make flink-status      # verify Flink pods are Running
```

## **3.0 The Examples**

Once the platform is up, head to the examples:

| Example Type | Example Description | Confluent Platform + Minikube | Confluent Cloud |
| --- | --- | --- | --- |
| PTF UDF | Walks through building, deploying, and testing a stateful **ProcessTableFunction** that enriches Kafka events with per-user session tracking. | [examples/ptf_udf/cp_java/README.md](examples/ptf_udf/cp_java/README.md) | [examples/ptf_udf/cc_java/README.md](examples/ptf_udf/cc_java/README.md) |

## **4.0 Teardown**

```bash
make confluent-teardown   # removes everything and stops Minikube
```

---

## **5.0 Documentation**

- [Minikube Deployment Guide](docs/minikube-deployment.md) — full reference for all Make targets, configuration variables, and architecture diagrams

## **6.0 Resources**

- [Confluent Platform for Apache Flink](https://docs.confluent.io/platform/current/flink/get-started/overview.html)
- [Confluent for Kubernetes](https://docs.confluent.io/operator/current/co-manage-overview.html)
- [Flink Process Table Functions](https://nightlies.apache.org/flink/flink-docs-release-2.1/docs/dev/table/functions/processtablefunctions/)
