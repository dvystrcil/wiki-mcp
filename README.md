# wiki-mcp (deploy)

Kustomize manifests for the [wiki-mcp](https://github.com/dvystrcil/wiki-mcp-docker)
Go MCP server. Phase 3 of dvystrcil/homelab#211.

## Layout

```
base/
  namespace.yaml             # ambient-mode label for gateway-services
  harbor-pull-secret.yaml    # InfisicalSecret → dockerconfigjson
  github-app-secret.yaml     # InfisicalSecret → GitHub App key for llm-wiki access
  pvc.yaml                   # 1Gi RWO for the working clone
  git-sync-script.yaml       # ConfigMap: get-token.sh + init.sh + sync.sh
  deployment.yaml            # init + main + sidecar in one pod
  service.yaml               # ClusterIP :8080
  kustomization.yaml
```

The Argo Application + ImageUpdater CR live in [dvystrcil/argocd-projects](https://github.com/dvystrcil/argocd-projects) under `wiki-mcp/`.

## Pod shape

```mermaid
flowchart LR
    INIT[init-clone<br/>alpine + git<br/>once] -->|clones into| PVC[(PVC<br/>/data)]
    PVC --> WMC[wiki-mcp<br/>main<br/>reads + writes]
    PVC --> SYNC[git-sync<br/>sidecar<br/>30s loop]
    SYNC -->|push| GH[(GitHub<br/>llm-wiki)]
    GH -->|pull| SYNC
    WMC -->|MCP HTTP :8080| OWUI[OWUI]
```

The `wiki-mcp` container itself has no outbound network — all GitHub
traffic is in the sidecar. The two-container split exists so that if
GitHub auth fails, the MCP keeps serving reads from the local clone;
only sync stops. Auth is a GitHub App installation token (minted +
auto-refreshed in-process by `get-token.sh`), so there is no PAT to
expire — see [Secrets](#secrets).

## Image tag convention

Pinned to `harbor.sirddail.net/ai/wiki-mcp:<semver>` — matches the
[open-terminal](https://github.com/dvystrcil/open-terminal) pattern.

**Release flow:**

1. Push to `main` of [wiki-mcp-docker](https://github.com/dvystrcil/wiki-mcp-docker) → CI builds `:dev` (mutable) and `:sha-<short>` (immutable debug aid)
2. Cut a GitHub release (e.g. `v0.2.0`) → release workflow retags `:dev` as `:0.2.0`, `:0.2`, and `:latest` in Harbor (no rebuild)
3. Bump the `image:` line in `base/deployment.yaml` here → commit + push → Argo syncs

No ImageUpdater — releases are intentional, gated by an actual GitHub release. The `:dev` tag never appears in this deployment.

## Secrets

Two InfisicalSecret CRs materialize from the `homelab-bz-gt/prod` project:

| K8s Secret               | Infisical keys used                  | Purpose                       |
|--------------------------|--------------------------------------|-------------------------------|
| `wiki-mcp-harbor-pull`   | HB_REGISTRY/USERNAME/PASSWORD/AUTH   | Pull from harbor-core         |
| `wiki-mcp-github-app`    | GITSYNC_APP_CLIENT_ID/INSTALLATION_ID/PRIVATE_KEY | sidecar git push/pull |

Sidecar git auth is a **GitHub App**, not a PAT. `get-token.sh` signs a
JWT with the App private key and exchanges it for a short-lived (≤1h)
installation token, refreshed in-loop — so nothing expires on a calendar
and there is no token to rotate.

It reuses the **same `GITSYNC_APP`** as
[quartz-viewer](https://github.com/dvystrcil/quartz-viewer) (already
installed on `dvystrcil/llm-wiki`). quartz-viewer only pulls; wiki-mcp
also pushes, so the App must grant **Contents: Read and write** on
`llm-wiki` (read-only is enough for quartz-viewer but blocks wiki-mcp's
push). Scope stays one repo — narrower than the broad write-capable CICD
App, whose key is deliberately kept out of long-running pods.

The JWT-signing path is covered offline by `tests/test-get-token-jwt.sh`.

## License

MIT.
