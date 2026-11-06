# claude-box image. Built on demand by claude-box / claude-box.ps1 — not meant to be built by hand.
FROM debian:trixie-slim
ARG UID=1000 GID=1000 UNAME=claude HOMEDIR=/home/claude VERSION=latest PACKAGES="" SETUP_B64=""
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl git sudo locales tini $PACKAGES \
 && sed -i 's/# en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen && locale-gen \
 && rm -rf /var/lib/apt/lists/*
RUN if [ -n "$SETUP_B64" ]; then echo "$SETUP_B64" | base64 -d | tr -d '\r' > /tmp/setup.sh && bash -e /tmp/setup.sh && rm /tmp/setup.sh; fi
RUN (getent group "$GID" >/dev/null || groupadd -g "$GID" "$UNAME") \
 && (id -u "$UID" >/dev/null 2>&1 && userdel -r "$(id -un "$UID")" || true) \
 && mkdir -p "$(dirname "$HOMEDIR")" \
 && useradd -o -u "$UID" -g "$GID" -d "$HOMEDIR" -m -s /bin/bash "$UNAME" \
 && echo "$UNAME ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/claude-box
USER $UID:$GID
ENV HOME=$HOMEDIR PATH=$HOMEDIR/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    LANG=en_US.UTF-8 DISABLE_AUTOUPDATER=1 IS_SANDBOX=1
RUN curl -fsSL https://claude.ai/install.sh | bash -s -- "$VERSION" \
 && rm -rf "$HOMEDIR/.claude" "$HOMEDIR/.claude.json" && claude --version
ENTRYPOINT ["/usr/bin/tini", "--", "claude"]
