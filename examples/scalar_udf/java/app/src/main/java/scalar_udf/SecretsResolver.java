/**
 * Copyright (c) 2026 Jeffrey Jonathan Jennings
 *
 * @author Jeffrey Jonathan Jennings (J3)
 */
package scalar_udf;

import java.net.URI;
import java.util.Optional;

import software.amazon.awssdk.http.urlconnection.UrlConnectionHttpClient;
import software.amazon.awssdk.regions.Region;
import software.amazon.awssdk.services.secretsmanager.SecretsManagerClient;
import software.amazon.awssdk.services.secretsmanager.SecretsManagerClientBuilder;
import software.amazon.awssdk.services.secretsmanager.model.GetSecretValueRequest;

/**
 * Resolves a UDF secret from one of two sources, in order:
 *
 * <ol>
 *   <li><b>AWS Secrets Manager</b> — when {@code <BASE_NAME>_SECRET_ID} is set, fetch the
 *       secret string for that secret-id. Honors {@code AWS_ENDPOINT_URL_SECRETSMANAGER}
 *       (or the generic {@code AWS_ENDPOINT_URL}) so a LocalStack endpoint can be used in
 *       development and minikube without changing UDF code.</li>
 *   <li><b>Plain environment variable</b> — when {@code <BASE_NAME>_SECRET_ID} is unset,
 *       fall back to {@code <BASE_NAME>_SECRET}. This keeps the UDF runnable in unit tests
 *       and outside Kubernetes.</li>
 * </ol>
 *
 * <p>Picking Secrets Manager is opt-in (driven by the {@code _SECRET_ID} env var) so that
 * pipelines without AWS connectivity continue to work and so that the AWS SDK is exercised
 * only on pods that truly need it.
 */
final class SecretsResolver {

    private SecretsResolver() {}

    /**
     * Resolve the secret for a UDF.
     *
     * @param baseName the env-var base, e.g. {@code "PII_PSEUDONYM"}. The resolver looks at
     *                 {@code baseName + "_SECRET_ID"} (Secrets Manager source) and
     *                 {@code baseName + "_SECRET"} (plain-env fallback).
     * @return the resolved secret string; never {@code null} or empty.
     * @throws IllegalStateException if neither source produces a non-empty value.
     */
    static String resolve(String baseName) {
        String secretId = System.getenv(baseName + "_SECRET_ID");
        if (secretId != null && !secretId.isEmpty()) {
            return fetchFromSecretsManager(secretId, baseName);
        }

        String envSecret = System.getenv(baseName + "_SECRET");
        if (envSecret != null && !envSecret.isEmpty()) {
            return envSecret;
        }

        throw new IllegalStateException(
            "Neither " + baseName + "_SECRET_ID (AWS Secrets Manager source) nor "
            + baseName + "_SECRET (plain environment fallback) is set. Configure one so the "
            + "UDF can load its keying material.");
    }

    private static String fetchFromSecretsManager(String secretId, String baseName) {
        SecretsManagerClientBuilder builder = SecretsManagerClient.builder()
            .httpClient(UrlConnectionHttpClient.create());

        Optional<String> region = firstNonEmpty(
            System.getenv("AWS_REGION"),
            System.getenv("AWS_DEFAULT_REGION"));
        region.ifPresent(r -> builder.region(Region.of(r)));

        Optional<String> endpoint = firstNonEmpty(
            System.getenv("AWS_ENDPOINT_URL_SECRETSMANAGER"),
            System.getenv("AWS_ENDPOINT_URL"));
        endpoint.ifPresent(e -> builder.endpointOverride(URI.create(e)));

        try (SecretsManagerClient client = builder.build()) {
            String value = client.getSecretValue(
                GetSecretValueRequest.builder().secretId(secretId).build()
            ).secretString();
            if (value == null || value.isEmpty()) {
                throw new IllegalStateException(
                    "Secret '" + secretId + "' (referenced by " + baseName + "_SECRET_ID) "
                    + "exists but has an empty SecretString.");
            }
            return value;
        }
    }

    private static Optional<String> firstNonEmpty(String... values) {
        for (String v : values) {
            if (v != null && !v.isEmpty()) return Optional.of(v);
        }
        return Optional.empty();
    }
}
