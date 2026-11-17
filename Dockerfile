ARG BASE_IMAGE=alpine:3.22

FROM ${BASE_IMAGE}

LABEL org.opencontainers.image.source="https://github.com/travisghansen/argo-cd-helmfile"

SHELL ["/bin/sh", "-ec"]

ENV ARGOCD_USER_ID=1000

ARG TARGETPLATFORM
ARG BUILDPLATFORM

RUN echo "Running on ${BUILDPLATFORM}, building for ${TARGETPLATFORM}"

USER root

# -----------------------------------------------------------------------------
# Base packages
# -----------------------------------------------------------------------------

RUN apk add --no-cache \
    ca-certificates \
    curl \
    git \
    git-lfs \
    jq \
    tar \
    gzip \
    gettext

# -----------------------------------------------------------------------------
# Non-root user
# -----------------------------------------------------------------------------

RUN addgroup -g "${ARGOCD_USER_ID}" argocd && \
    adduser \
        -D \
        -u "${ARGOCD_USER_ID}" \
        -G argocd \
        -h /home/argocd \
        -s /sbin/nologin \
        argocd && \
    mkdir -p \
        /home/argocd/cmp-server/config \
        /home/argocd/.cache/argo-cd-helmfile \
        /home/argocd/helm/cache \
        /home/argocd/helm/config \
        /home/argocd/helm/data && \
    chown -R "${ARGOCD_USER_ID}:argocd" /home/argocd && \
    chmod -R g=u /home/argocd && \
    git lfs install --system

# -----------------------------------------------------------------------------
# Tool versions
# -----------------------------------------------------------------------------

ARG AGE_VERSION="v1.3.2"
ARG HELM_VERSION="v4.2.4"
ARG HELMFILE_VERSION="1.7.4"
ARG KUSTOMIZE_VERSION="5.8.1"
ARG SOPS_VERSION="v3.13.3"
ARG YQ_VERSION="v4.53.6"

ARG KUBECTL_VERSION="v1.37.0"
ARG KUBESEAL_VERSION="0.39.1"

ARG HELM_DIFF_VERSION="3.15.12"
ARG HELM_GIT_VERSION="1.5.2"
ARG HELM_SECRETS_VERSION="4.7.7"

# -----------------------------------------------------------------------------
# Install binaries
# -----------------------------------------------------------------------------

RUN ARCH="$(apk --print-arch)" && \
    case "${ARCH}" in \
        x86_64) GO_ARCH="amd64" ;; \
        aarch64) GO_ARCH="arm64" ;; \
        armv7) GO_ARCH="arm" ;; \
        *) echo "Unsupported architecture: ${ARCH}"; exit 1 ;; \
    esac && \
    \
    mkdir -p /tmp/downloads && \
    cd /tmp/downloads && \
    \
    # helm
    curl -fsSLO "https://get.helm.sh/helm-${HELM_VERSION}-linux-${GO_ARCH}.tar.gz" && \
    tar -xzf "helm-${HELM_VERSION}-linux-${GO_ARCH}.tar.gz" && \
    install -m 0755 "linux-${GO_ARCH}/helm" /usr/local/bin/helm && \
    \
    # helmfile
    curl -fsSLO "https://github.com/helmfile/helmfile/releases/download/v${HELMFILE_VERSION}/helmfile_${HELMFILE_VERSION}_linux_${GO_ARCH}.tar.gz" && \
    tar -xzf "helmfile_${HELMFILE_VERSION}_linux_${GO_ARCH}.tar.gz" && \
    install -m 0755 helmfile /usr/local/bin/helmfile && \
    \
    # sops
    curl -fsSL \
        -o /usr/local/bin/sops \
        "https://github.com/getsops/sops/releases/download/${SOPS_VERSION}/sops-${SOPS_VERSION}.linux.${GO_ARCH}" && \
    chmod 0755 /usr/local/bin/sops && \
    \
    # age
    curl -fsSLO \
        "https://github.com/FiloSottile/age/releases/download/${AGE_VERSION}/age-${AGE_VERSION}-linux-${GO_ARCH}.tar.gz" && \
    tar -xzf "age-${AGE_VERSION}-linux-${GO_ARCH}.tar.gz" && \
    install -m 0755 age/age /usr/local/bin/age && \
    install -m 0755 age/age-keygen /usr/local/bin/age-keygen && \
    \
    # yq
    curl -fsSL \
        -o /usr/local/bin/yq \
        "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_${GO_ARCH}" && \
    chmod 0755 /usr/local/bin/yq && \
    \
    # kubectl
    curl -fsSL \
        -o /usr/local/bin/kubectl \
        "https://dl.k8s.io/${KUBECTL_VERSION}/bin/linux/${GO_ARCH}/kubectl" && \
    chmod 0755 /usr/local/bin/kubectl && \
    \
    # kubeseal
    curl -fsSLO \
        "https://github.com/bitnami-labs/sealed-secrets/releases/download/v${KUBESEAL_VERSION}/kubeseal-${KUBESEAL_VERSION}-linux-${GO_ARCH}.tar.gz" && \
    tar -xzf "kubeseal-${KUBESEAL_VERSION}-linux-${GO_ARCH}.tar.gz" && \
    install -m 0755 kubeseal /usr/local/bin/kubeseal && \
    \
    # kustomize
    curl -fsSLO \
        "https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize%2Fv${KUSTOMIZE_VERSION}/kustomize_v${KUSTOMIZE_VERSION}_linux_${GO_ARCH}.tar.gz" && \
    tar -xzf "kustomize_v${KUSTOMIZE_VERSION}_linux_${GO_ARCH}.tar.gz" && \
    install -m 0755 kustomize /usr/local/bin/kustomize && \
    \
    rm -rf /tmp/downloads

# -----------------------------------------------------------------------------
# Runtime configuration
# -----------------------------------------------------------------------------

ENV USER=argocd
ENV HOME=/home/argocd

ENV HELM_CACHE_HOME=/home/argocd/helm/cache
ENV HELM_CONFIG_HOME=/home/argocd/helm/config
ENV HELM_DATA_HOME=/home/argocd/helm/data

ENV ARGOCD_HELMFILE_CACHE_ROOT=/home/argocd/.cache/argo-cd-helmfile

USER ${ARGOCD_USER_ID}

WORKDIR /home/argocd

# -----------------------------------------------------------------------------
# Helm plugins
# -----------------------------------------------------------------------------

RUN helm plugin install https://github.com/aslafy-z/helm-git --version v${HELM_GIT_VERSION} --verify=false; \
    helm plugin install https://github.com/databus23/helm-diff/releases/download/v${HELM_DIFF_VERSION}/helm-diff-linux-amd64.tgz --verify=false; \
    helm plugin install https://github.com/jkroepke/helm-secrets/releases/download/v${HELM_SECRETS_VERSION}/secrets-${HELM_SECRETS_VERSION}.tgz --verify=false; \
    helm plugin install https://github.com/jkroepke/helm-secrets/releases/download/v${HELM_SECRETS_VERSION}/secrets-getter-${HELM_SECRETS_VERSION}.tgz --verify=false; \
    helm plugin install https://github.com/jkroepke/helm-secrets/releases/download/v${HELM_SECRETS_VERSION}/secrets-post-renderer-${HELM_SECRETS_VERSION}.tgz --verify=false

# -----------------------------------------------------------------------------
# Argo CD CMP config and entry script
# -----------------------------------------------------------------------------

USER root

COPY src/argo-cd-helmfile.sh /usr/local/bin/argo-cd-helmfile.sh
COPY plugin.yaml /home/argocd/cmp-server/config/plugin.yaml

RUN chmod 0755 /usr/local/bin/argo-cd-helmfile.sh && \
    chown -R "${ARGOCD_USER_ID}:0" \
        /home/argocd \
        /usr/local/bin/argo-cd-helmfile.sh && \
    chmod -R g=u /home/argocd

USER ${ARGOCD_USER_ID}

WORKDIR /home/argocd