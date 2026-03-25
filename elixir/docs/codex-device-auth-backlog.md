# Codex Device Auth Dashboard Backlog

Status: completed

## Goal

Allow operators to complete `codex login --device-auth` from the Symphony dashboard instead of
dropping to the container shell.

## Scope

- runtime service for Codex auth status and device-auth sessions
- operator-protected dashboard controls
- JSON API for status, start, refresh, and cancel
- Docker-facing documentation for the new flow

## Completed

- Added `SymphonyElixir.CodexAuth` as a supervised runtime service.
- Added status probing via `codex login status`.
- Added live device-auth launch via `codex login --device-auth`.
- Added parsing for verification URL and user code from CLI output.
- Added cancellation support for an in-flight device-auth session.
- Exposed auth state through the shared presenter payload.
- Added API routes:
  - `GET /api/v1/codex/auth`
  - `POST /api/v1/codex/auth/refresh`
  - `POST /api/v1/codex/auth/device/start`
  - `POST /api/v1/codex/auth/device/cancel`
- Added a `Device login` operator panel on the dashboard settings page.
- Documented the dashboard path in the Docker setup notes.

## Outcome

Operators can now:

- inspect current Codex auth state
- start a device-code login from the dashboard
- copy/open the verification URL and code
- watch the flow complete live
- cancel a stuck login flow without shell access
