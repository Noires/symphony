#!/bin/sh
set -eu

action="${1:-get}"

read_token_file() {
  token_file="${SYMPHONY_GITHUB_TOKEN_FILE:-}"

  if [ -n "$token_file" ] && [ -f "$token_file" ]; then
    tr -d '\r\n' < "$token_file"
  fi
}

case "$action" in
  get)
    protocol=""
    host=""
    token=""

    while IFS='=' read -r key value; do
      case "$key" in
        protocol) protocol="$value" ;;
        host) host="$value" ;;
      esac
    done

    token="$(read_token_file)"

    if [ -z "$token" ] && [ -n "${GITHUB_TOKEN:-}" ]; then
      token="$GITHUB_TOKEN"
    fi

    if [ "$protocol" = "https" ] && [ "$host" = "github.com" ] && [ -n "$token" ]; then
      printf 'username=x-access-token\n'
      printf 'password=%s\n' "$token"
    fi
    ;;
  store|erase)
    ;;
esac

exit 0
