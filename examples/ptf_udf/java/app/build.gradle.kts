plugins {
    java
    id("com.gradleup.shadow") version "9.0.0-beta12"
}

group = "ptf"
version = "1.0.0-SNAPSHOT"

val flinkVersion = "2.1.0"
val kafkaConnectorVersion = "4.0.1-2.0"
val log4jVersion = "2.24.3"

java {
    sourceCompatibility = JavaVersion.VERSION_17
    targetCompatibility = JavaVersion.VERSION_17
}

repositories {
    mavenCentral()
}

dependencies {
    // Flink (provided on the cluster)
    compileOnly("org.apache.flink:flink-table-api-java:$flinkVersion")
    compileOnly("org.apache.flink:flink-table-runtime:$flinkVersion")
    compileOnly("org.apache.flink:flink-streaming-java:$flinkVersion")
    compileOnly("org.apache.flink:flink-clients:$flinkVersion")

    // Provided by Confluent Cloud Flink runtime
    compileOnly("org.apache.flink:flink-connector-kafka:$kafkaConnectorVersion")
    compileOnly("org.apache.flink:flink-json:$flinkVersion")

    // Logging (provided by Confluent Cloud Flink runtime)
    compileOnly("org.apache.logging.log4j:log4j-slf4j2-impl:$log4jVersion")
    compileOnly("org.apache.logging.log4j:log4j-api:$log4jVersion")
    compileOnly("org.apache.logging.log4j:log4j-core:$log4jVersion")

    // Test
    testImplementation("org.apache.flink:flink-table-planner-loader:$flinkVersion")
    testImplementation("org.junit.jupiter:junit-jupiter:5.11.0")
    testImplementation("org.assertj:assertj-core:3.26.3")
}

tasks.test {
    useJUnitPlatform()
}

tasks.shadowJar {
    archiveClassifier.set("")
    mergeServiceFiles()
    exclude("META-INF/*.SF", "META-INF/*.DSA", "META-INF/*.RSA")
    manifest {
        attributes("Main-Class" to "ptf.FlinkJob")
    }
}
