defmodule SymphonyElixirWeb.Layouts do
  @moduledoc """
  Shared layouts for the observability dashboard.
  """

  use Phoenix.Component
  alias SymphonyElixirWeb.DashboardComponents

  @spec root(map()) :: Phoenix.LiveView.Rendered.t()
  def root(assigns) do
    assigns = assign(assigns, :csrf_token, Plug.CSRFProtection.get_csrf_token())

    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={@csrf_token} />
        <meta name="theme-color" content="#f6f7fb" />
        <title>Symphony Control Surface</title>
        <script>
          (function () {
            try {
              var storedTheme = window.localStorage.getItem("symphony-theme");
              var systemTheme = window.matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light";
              var resolvedTheme = storedTheme || systemTheme;
              document.documentElement.dataset.theme = resolvedTheme;
            } catch (_error) {
              document.documentElement.dataset.theme = "light";
            }
          })();
        </script>
        <script defer src="/vendor/phoenix_html/phoenix_html.js"></script>
        <script defer src="/vendor/phoenix/phoenix.js"></script>
        <script defer src="/vendor/phoenix_live_view/phoenix_live_view.js"></script>
        <script>
          function setTheme(theme) {
            var nextTheme = theme === "dark" ? "light" : "dark";
            document.documentElement.dataset.theme = theme;

            try {
              window.localStorage.setItem("symphony-theme", theme);
            } catch (_error) {}

            var themeMeta = document.querySelector("meta[name='theme-color']");
            if (themeMeta) {
              themeMeta.setAttribute("content", theme === "dark" ? "#0f1720" : "#f6f7fb");
            }

            var toggleButtons = document.querySelectorAll("[data-theme-toggle]");
            toggleButtons.forEach(function (button) {
              button.setAttribute("aria-pressed", String(theme === "dark"));
              var meta = button.querySelector(".utility-button-meta");
              if (meta) meta.textContent = theme === "dark" ? "Dark" : "Light";
              button.dataset.nextTheme = nextTheme;
            });
          }

          function wireUtilityButtons() {
            document.querySelectorAll("[data-copy]").forEach(function (button) {
              if (button.dataset.copyBound === "true") return;
              button.dataset.copyBound = "true";
              button.addEventListener("click", function () {
                var value = button.dataset.copy || "";
                var baseLabel = button.dataset.copyLabel || button.textContent;
                var copiedLabel = button.dataset.copyCopied || "Copied";

                if (navigator.clipboard && value) {
                  navigator.clipboard.writeText(value);
                }

                button.textContent = copiedLabel;
                window.clearTimeout(button._copyTimer);
                button._copyTimer = window.setTimeout(function () {
                  button.textContent = baseLabel;
                }, 1200);
              });
            });

            document.querySelectorAll("[data-theme-toggle]").forEach(function (button) {
              if (button.dataset.themeBound === "true") return;
              button.dataset.themeBound = "true";
              button.addEventListener("click", function () {
                setTheme(button.dataset.nextTheme || "dark");
              });
            });
          }

          function syncUiChrome() {
            setTheme(document.documentElement.dataset.theme || "light");
            wireUtilityButtons();
          }

          window.addEventListener("DOMContentLoaded", function () {
            var csrfToken = document
              .querySelector("meta[name='csrf-token']")
              ?.getAttribute("content");

            syncUiChrome();

            if (!window.Phoenix || !window.LiveView) return;

            var liveSocket = new window.LiveView.LiveSocket("/live", window.Phoenix.Socket, {
              params: {_csrf_token: csrfToken}
            });

            liveSocket.connect();
            window.liveSocket = liveSocket;
          });

          window.addEventListener("phx:page-loading-stop", syncUiChrome);
        </script>
        <link rel="stylesheet" href="/dashboard.css" />
      </head>
      <body>
        {@inner_content}
      </body>
    </html>
    """
  end

  @spec app(map()) :: Phoenix.LiveView.Rendered.t()
  def app(assigns) do
    ~H"""
    <a class="skip-link" href="#main-content">Skip to main content</a>
    <div class="app-shell">
      <DashboardComponents.flash_group flash={assigns[:flash] || %{}} />
      <main id="main-content" class="app-main">
        {@inner_content}
      </main>
    </div>
    """
  end
end
