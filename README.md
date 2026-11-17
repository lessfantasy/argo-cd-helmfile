# Argo CD Helmfile CMP Plugin

This repository contains a sidecar-based Argo CD Config Management Plugin (CMP)
for rendering Kubernetes manifests with [`helmfile`](https://github.com/helmfile/helmfile).

This is deep rewrited fork from [text](https://github.com/travisghansen/argo-cd-helmfile)

## What is included

```text
.
├── Dockerfile.             # Image based on Alpine
├── plugin.yaml             # Shared Argo CD CMP configuration
└── src
    └── argo-cd-helmfile.sh # CMP entrypoint
```


## Default tool versions:

| Tool | Version |
|---|---:|
| Helmfile | `1.7.4` |
| helm-diff | `3.15.12` |
| helm-git | `1.5.2` |
| helm-secrets | `4.7.7` |
| SOPS | `v3.13.3` |
| age | `v1.3.2` |
| yq | `v4.53.6` |
| kubectl | `v1.37.0` |
| kustomize | `5.8.1` |
| kubeseal | `0.39.1` |

## Build

```bash
docker build \
  -f Dockerfile \
  -t ghcr.io/lessfantasy/argo-cd-helmfile:latest \
  .
```

### Override versions at build time

Any version declared as an `ARG` in the Dockerfile can be overridden during the
build.

Example:

```bash
docker build \
  -f Dockerfile \
  --build-arg HELM_VERSION=v4.2.4 \
  --build-arg HELMFILE_VERSION=1.5.5 \
  -t ghcr.io/lessfantasy/argo-cd-helmfile:custom \
  .
```

## Argo CD integration

The image is designed to run as an Argo CD repo-server sidecar CMP plugin.
The Dockerfile copies:

```text
plugin.yaml -> /home/argocd/cmp-server/config/plugin.yaml
src/argo-cd-helmfile.sh -> /usr/local/bin/argo-cd-helmfile.sh
```

Because the version-specific script is always copied to the same runtime path,
`plugin.yaml` is shared by both image variants.

Minimal sidecar example:

```yaml
repoServer:
  extraContainers:
    - name: helmfile-cmp
      image: ghcr.io/lessfantasy/argo-cd-helmfile:latest
      command: [/var/run/argocd/argocd-cmp-server]
      securityContext:
        runAsNonRoot: true
        runAsUser: 999
      volumeMounts:
        - name: var-files
          mountPath: /var/run/argocd
        - name: plugins
          mountPath: /home/argocd/cmp-server/plugins
        - name: tmp
          mountPath: /tmp
```

Use the Helm 4 image by changing only the image tag:

```yaml
image: ghcr.io/lessfantasy/argo-cd-helmfile:latest
```

The exact `repoServer` values can vary depending on how Argo CD is installed
and which Helm chart or manifests are used to manage it.

## CMP phases

`plugin.yaml` wires the following Argo CD CMP phases to the entrypoint script:

| Phase | Command |
|---|---|
| `init` | `argo-cd-helmfile.sh init` |
| `generate` | `argo-cd-helmfile.sh generate` |
| `discover` | `argo-cd-helmfile.sh discover` |
| `parameters.dynamic` | `argo-cd-helmfile.sh parameters` |

### `init`

The init phase can:

1. optionally run `helmfile cache cleanup`;
2. optionally execute a user-provided init script;
3. run `helmfile repos`, unless the persistent repository cache is still valid.

### `generate`

The generate phase runs:

```bash
helmfile template --skip-deps
```

The script also forwards Argo CD Kubernetes capabilities to Helm through
`helmfile template --args`:

- `KUBE_VERSION` -> `helm template --kube-version=...`
- `KUBE_API_VERSIONS` -> repeated `helm template --api-versions=...`

### `discover`

Discovery succeeds when the repository contains at least one of:

```text
helmfile.yaml
helmfile.yaml.gotmpl
helmfile.d/
```

Discovery can also be forced with `HELMFILE_DISCOVERY_RESPONSE`.

## Dynamic parameters

The plugin exposes the following dynamic parameters to Argo CD:

| Parameter | Type | Description |
|---|---|---|
| `HELM_TEMPLATE_OPTIONS` | string | Extra options passed to `helm template` through `helmfile template --args` |
| `HELMFILE_TEMPLATE_OPTIONS` | string | Extra options appended to `helmfile template` |
| `HELMFILE_GLOBAL_OPTIONS` | string | Extra options appended to the base `helmfile` command |
| `HELMFILE_INIT_SCRIPT_FILE` | string | Path to an optional init script inside the checked-out repository |
| `HELMFILE_CACHE_CLEANUP` | boolean | Run `helmfile cache cleanup` during `init` |
| `HELMFILE_REPO_CACHE_TIMEOUT` | string | Repository update cache TTL in seconds |
| `HELMFILE_USE_CONTEXT_NAMESPACE` | boolean | Do not force `--namespace ${ARGOCD_APP_NAMESPACE}` when enabled |

## Environment variables

The script supports direct environment variables and Argo CD parameter/env
prefixes.

### Prefix handling

Before doing any work, the script exports values from these prefixes:

| Input prefix | Result |
|---|---|
| `ARGOCD_ENV_FOO=bar` | exports `FOO=bar` |
| `PARAM_FOO=bar` | exports `FOO=bar` |

This keeps compatibility with Argo CD CMP parameter injection.

### Common configuration

| Variable | Default | Description |
|---|---|---|
| `HELM_BINARY` | `helm` | Helm executable name or path |
| `HELMFILE_BINARY` | `helmfile` | Helmfile executable name or path |
| `HELMFILE_ENV_FILE` | `.argo-cd-helmfile-env` | Optional env file sourced from the repository root |
| `HELMFILE_GLOBAL_OPTIONS` | empty | Extra global Helmfile options |
| `HELMFILE_TEMPLATE_OPTIONS` | empty | Extra options for `helmfile template` |
| `HELM_TEMPLATE_OPTIONS` | empty | Extra options for Helm template via `--args` |
| `HELMFILE_INIT_SCRIPT_FILE` | empty | Optional init script path |
| `HELMFILE_CACHE_CLEANUP` | `false` | Whether to run `helmfile cache cleanup` |
| `HELMFILE_REPO_CACHE_TIMEOUT` | `0` | Cache TTL for `helmfile repos`; disabled when `0` |
| `HELMFILE_REPO_CACHE_KEY` | generated | Custom cache key for `helmfile repos` |
| `HELMFILE_USE_CONTEXT_NAMESPACE` | `false` | Use the namespace from the Kubernetes context instead of Argo CD app namespace |
| `HELMFILE_DISCOVERY_RESPONSE` | empty | Force discovery success/failure when set to a truthy or falsy value |

### Option parsing

`HELM_TEMPLATE_OPTIONS`, `HELMFILE_TEMPLATE_OPTIONS`, and
`HELMFILE_GLOBAL_OPTIONS` support two formats:

#### Space-separated format

```bash
HELM_TEMPLATE_OPTIONS="--include-crds --skip-tests"
```

#### Newline-separated format

Use newline-separated values when an argument itself may contain spaces.

```bash
HELMFILE_TEMPLATE_OPTIONS='--selector name=my-release
--include-needs'
```

The newline-separated format is safer for complex arguments.

## Cache and temporary directories

Runtime temporary files are created in a unique directory per invocation:

```bash
TMP_ROOT="$(mktemp -d /tmp/argo-cd-helmfile.sh.XXXXXX)"
TMPDIR="$TMP_ROOT"
```

The temporary directory is removed automatically on exit.

Helm and Helmfile state is persisted under:

```text
/home/argocd/.cache/argo-cd-helmfile
```

The default cache-related paths are:

| Variable | Default |
|---|---|
| `ARGOCD_HELMFILE_CACHE_ROOT` | `${HOME}/.cache/argo-cd-helmfile` |
| `HELM_CACHE_HOME` | `${ARGOCD_HELMFILE_CACHE_ROOT}/helm/cache` |
| `HELM_CONFIG_HOME` | `${ARGOCD_HELMFILE_CACHE_ROOT}/helm/config` |
| `HELM_DATA_HOME` | `${ARGOCD_HELMFILE_CACHE_ROOT}/helm/data` |

Repository update cache markers are stored under:

```text
${ARGOCD_HELMFILE_CACHE_ROOT}/repo-update
```

Set `HELMFILE_REPO_CACHE_TIMEOUT` to enable caching of the `helmfile repos`
step.

Example:

```bash
HELMFILE_REPO_CACHE_TIMEOUT=3600
```

