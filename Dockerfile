# claude-box image. Built on demand by claude-box / claude-box.cmd — not meant to be built by hand.
FROM debian:trixie-slim
ARG UID=1000 GID=1000 UNAME=claude HOMEDIR=/home/claude VERSION=latest PACKAGES="" SETUP_B64=""
ENV DEBIAN_FRONTEND=noninteractive
# Bootstrap CA certs over http (retrying), then switch apt to https: some networks corrupt plain http.
RUN echo 'Acquire::Retries "5";' > /etc/apt/apt.conf.d/80retries \
 && for i in 1 2 3 4 5; do apt-get update && apt-get install -y --no-install-recommends ca-certificates && break; sleep 2; done \
 && sed -i 's|http://|https://|g' /etc/apt/sources.list.d/debian.sources \
 && apt-get update && apt-get install -y --no-install-recommends curl git locales tini $PACKAGES \
 && sed -i 's/# en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen && locale-gen \
 && rm -rf /var/lib/apt/lists/*
RUN git config --system safe.directory "*"
RUN if [ -n "$SETUP_B64" ]; then echo "$SETUP_B64" | base64 -d | tr -d '\r' > /tmp/setup.sh && bash -e /tmp/setup.sh && rm /tmp/setup.sh; fi
RUN (getent group "$GID" >/dev/null || groupadd -g "$GID" "$UNAME") \
 && (id -u "$UID" >/dev/null 2>&1 && userdel -r "$(id -un "$UID")" || true) \
 && mkdir -p "$(dirname "$HOMEDIR")" \
 && useradd -o -u "$UID" -g "$GID" -d "$HOMEDIR" -m -s /bin/bash "$UNAME"
USER $UID:$GID
ENV HOME=$HOMEDIR PATH=$HOMEDIR/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    LANG=en_US.UTF-8 DISABLE_AUTOUPDATER=1 IS_SANDBOX=1
RUN curl -fsSL https://claude.ai/install.sh | bash -s -- "$VERSION" \
 && rm -rf "$HOMEDIR/.claude" "$HOMEDIR/.claude.json" && claude --version
ENTRYPOINT ["/usr/bin/tini", "--", "claude"]
