# Theme and palette (master doc 6.4). bslib only -- no CSS literals in the
# modules; www/css/custom.css keeps what Bootstrap cannot express (the red
# field while a validation hint is visible).

theme_taxi <- function(mode = c("light", "dark")) {
  mode <- match.arg(mode)
  light <- mode == "light"

  bs_theme(
    version = 5,
    bg = if (light) "#ffffff" else "#16171d",
    fg = if (light) "#1f2328" else "#e6e6ea",
    primary = brand_colour(if (light) "primary" else "primary_dark"),
    base_font = font_google("Inter", local = TRUE),
    code_font = font_google("JetBrains Mono", local = TRUE),
    "border-radius" = "0.5rem",
    "enable-shadows" = "false"
  ) |>
    bs_add_rules(c(
      # Palette tokens (6.4). The primary itself comes from shared/brand.yaml;
      # its contrast over #ffffff is 6.8:1, so it passes AA. The rest of this
      # block is app-only (share/ has no light/dark theme). Dark mode follows
      # data-bs-theme, which input_dark_mode() toggles on the page.
      ":root {",
      "  --taxi-surface: #f6f7f9;",
      "  --taxi-border: #e3e6ea;",
      "  --taxi-success-bg: #d1f4dd;",
      "  --taxi-success-fg: #0a5c2b;",
      "  --taxi-danger-bg: #fde2e4;",
      "  --taxi-danger-fg: #8b1a1a;",
      "  --taxi-pu-zone: #8470ff;",
      "  --taxi-do-zone: #C44E52;",
      "  --taxi-origin: #E6B800;",
      "}",
      "[data-bs-theme=\"dark\"] {",
      "  --taxi-surface: #1e2028;",
      "  --taxi-border: #2c2f3a;",
      "  --taxi-success-bg: #1e4d2b;",
      "  --taxi-success-fg: #6ee7a0;",
      "  --taxi-danger-bg: #4a1a1a;",
      "  --taxi-danger-fg: #f8a5a5;",
      "  --taxi-pu-zone: #a99aff;",
      "  --taxi-do-zone: #e07074;",
      "  --taxi-origin: #FFD700;",
      "}",
      "body { background-color: var(--taxi-surface); }",
      ".card { border-color: var(--taxi-border); }"
    ))
}
