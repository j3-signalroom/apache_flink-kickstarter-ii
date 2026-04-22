"""
Copyright (c) 2026 Jeffrey Jonathan Jennings

Author: Jeffrey Jonathan Jennings (J3)

Resolves a UDF secret from one of two sources, in order:

1. **AWS Secrets Manager** — when ``<BASE_NAME>_SECRET_ID`` is set, fetch the
   secret string for that secret-id. Honors ``AWS_ENDPOINT_URL_SECRETSMANAGER``
   (or the generic ``AWS_ENDPOINT_URL``) so a LocalStack endpoint can be used
   in development and minikube without changing UDF code.

2. **Plain environment variable** — when ``<BASE_NAME>_SECRET_ID`` is unset,
   fall back to ``<BASE_NAME>_SECRET``. This keeps the UDF runnable in unit
   tests and outside Kubernetes.

Picking Secrets Manager is opt-in (driven by the ``_SECRET_ID`` env var) so
that pipelines without AWS connectivity continue to work and so that boto3 is
imported only on workers that truly need it.
"""
import os


def resolve(base_name: str) -> str:
    """
    Resolve the secret for a UDF.

    :param base_name: env-var base, e.g. ``"PII_PSEUDONYM"``. The resolver
        looks at ``base_name + "_SECRET_ID"`` (Secrets Manager source) and
        ``base_name + "_SECRET"`` (plain-env fallback).
    :return: the resolved secret string; never empty.
    :raises RuntimeError: if neither source produces a non-empty value.
    """
    secret_id = os.environ.get(f"{base_name}_SECRET_ID")
    if secret_id:
        return _fetch_from_secrets_manager(secret_id, base_name)

    env_secret = os.environ.get(f"{base_name}_SECRET")
    if env_secret:
        return env_secret

    raise RuntimeError(
        f"Neither {base_name}_SECRET_ID (AWS Secrets Manager source) nor "
        f"{base_name}_SECRET (plain environment fallback) is set. Configure "
        "one so the UDF can load its keying material."
    )


def _fetch_from_secrets_manager(secret_id: str, base_name: str) -> str:
    # boto3 is imported lazily so jobs that only use the env-var fallback do
    # not pay its import cost (and do not need it installed in the venv).
    import boto3

    kwargs = {}
    region = os.environ.get("AWS_REGION") or os.environ.get("AWS_DEFAULT_REGION")
    if region:
        kwargs["region_name"] = region

    endpoint = (
        os.environ.get("AWS_ENDPOINT_URL_SECRETSMANAGER")
        or os.environ.get("AWS_ENDPOINT_URL")
    )
    if endpoint:
        kwargs["endpoint_url"] = endpoint

    client = boto3.client("secretsmanager", **kwargs)
    response = client.get_secret_value(SecretId=secret_id)
    value = response.get("SecretString")
    if not value:
        raise RuntimeError(
            f"Secret '{secret_id}' (referenced by {base_name}_SECRET_ID) "
            "exists but has an empty SecretString."
        )
    return value
