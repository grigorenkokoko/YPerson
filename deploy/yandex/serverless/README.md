# Domainless serverless bootstrap

This is the one-time operator runbook for the database-free YPerson backend.
Perform the steps in order and stop if any verification fails. The deployment
workflow is
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

## Least-privilege target state

The completed bootstrap must have only these intended bindings:

| Service account | Binding |
| --- | --- |
| `yperson-runtime` | `container-registry.images.puller` on registry `crp7vdmqvk61ce7oukqn` |
| `yperson-gateway` | `serverless-containers.containerInvoker` on `yperson-api` |
| `yperson-github` | `container-registry.images.pusher` on the registry; `serverless-containers.editor` on `yperson-api`; `iam.serviceAccounts.user` on `yperson-runtime` |

The order below deliberately creates each target resource before assigning a
binding to it.

## GitHub OIDC target state

Create two distinct Yandex IAM objects: a named workload identity federation
and a federated credential linking that federation to `yperson-github`.

```text
Federation name: `yperson-github-oidc`
Issuer: https://token.actions.githubusercontent.com
Audience: https://github.com/grigorenkokoko
JWKS: https://token.actions.githubusercontent.com/.well-known/jwks
External subject ID: `repo:grigorenkokoko/YPerson:ref:refs/heads/main`
```

The issuer, audience, and JWKS configure the federation. The external subject
ID configures the separate federated credential; it is not a federation
property. Do not create an authorized-key JSON or GitHub secret. The workflow
must exchange GitHub OIDC for a short-lived Yandex Cloud IAM token.

## Bootstrap order

1. Create the three service accounts: `yperson-runtime`, `yperson-gateway`, and
   `yperson-github`.
2. Grant the registry-scoped bindings: give `yperson-runtime`
   `container-registry.images.puller` and `yperson-github`
   `container-registry.images.pusher` on registry `crp7vdmqvk61ce7oukqn`.
   Also grant `yperson-github` `iam.serviceAccounts.user` on the existing
   `yperson-runtime` account.
3. Create the empty private `yperson-api` container object without publishing
   a revision. Record its ID as `YC_HTTP_CONTAINER_ID`. Do not make the
   container public.
4. Grant the container-scoped bindings on the now-existing `yperson-api`
   container: give `yperson-gateway`
   `serverless-containers.containerInvoker` and `yperson-github`
   `serverless-containers.editor`.
5. Run the pre-revision effective-access audit. Container role listings omit
   inherited roles, so inspect the direct container, folder, and cloud bindings
   and save all three outputs:

   ```bash
   YC_CLOUD_ID="$(yc resource-manager folder get "$YC_FOLDER_ID" \
     --format json | jq -r '.cloud_id')"
   yc serverless container list-access-bindings --name yperson-api
   yc resource-manager folder list-access-bindings "$YC_FOLDER_ID"
   yc resource-manager cloud list-access-bindings "$YC_CLOUD_ID"
   ```

   At every inspected scope, reject any binding for `allUsers` or
   `allAuthenticatedUsers` that grants `serverless-containers.containerInvoker`,
   `serverless-containers.editor`, `serverless-containers.admin`, `editor`, or
   `admin`. Stop if one exists; do not continue until it is removed through a
   separately reviewed access change. Do not make the container public to test
   access.
6. In a temporary rendered copy of [`api-gateway.yaml`](api-gateway.yaml), fill
   only `YC_HTTP_CONTAINER_ID` and `YC_GATEWAY_SA_ID`. Reject the file if any
   literal `${` remains, then create `yperson-api-gateway` from that rendered
   copy.
7. Read and record the Gateway `domain` field as `GATEWAY_DOMAIN`. Its base URL
   is `https://${GATEWAY_DOMAIN}`. This API Gateway technical HTTPS domain is
   the permanent production address while the same Gateway resource exists;
   this architecture has no later custom-domain cutover.
8. Configure exactly these ten GitHub repository variables:

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

   Set `YC_REGISTRY_ID` to `crp7vdmqvk61ce7oukqn`.
9. Before enabling production OIDC or automatic deployment, create or promote
   the remote `main` branch from the reviewed local commit and prove that the
   remote ref points to the same immutable SHA:

   ```bash
   EXPECTED_MAIN_SHA="$(git rev-parse HEAD)"
   git show --no-patch "$EXPECTED_MAIN_SHA"
   git push origin "$EXPECTED_MAIN_SHA:refs/heads/main"
   REMOTE_MAIN_SHA="$(git ls-remote origin refs/heads/main | awk '{print $1}')"
   test "$REMOTE_MAIN_SHA" = "$EXPECTED_MAIN_SHA"
   ```

   Stop if the SHA comparison fails. Then create and enforce GitHub branch
   protection for exact branch `main`. Require a pull request before merging
   with at least one approving review and enable **Do not allow bypassing the
   above settings**. Leave **Allow force pushes** disabled. Leave **Allow
   deletions** disabled. Verify the effective `main` branch protection rule in
   repository settings, record its read-back evidence, and stop if any of
   those controls is absent.
10. Create the workload identity federation `yperson-github-oidc` with the exact
    issuer, audience, and JWKS values above. Read it back and record its
    federation ID and configured values.
11. Only after branch protection is verified, create a separate federated
    credential linking the recorded federation ID, service account
    `yperson-github`, and external subject ID
    `repo:grigorenkokoko/YPerson:ref:refs/heads/main`. Read it back and verify
    all three links. Creating this credential enables the workflow's automatic
    production authentication path; keep static credentials absent.
12. Dispatch **Deploy backend to Yandex Serverless Containers** explicitly
    from the verified production ref:

    ```bash
    gh workflow run deploy-serverless.yml --ref main
    ```

    Verify that the queued run names branch `main` and commit
    `EXPECTED_MAIN_SHA`. This creates the first revision only after the Gateway
    domain and all ten repository variables exist.
13. Repeat the post-revision effective-access audit with the three commands from
    step 5 and apply the same public-group rejection. Then retrieve the
    container's direct URL and record it:

    ```bash
    CONTAINER_URL="$(yc serverless container get \
      --id "$YC_HTTP_CONTAINER_ID" --format json | jq -r '.url')"
    test -n "$CONTAINER_URL"
    DIRECT_HEALTH_URL="${CONTAINER_URL%/}/health"
    DIRECT_STATUS="$(curl --silent --show-error --output /dev/null \
      --write-out '%{http_code}' "$DIRECT_HEALTH_URL")"
    case "$DIRECT_STATUS" in
      401|403) ;;
      *) echo "expected direct authorization denial, got $DIRECT_STATUS" >&2; exit 1 ;;
    esac
    ```

    Send that `/health` request without an `Authorization` header. Require the
    authorization-layer denial `401` or `403`; any application response such
    as `200` or `404`, and every other status, fails the privacy gate. Do not
    make the container public for this negative test.

    Through `https://${GATEWAY_DOMAIN}`, verify these exact Gateway contracts:

    | Request | Required result |
    | --- | --- |
    | `GET /health` | `200` JSON with `status: "ok"` and the configured `version` |
    | `GET /config` | `200` canonical public-configuration JSON, `ETag`, and `Cache-Control: public, max-age=60`; an equal `If-None-Match` returns `304` with an empty body |
    | `GET /privacy` | `200` HTML technical privacy page |
    | `GET /support` | `200` HTML technical support page |
    | `POST /sync` | `503` Gateway dummy JSON `{"error":"temporarily_unavailable","message":"sync is not enabled"}` |

14. Put `https://${GATEWAY_DOMAIN}` in `Config/Release.xcconfig` as
    `API_BASE_URL`. Put the `/privacy` and `/support` URLs in
    `Config/Base.xcconfig` as `PRIVACY_POLICY_URL` and `SUPPORT_URL`, using the
    repository's `https:/$()/...` xcconfig escaping.
15. Regenerate the Xcode project if required, build the Release configuration,
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
when a previous active revision exists. After rollback, repeat the
post-revision effective-access audit, the unauthenticated direct-URL denial
check, and all five Gateway route contracts.

A physical iPhone must successfully load `/config`, `/privacy`, and `/support`
through API Gateway before release installation is accepted. The legacy VM is
neither a dependency nor a fallback in this runbook; no VM action is included.

## Official procedures

- [Create a Serverless Container](https://yandex.cloud/en/docs/serverless-containers/operations/create)
- [Assign roles for a container](https://yandex.cloud/en/docs/serverless-containers/operations/role-add)
- [View direct container roles](https://yandex.cloud/en/docs/serverless-containers/operations/role-list)
- [View assigned and inherited roles](https://yandex.cloud/en/docs/iam/operations/roles/get-assigned-roles)
- [Configure GitHub workload identity federation and federated credentials](https://yandex.cloud/en/docs/iam/tutorials/ci-cd-github-functions)
- [Configure API Gateway Serverless Containers integration](https://yandex.cloud/en/docs/api-gateway/concepts/extensions/containers)
- [About protected branches](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-protected-branches/about-protected-branches)
