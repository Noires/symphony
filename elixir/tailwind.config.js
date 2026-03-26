const defaultTheme = require("tailwindcss/defaultTheme");

const withOpacity = (variableName) => {
  return ({ opacityValue }) => {
    if (opacityValue === undefined) {
      return `rgb(var(${variableName}) / 1)`;
    }
    return `rgb(var(${variableName}) / ${opacityValue})`;
  };
};

/** @type {import('tailwindcss').Config} */
module.exports = {
  content: [
    "./lib/**/*.{ex,heex,eex,leex}",
    "./ui-visual/**/*.{js,mjs}",
    "./playwright.config.mjs"
  ],
  theme: {
    extend: {
      colors: {
        primary: withOpacity("--color-primary"),
        "primary-content": withOpacity("--color-primary-content"),
        secondary: withOpacity("--color-secondary"),
        "secondary-content": withOpacity("--color-secondary-content"),
        accent: withOpacity("--color-accent"),
        "accent-content": withOpacity("--color-accent-content"),
        neutral: withOpacity("--color-neutral"),
        "neutral-content": withOpacity("--color-neutral-content"),
        "base-100": withOpacity("--color-base-100"),
        "base-200": withOpacity("--color-base-200"),
        "base-300": withOpacity("--color-base-300"),
        "base-content": withOpacity("--color-base-content"),
        info: withOpacity("--color-info"),
        success: withOpacity("--color-success"),
        warning: withOpacity("--color-warning"),
        error: withOpacity("--color-error")
      },
      fontFamily: {
        sans: ["IBM Plex Sans", ...defaultTheme.fontFamily.sans],
        mono: ["IBM Plex Mono", "Consolas", ...defaultTheme.fontFamily.mono]
      },
      boxShadow: {
        "raised": "0 1px 2px rgba(0,0,0,0.04), 0 2px 8px rgba(0,0,0,0.02)",
        "raised-dark": "0 1px 3px rgba(0,0,0,0.3), 0 4px 12px rgba(0,0,0,0.15)",
        "elevated": "0 2px 6px rgba(0,0,0,0.06), 0 8px 24px rgba(0,0,0,0.04)",
        "elevated-dark": "0 2px 8px rgba(0,0,0,0.4), 0 12px 32px rgba(0,0,0,0.2)",
        "glow-blue": "0 0 12px rgba(96,165,250,0.15)",
        "glow-green": "0 0 10px rgba(34,197,94,0.12)",
        "glow-amber": "0 0 10px rgba(245,158,11,0.12)",
        "glow-red": "0 0 10px rgba(248,113,113,0.12)",
        "glow-purple": "0 0 10px rgba(167,139,250,0.12)"
      },
      animation: {
        "fade-up": "fadeUp 0.2s ease both",
        "scale-in": "scaleIn 0.15s ease both",
        "beacon": "beacon 2s ease-in-out infinite"
      },
      keyframes: {
        fadeUp: {
          "0%": { opacity: "0", transform: "translateY(3px)" },
          "100%": { opacity: "1", transform: "translateY(0)" }
        },
        scaleIn: {
          "0%": { opacity: "0", transform: "scale(0.98)" },
          "100%": { opacity: "1", transform: "scale(1)" }
        },
        beacon: {
          "0%, 100%": { opacity: "1" },
          "50%": { opacity: "0.35" }
        }
      }
    }
  },
  plugins: []
};
