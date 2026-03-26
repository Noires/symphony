FROM elixir:1.19.5-otp-28

ENV DEBIAN_FRONTEND=noninteractive \
    GIT_TERMINAL_PROMPT=0

RUN apt-get update && apt-get install -y --no-install-recommends \
    bash \
    build-essential \
    ca-certificates \
    git \
    nodejs \
    npm \
    openssh-client \
    python3 \
    ripgrep \
  && npm install --global @openai/codex yarn \
  && mix local.hex --force \
  && mix local.rebar --force \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY mix.exs mix.lock ./
COPY config ./config

RUN mix deps.get

COPY lib ./lib
COPY priv ./priv
COPY bin ./bin
COPY scripts ./scripts
COPY .formatter.exs ./
COPY README.md ./

RUN mix deps.compile && mix build

RUN groupadd --system symphony \
 && useradd --system --gid symphony --create-home --home-dir /home/symphony --shell /bin/bash symphony \
 && mkdir -p /home/symphony/.codex /run/symphony /workspaces /logs \
 && chown -R symphony:symphony /home/symphony /run/symphony /workspaces /logs \
 && install -m 0755 ./scripts/symphony-git-credential-helper.sh /usr/local/bin/symphony-git-credential-helper \
 && git config --system credential.helper /usr/local/bin/symphony-git-credential-helper \
 && git config --system credential.useHttpPath true

ENV HOME=/home/symphony \
    XDG_CONFIG_HOME=/home/symphony/.config

USER symphony

CMD ["./bin/symphony", "--i-understand-that-this-will-be-running-without-the-usual-guardrails", "--logs-root", "/logs", "--port", "4000", "/run/symphony/WORKFLOW.md"]
