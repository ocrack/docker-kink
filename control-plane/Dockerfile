FROM docker:19.03.1-dind

ENV container docker
ENV KUBECTL_VERSION v1.15.11
ENV KIND_VERSION v0.8.1

RUN set -eux; \
    apk add --no-cache bash \
                       curl \
                       findmnt; \
    \
    curl -Lso /usr/bin/kubectl https://storage.googleapis.com/kubernetes-release/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl; \
    chmod 0755 /usr/bin/kubectl; \
    curl -Lso /usr/bin/kind https://github.com/kubernetes-sigs/kind/releases/download/${KIND_VERSION}/kind-linux-amd64; \
    chmod 0755 /usr/bin/kind

COPY kind-config.yaml /kind-config.yaml
COPY entrypoint.sh /entrypoint.sh

EXPOSE 30001

ENTRYPOINT ["/entrypoint.sh"]
CMD []
