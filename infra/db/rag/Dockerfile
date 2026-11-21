# RAG-store Liquibase applier image (Liquibase 5.0).
#
# Base image is pulled THROUGH the project's ECR pull-through cache (not
# docker.io directly) to avoid Docker Hub rate limits. The registry
# (<account>.dkr.ecr.<region>.amazonaws.com) is passed in as a build arg by the
# build workflow, resolved via `aws sts get-caller-identity` — never hardcoded.
# The pull-through-cache repo prefix is `docker-hub/` (set by the cache rule in
# ecr_pullthrough.tf), so upstream `liquibase/liquibase` becomes
# `<registry>/docker-hub/liquibase/liquibase`.
#
# IMPORTANT (Liquibase 5.0): the 5.0 Community image NO LONGER bundles any
# database driver. We therefore install the PostgreSQL JDBC driver explicitly
# below — without it, Liquibase cannot connect at all.
#
# Debian variant (not -alpine): the entrypoint needs AWS CLI v2 + jq, which apt
# installs cleanly; AWS CLI v2 on alpine/musl is glibc-only and awkward.
ARG ECR_REGISTRY
FROM ${ECR_REGISTRY}/docker-hub/liquibase/liquibase:5.0

USER root

# Tooling the entrypoint needs: jq (parse the secret), curl (download the JDBC
# driver), unzip (for the AWS CLI installer). NOTE: Ubuntu/Debian repos do NOT
# ship an `awscli` package for AWS CLI v2 — it is installed from AWS's official
# zip bundle below, not via apt.
RUN apt-get update \
 && apt-get install -y --no-install-recommends jq curl ca-certificates unzip \
 && rm -rf /var/lib/apt/lists/*

# AWS CLI v2 — installed from AWS's official bundle (resolve amd64 vs arm64 at
# build time so the image works on either Fargate platform).
RUN set -eux; \
    arch="$(uname -m)"; \
    case "$arch" in \
      x86_64)  awscli_url="https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" ;; \
      aarch64) awscli_url="https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip" ;; \
      *) echo "unsupported arch: $arch" >&2; exit 1 ;; \
    esac; \
    curl -fsSL -o /tmp/awscliv2.zip "$awscli_url"; \
    unzip -q /tmp/awscliv2.zip -d /tmp; \
    /tmp/aws/install; \
    rm -rf /tmp/awscliv2.zip /tmp/aws; \
    aws --version

# Install the PostgreSQL JDBC driver, resolving the ABSOLUTE LATEST stable
# release from Maven Central at build time — ANY major version (42.x, 43.x, and
# beyond), per project requirement. Uses Maven's <release> field (the newest
# stable the maintainers publish), falling back to the max non-SNAPSHOT version.
# The build FAILS if the version can't be resolved or the jar can't be
# downloaded — we never ship a driverless image.
#
# NOTE: unpinned "any major" means a future major release is adopted
# automatically; a breaking major could surface at migrate time. Chosen
# deliberately (always-latest driver).
RUN set -eux; \
    meta="$(curl -fsSL https://repo1.maven.org/maven2/org/postgresql/postgresql/maven-metadata.xml)"; \
    version="$(printf '%s' "$meta" \
      | grep -oE '<release>[^<]+</release>' \
      | sed -E 's@</?release>@@g' | head -n1)"; \
    if [ -z "$version" ]; then \
      version="$(printf '%s' "$meta" \
        | grep -oE '<version>[^<]+</version>' \
        | sed -E 's@</?version>@@g' \
        | grep -vi 'snapshot\|alpha\|beta\|rc' \
        | sort -V | tail -n1)"; \
    fi; \
    test -n "$version"; \
    echo "Installing PostgreSQL JDBC driver ${version}"; \
    curl -fsSL -o /liquibase/lib/postgresql.jar \
      "https://repo1.maven.org/maven2/org/postgresql/postgresql/${version}/postgresql-${version}.jar"; \
    test -s /liquibase/lib/postgresql.jar

# NOTE: the changelog + changesets are NOT baked into the image. They are
# MOUNTED at runtime from the git checkout (the rag-migrate workflow does
# `actions/checkout` then `docker run -v .../infra/db/rag:/work`). This means a
# new changeset is just a commit — no image rebuild. The image is a stable
# Liquibase runtime (base + driver + aws-cli + entrypoint); git is the source of
# truth for the schema. The entrypoint runs Liquibase from the mounted /work.

# Entrypoint: fetch secret -> build JDBC url -> run the requested command
# against the MOUNTED changelog. (Image logic, so it is baked in — not SQL.)
COPY infra/db/rag/entrypoint.sh /usr/local/bin/rag-entrypoint.sh
RUN chmod +x /usr/local/bin/rag-entrypoint.sh

# Drop back to the unprivileged liquibase user shipped by the base image.
USER liquibase

ENTRYPOINT ["/usr/local/bin/rag-entrypoint.sh"]
CMD ["update"]
