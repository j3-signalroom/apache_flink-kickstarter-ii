# Local Kafka Stack Quickstart: Confluent Platform, Kafka UI, and Apache Flink on Minikube
This tutorial provides a step-by-step guide to deploying the core components of the **Confluent Platform** with **Provectus' Kafka UI** and **Apache Flink** on a local Minikube Kubernetes cluster using **Confluent for Kubernetes (CFK)**, the **Provectus Kafka UI Helm chart**, and the **Flink Kubernetes Operator**.

By the end of this guide, you will have a fully functional **Confluent Platform** running in **KRaft mode (ZooKeeper-less Kafka)**, a browser-accessible **Kafka UI** for cluster visibility, and a **Flink session cluster** with its own UI, all running locally on Minikube. The guide also covers complete teardown procedures for each component.

The stack you will deploy includes:

- **Kafka (KRaft mode)** — brokers and controllers, no ZooKeeper
- **Schema Registry** — manages and enforces schemas for Kafka topics
- **Kafka Connect** — integrates Kafka with external systems
- **ksqlDB** — stream processing with SQL-like queries
- **REST Proxy** — provides a RESTful interface to Kafka
- **Control Center (C3)** — the Confluent monitoring UI
- **Provectus Kafka UI** — lightweight alternative UI for cluster inspection
- **Apache Flink** — session cluster via Flink Kubernetes Operator

---

**Table of Contents**
<!-- toc -->
- [**1.0 MacOS prerequisites setup**](#10-macos-prerequisites-setup)
  - [**1.1 Prerequisites**](#11-prerequisites)
  - [**1.2 Install Minikube**](#12-install-minikube)
  - [**1.3 Verify Installation**](#13-verify-installation)
  - [**1.4 Start Minikube**](#14-start-minikube)
- [**2.0 Startup the Confluent Operator (CFK)**](#20-startup-the-confluent-operator-cfk)
  - [**2.1 Create the Confluent namespace and set it as the default context for `kubectl`**](#21-create-the-confluent-namespace-and-set-it-as-the-default-context-for-kubectl)
  - [**2.2 Add the Confluent Helm repo and install the Confluent Operator**](#22-add-the-confluent-helm-repo-and-install-the-confluent-operator)
  - [**2.3 Verify the Operator is running**](#23-verify-the-operator-is-running)
- [**3.0 Deploy KRaft broker and controller with CFK**](#30-deploy-kraft-broker-and-controller-with-cfk)
  - [**3.1 Set the TUTORIAL_HOME environment variable**](#31-set-the-tutorial_home-environment-variable)
  - [**3.2 Apply the Confluent Platform manifest**](#32-apply-the-confluent-platform-manifest)
  - [**3.3 Verify the platform is running**](#33-verify-the-platform-is-running)
  - [**3.4 Access Control Center**](#34-access-control-center)
- [**4.0 Teardown the CP Core Components**](#40-teardown-the-cp-core-components)
- [**5.0 Deploy Provectus' Kafka UI**](#50-deploy-provectus-kafka-ui)
  + [**5.1 Add the Helm repo**](#51-add-the-helm-repo)
  + [**5.2 Install Kafka UI**](#52-install-kafka-ui)
  + [**5.3 Verify the installation**](#53-verify-the-installation)
  + [**5.4 Open the UI**](#54-open-the-ui)
- [**6.0 Teardown Kafka UI**](#60-teardown-kafka-ui)
- [**7.0 Deploy Apache Flink on Kubernetes with the Flink Operator**](#70-deploy-apache-flink-on-kubernetes-with-the-flink-operator)
  + [**7.1 Install cert-manager**](#71-install-cert-manager)
  + [**7.2 Install the Flink Kubernetes Operator**](#72-install-the-flink-kubernetes-operator)
  + [**7.3 Deploy the Flink session cluster**](#73-deploy-the-flink-session-cluster)
  + [**7.4 Verify**](#74-verify)
  + [**7.5 Open the Flink UI**](#75-open-the-flink-ui)
- [**8.0 Teardown Flink**](#80-teardown-flink)
  + [**8.1 Remove Flink cluster**](#81-remove-flink-cluster)
  + [**8.2 Remove Flink Operator**](#82-remove-flink-operator)
  + [**8.3 Remove cert-manager**](#83-remove-cert-manager)
- [**9.0 Glossary**](#90-glossary)
- [**10.0 Kubernetes Nautical Theme**](#100-kubernetes-nautical-theme)
<!-- tocstop -->

## **1.0 MacOS prerequisites setup**

### **1.1 Prerequisites**
Need a container driver running.  Docker Desktop is a good choice:
```bash
brew install --cask docker
```

Then launch Docker Desktop and make sure it's running before proceeding.

Install `kubectl`:
```bash
brew install kubectl
```

### **1.2 Install Minikube**
```bash
brew install minikube
```

If which minikube fails after install, relink it:
```bash
brew link --overwrite minikube
```

### **1.3 Verify Installation**
```bash
minikube version
```

### **1.4 Start Minikube**
CP is very memory and resource intensive, so we need to allocate more resources to the Minikube cluster. The default settings may not be sufficient for running CP components smoothly. We will allocate 6 CPU cores, 20GB of memory, and 50GB of disk space to ensure that the cluster can handle the workload effectively.

```bash
minikube start --driver=docker --cpus=6 --memory=20480 --disk-size=50g
```

- `--driver=docker`: Use Docker as the container runtime (instead of VirtualBox or Hyper-V).
- `--cpus=6`: Allocate 6 CPU cores to the Minikube cluster.
- `--memory=20480`: Allocate 20GB of memory to the Minikube cluster.
- `--disk-size=50g`: Allocate 50GB of disk space to the Minikube cluster.

Then verify that Minikube is running:
```bash
minikube status
kubectl get nodes
```

## **2.0 Startup the Confluent Operator (CFK)**

### **2.1 Create the Confluent namespace and set it as the default context for `kubectl`**
```bash
kubectl create namespace confluent
kubectl config set-context --current --namespace=confluent
```

### **2.2 Add the Confluent Helm repo and install the Confluent Operator**
```bash
helm repo add confluentinc https://packages.confluent.io/helm
helm repo update
helm upgrade --install confluent-operator confluentinc/confluent-for-kubernetes --namespace confluent
```

### **2.3 Verify the Operator is running**
```bash
kubectl get pods -n confluent
```

If all goes well you should see the following output:
```bash
NAME                                  READY   STATUS    RESTARTS   AGE
confluent-operator-66b887b979-frj42   1/1     Running   0          15s
```

The CFK operater is now running and ready to manage Confluent Platform resources in the cluster.

## **3.0 Deploy KRaft broker and controller with CFK**

### **3.1 Set the TUTORIAL_HOME environment variable**
```bash
export TUTORIAL_HOME="https://raw.githubusercontent.com/confluentinc/confluent-kubernetes-examples/master/quickstart-deploy/kraft-quickstart"
```

The `TUTORIAL_HOME` environment variable is being set to a raw GitHub URL that points to the directory containing the Kubernetes manifest for deploying Confluent Platform in KRaft mode. This allows us to reference the manifest file directly from that URL in the next step when we apply it with `kubectl`.

Sets an environment variable pointing to a raw GitHub URL for Confluent's official Kubernetes examples repo — specifically the KRaft quickstart directory. KRaft is Kafka's ZooKeeper-free mode (Kafka Raft metadata).

> **To browse the manifest file directly, you can visit:**
> [https://github.com/confluentinc/confluent-kubernetes-examples/tree/master/quickstart-deploy/kraft-quickstart](https://github.com/confluentinc/confluent-kubernetes-examples/tree/master/quickstart-deploy/kraft-quickstart)


### **3.2 Apply the Confluent Platform manifest**
```bash
kubectl apply -f $TUTORIAL_HOME/confluent-platform-c3++.yaml
```

> The **`raw.githubusercontent.com`** URL works when you append a specific filename to it, allowing you to directly access the raw content of that file. When you use `kubectl apply -f` with a URL, `kubectl` can fetch the YAML manifest directly from that URL and apply it to your Kubernetes cluster without needing to download the file manually first. This is a convenient way to deploy Kubernetes resources directly from a GitHub repository.

Applies a Kubernetes manifest file directly from that GitHub URL, `kubectl` can fetch and apply remote YAML files without downloading them first. The c3++ in the filename likely refers to Control Center (C3) with additional/enhanced configuration (the ++ suggesting an extended or "plus" variant).

> This is spinning up the Confluent Platform on Kubernetes using the Confluent Operator (CFK - Confluent for Kubernetes) in KRaft mode. It would typically deploy:
>
> - Kraft Controllers
> - Kafka Brokers
> - Schema Registry
> - Kafka Connect
> - ksqlDB
> - REST Proxy
> - Control Center (C3) — the Confluent monitoring UI

### **3.3 Verify the platform is running**
Watch the pods in the confluent namespace until all components are up and running (this will take a few minutes):
```bash
kubectl get pods -n confluent -w
```

You're looking for all pods to be in the "Running" state.

Final status checker for Kubernetes Operators:
```bash
kubectl get pods -n confluent
```

You should see all pods at `1/1` or `3/3 Running`.  Then open the Control Center UI to verify the platform is healthy.

Open Control Center:
```bash
kubectl port-forward -n confluent controlcenter-0 9021:9021
```

### **3.4 Access Control Center**
Go to the Control Center UI dashboard:
```bash
http://localhost:9021/
```

## **4.0 Teardown the CP Core Components**
To clean up the resources created by this tutorial, you can delete the Confluent Platform deployment and the Confluent Operator:
```bash
kubectl delete -f $TUTORIAL_HOME/confluent-platform-c3++.yaml
helm uninstall confluent-operator -n confluent
kubectl delete namespace confluent
```

## **5.0 Deploy Provectus' Kafka UI**

### **5.1 Add the Helm repo**
```bash
helm repo add kafka-ui https://provectus.github.io/kafka-ui-charts
helm repo update
```

### **5.2 Install Kafka UI**
```bash
helm upgrade --install kafka-ui kafka-ui/kafka-ui \
  --namespace confluent \
  --set yamlApplicationConfig.kafka.clusters[0].name="confluent" \
  --set yamlApplicationConfig.kafka.clusters[0].bootstrapServers="kafka:9092" \
  --set yamlApplicationConfig.kafka.clusters[0].schemaRegistry="http://schemaregistry:8081" \
  --set yamlApplicationConfig.kafka.clusters[0].kafkaConnect[0].name="connect" \
  --set yamlApplicationConfig.kafka.clusters[0].kafkaConnect[0].address="http://connect:8083" \
  --set yamlApplicationConfig.auth.type="DISABLED" \
  --set yamlApplicationConfig.management.health.ldap.enabled="false"
```

The service names (`kafka`, `schemaregistry`, `connect`) are the internal Kubernetes DNS names assigned by CFK, they only resolve from within the cluster, which is why Kafka UI runs inside the same namespace.

### **5.3 Verify the installation**
```bash
kubectl get pods -n confluent | grep kafka-ui
```

Wait until the pod shows `Running` before port-forwarding.

### **5.4 Open the UI**
```bash
kubectl port-forward -n confluent svc/kafka-ui 8080:80
```

Then open `http://localhost:8080` in your browser. Note the asymmetry: the service listens on port `80` internally, forwarded to `8080` locally.

## **6.0 Teardown Kafka UI**
To remove Kafka UI from the cluster, run:
```bash
helm uninstall kafka-ui -n confluent
```

## **7.0 Deploy Apache Flink on Kubernetes with the Flink Operator**

Set these shell variables once at the top of your terminal session to avoid hardcoding versions in the commands below:

```bash
export CERT_MANAGER_VER="v1.18.2"
export FLINK_OPERATOR_VER="1.130.0"
```

### **7.1 Install `cert-manager` manifest**

The Confluent Flink Kubernetes Operator uses cert-manager webhooks for TLS certificate injection. cert-manager must be fully ready **before** the operator is installed:

```bash
kubectl apply -f https://github.com/jetstack/cert-manager/releases/download/${CERT_MANAGER_VER}/cert-manager.yaml
```

> This creates the `cert-manager` namespace and installs three deployments: `cert-manager`, `cert-manager-cainjector`, and `cert-manager-webhook`.

### **7.2 Wait for cert-manager to be ready**

Then wait for all three components to be ready before proceeding, the Flink operator webhook will fail silently if `cert-manager` isn't fully up:

```bash
# Core controller
kubectl wait --for=condition=ready pod -l app=cert-manager -n cert-manager --timeout=120s

# CA injector (patches webhook CA bundles)
kubectl wait --for=condition=ready pod -l app=cainjector -n cert-manager --timeout=120s

# Webhook (validates Certificate / Issuer CRs)
kubectl wait --for=condition=ready pod -l app=webhook    -n cert-manager --timeout=120s
```

### **7.3 Verify cert-manager is running**
```bash
kubectl get pods -n cert-manager
```

### **7.4 Install the Confluent Flink Kubernetes Operator**
The Flink Operator is available on the Confluent Helm repo, so we can install it with `helm`:

#### **7.4.1 Add the Confluent Helm repo**
```bash
helm repo add confluentinc https://packages.confluent.io/helm 2>/dev/null || true
helm repo update
```

Confirm the chart is available:
```bash
helm search repo confluentinc/flink-kubernetes-operator --versions | head -5
```

#### **7.4.2 Install the operator**
```bash
helm upgrade --install cp-flink-kubernetes-operator \
  confluentinc/flink-kubernetes-operator \
  --version "~${FLINK_OPERATOR_VER}" \
  --namespace confluent \
  --set watchNamespaces="{confluent}" \
  --set webhook.create=false
```

| Flag | Value | Reason |
| --- | --- | --- |
| --version | "~${FLINK_OPERATOR_VER}" | Tilde constraint allows patch-level upgrades only |
| watchNamespaces | "{confluent}" | Scopes operator to the confluent namespace; prevents cluster-wide RBAC grants |
| webhook.create | false | Disables the operator's own admission webhook (cert-manager is handling TLS for CMF; the operator webhook is not required for session-cluster mode) |

#### **7.4.3 Wait for the operator pod**
```bash
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=flink-kubernetes-operator -n confluent --timeout=180s
```

#### **7.4.4 Verify**
```bash
# Pod status
kubectl get pods -n confluent | grep -E "flink-kubernetes-operator"

# Helm release
helm list -n confluent | grep cp-flink-kubernetes-operator

# CRDs installed by the operator
kubectl get crds | grep flink.apache.org
```

## **8.0 Deploy Confluent Manager for Apache Flink (CMF) on Kubernetes**

Set these shell variables once at the top of your terminal session to avoid hardcoding versions in the commands below:

```bash
export CMF_VER="2.1.0"
export CMF_ENV_NAME="dev-local"
export CMF_LOCAL_PORT="18080"   # ephemeral port used for port-forward during API calls
export CMF_OPEN_PORT="8080"     # port used when browsing the REST API interactively
```

### **8.1 Add (or update) the Confluent Helm repo**
```bash
helm repo add confluentinc https://packages.confluent.io/helm 2>/dev/null || true
helm repo update
```

Confirm the chart is available:
```bash
helm search repo confluentinc/confluent-manager-for-apache-flink --versions | head -5
```

### **8.2 Install the CMF chart**
```bash
helm upgrade --install cmf confluentinc/confluent-manager-for-apache-flink --version "~${CMF_VER}" --namespace confluent --set cmf.sql.production=false
```

| Flag | Value | Reason |
| --- | --- | --- |
| --version | "~${CMF_VER}" | Tilde allows patch-level upgrades; pins the minor version |
| cmf.sql.production | false | Enables non-production SQL mode required for local / dev deployments; Flink SQL statements will not enforce production-grade resource quotas |

### **8.3 Wait for the CMF pod**
```bash
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=confluent-manager-for-apache-flink -n confluent --timeout=180s
```

### **8.4 Verify**
```bash
# Pod status
kubectl get pods -n confluent -l app.kubernetes.io/name=confluent-manager-for-apache-flink

# Helm release
helm list -n confluent | grep cmf

# CMF service
kubectl get svc cmf-service -n confluent
```


### **8.1 Remove Flink cluster**

```bash
kubectl delete flinkdeployment flink-basic -n confluent --ignore-not-found=true
```

### **8.2 Remove Flink Operator**

```bash
helm uninstall flink-kubernetes-operator -n confluent
```

### **8.3 Remove cert-manager**

```bash
kubectl delete -f https://github.com/jetstack/cert-manager/releases/download/${CERT_MANAGER_VER}/cert-manager.yaml --ignore-not-found=true
```

## **9.0 Glossary**
| Term | Description |
| --- | --- |
| **CFK** | Confluent for Kubernetes, a set of Kubernetes Operators for deploying and managing Confluent Platform on Kubernetes. |
| **CRD** | Custom Resource Definition, a way to extend Kubernetes capabilities by defining custom resources. |
| **Operator** | A method of packaging, deploying, and managing a Kubernetes application. |
| **Controller** | A control loop that watches the state of your cluster and makes or requests changes as needed. |
| **Reconciliation** | The process of ensuring that the current state of the cluster matches the desired state defined by a resource. |
| **Finalizer** | A mechanism to perform cleanup before a resource is deleted. |
| **Webhook** | A way to extend Kubernetes API by intercepting API requests and modifying them or validating them. |
| **CR** | Custom Resource, an instance of a CRD that represents a specific configuration or state in the cluster. | 

## **10.0 Kubernetes Nautical Theme**
The nautical theme runs throughout the Kubernetes ecosystem:

| Term | Description |
| --- | --- |
| **Kubernetes** | Helmsman/pilot |
| **Helm** | The ship's wheel |
| **Charts** | Nautical maps (Helm packages are called "charts") |
| **Harbor** | A container registry (like a port where ships dock) |
| **Fleet** | A multi-cluster management tool |
