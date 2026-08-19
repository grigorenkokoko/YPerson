# Domainless serverless bootstrap

This is the one-time operator runbook for the database-free YPerson backend.
Perform the steps in this order. The deployment workflow is
[`../../../.github/workflows/deploy-serverless.yml`](../../../.github/workflows/deploy-serverless.yml),
the Gateway specification is [`api-gateway.yaml`](api-gateway.yaml), and the
revision deployment with health-check rollback is [`deploy.sh`](deploy.sh).

## Resource inventory and scope

Use this exact inventory:

```text
Existing registry: crp7vdmqvk61ce7oukqn
Image repository: backend
HTTP container: yperson-api
Runtime service account: yperson-runtime
Gateway service account: yperson-gateway
GitHub deployer service account: yperson-github
API Gateway: yperson-api-gateway
```

This release creates no customer domain, certificate, DNS record, VM route,
YDB, PostgreSQL, Lockbox, VPC attachment, migration container, or database
security group. Do not create or configure any of those resources for this
runbook.

## Least-privilege identities and GitHub OIDC

Create the three named service accounts and grant only these scoped bindings:

| Service account | Binding |
| --- | --- |
| `yperson-runtime` | `container-registry.images.puller` on registry `crp7vdmqvk61ce7oukqn` |
| `yperson-gateway` | `serverless-containers.containerInvoker` on `yperson-api` |
| `yperson-github` | `container-registry.images.pusher` on the registry; `serverless-containers.editor` on `yperson-api`; `iam.serviceAccounts.user` on `yperson-runtime` |

Configure workload identity federation for `yperson-github` with these exact
values:

```text
Issuer: https://token.actions.githubusercontent.com
Audience: https://github.com/grigorenkokoko
JWKS: https://token.actions.githubusercontent.com/.well-known/jwks
Subject: repo:grigorenkokoko/YPerson:ref:refs/heads/main
```

The workflow exchanges its GitHub Actions identity token for a Yandex Cloud IAM
token. Do not create an authorized-key JSON or GitHub secret.

## Bootstrap order

1. Create the three service accounts and their scoped bindings.
2. Create the private `yperson-api` container object without publishing a
   revision.
3. In a temporary rendered copy of [`api-gateway.yaml`](api-gateway.yaml), fill
   only `YC_HTTP_CONTAINER_ID` and `YC_GATEWAY_SA_ID`. Reject the file if any
   literal `${` remains, then create `yperson-api-gateway` from that rendered
   copy.
4. Read and record the Gateway `domain` field as `GATEWAY_DOMAIN`. Its base URL
   is `https://${GATEWAY_DOMAIN}`. This API Gateway technical HTTPS domain is
   the permanent production address while the same Gateway resource exists;
   this architecture has no later custom-domain cutover.
5. Configure exactly these ten GitHub repository variables:

   ```text
   YC_DEPLOYER_SA_ID
   YC_FOLDER_ID
   YC_REGISTRY_ID
   YC_HTTP_CONTAINER_ID
   YC_RUNTIME_SA_ID
   YC_GATEWAY_SA_ID
   YC_HEALTH_URL=https://${GATEWAY_DOMAIN}/health
   YPERSON_CONFIG_VERSION=2026-08-19.1
   YPERSON_PRIVACY_URL=https://${GATEWAY_DOMAIN}/privacy
   YPERSON_SUPPORT_URL=https://${GATEWAY_DOMAIN}/support
   ```

   Set `YC_REGISTRY_ID` to the existing registry ID
   `crp7vdmqvk61ce7oukqn`.
6. Configure workload identity federation and manually dispatch **Deploy
   backend to Yandex Serverless Containers**. This creates the first revision.
7. Through `https://${GATEWAY_DOMAIN}`, verify these exact status and content
   contracts:

   | Request | Required result |
   | --- | --- |
   | `GET /health` | `200` JSON with `status: "ok"` and the configured `version` |
   | `GET /config` | `200` canonical public-configuration JSON, `ETag`, and `Cache-Control: public, max-age=60`; an equal `If-None-Match` returns `304` with an empty body |
   | `GET /privacy` | `200` HTML technical privacy page |
   | `GET /support` | `200` HTML technical support page |
   | `POST /sync` | `503` Gateway dummy JSON `{"error":"temporarily_unavailable","message":"sync is not enabled"}` |

8. Put `https://${GATEWAY_DOMAIN}` in `Config/Release.xcconfig` as
   `API_BASE_URL`. Put the `/privacy` and `/support` URLs in
   `Config/Base.xcconfig` as `PRIVACY_POLICY_URL` and `SUPPORT_URL`, using the
   repository's `https:/$()/...` xcconfig escaping.
9. Regenerate the Xcode project if required, build the Release configuration,
   and verify the resolved `API_BASE_URL`, `PRIVACY_POLICY_URL`, and
   `SUPPORT_URL` build settings before installing on an iPhone.

## Rollback and physical-iPhone gate

For a failed revision, use a known-good revision ID for the manual rollback:

```bash
yc --folder-id "$YC_FOLDER_ID" serverless container rollback \
  --id "$YC_HTTP_CONTAINER_ID" \
  --revision-id "<KNOWN_GOOD_REVISION_ID>"
```

The deployment script also attempts this rollback after a failed health check
when a previous active revision exists. After rollback, recheck all five route
contracts through the Gateway domain.

A physical iPhone must successfully load `/config`, `/privacy`, and `/support`
through API Gateway before release installation is accepted. The legacy VM is
neither a dependency nor a fallback in this runbook; no VM action is included.
