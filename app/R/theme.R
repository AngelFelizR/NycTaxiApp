# Theme and palette (master doc 6.4). bslib only -- no CSS literals in the
# modules; www/css/custom.css keeps what Bootstrap cannot express (the red
# field while a validation hint is visible).

# The palette as data (6.4, and section 12's "contrast verified").
#
# Every colour the app draws comes from here, so the contrast check in
# tests/testthat/test-accessibility.R reads the same values the CSS is built
# from rather than a copy of them that could drift. Values are the ones the
# master document's palette table states; this file only decides where they
# live and which mode they belong to.
taxi_palette <- function(mode = c("light", "dark")) {
  mode <- match.arg(mode)
  light <- mode == "light"
  list(
    bg         = if (light) "#ffffff" else "#16171d",
    fg         = if (light) "#1f2328" else "#e6e6ea",
    primary    = brand_colour(if (light) "primary" else "primary_dark"),
    # Links are NOT the primary (section 12's 4.5:1 decided this, pa11y
    # found it): the brand primary #6d5dfc clears AA on #ffffff (4.54:1) but
    # the body sits on --taxi-surface #f6f7f9, where it reaches only 4.24:1
    # -- under AA for every anchor on a card, in the footer and in the intro.
    # No single value can serve both themes either, which is why this is a
    # per-mode token: the light one is the primary darkened until it clears
    # 4.5:1 on the surface (4.73:1), the dark one is the primary_dark, which
    # already clears it there (5.01:1). Bootstrap paints <a> from
    # $link-color, so theme_taxi() feeds it from here.
    link       = if (light) "#6657ec" else "#8b7dff",
    link_hover = if (light) "#5649c8" else "#9c90ff",
    surface    = if (light) "#f6f7f9" else "#1e2028",
    border     = if (light) "#e3e6ea" else "#2c2f3a",
    success_bg = if (light) "#d1f4dd" else "#1e4d2b",
    success_fg = if (light) "#0a5c2b" else "#6ee7a0",
    danger_bg  = if (light) "#fde2e4" else "#4a1a1a",
    danger_fg  = if (light) "#8b1a1a" else "#f8a5a5",
    # Secondary text (.kpi-label, .kbd-footer). One value cannot serve both
    # themes: on the light surface #64748b reaches only 4.44:1 and on the
    # dark one 3.41:1, both under section 12's 4.5:1 -- and no single grey
    # clears both (the light one needs to be dark, the dark one light).
    muted_fg   = if (light) "#5b6678" else "#9aa4b2",
    pu_zone    = if (light) "#8470ff" else "#a99aff",
    do_zone    = if (light) "#C44E52" else "#e07074",
    origin     = if (light) "#E6B800" else "#FFD700"
  )
}

# The token block for one mode, as the stylesheet wants it.
taxi_palette_rules <- function(p) {
  paste0("  --taxi-", c(
    sprintf("surface: %s;", p$surface),
    sprintf("border: %s;", p$border),
    sprintf("success-bg: %s;", p$success_bg),
    sprintf("success-fg: %s;", p$success_fg),
    sprintf("danger-bg: %s;", p$danger_bg),
    sprintf("danger-fg: %s;", p$danger_fg),
    sprintf("muted-fg: %s;", p$muted_fg),
    sprintf("pu-zone: %s;", p$pu_zone),
    sprintf("do-zone: %s;", p$do_zone),
    sprintf("origin: %s;", p$origin)
  ))
}

theme_taxi <- function(mode = c("light", "dark")) {
  mode <- match.arg(mode)
  p <- taxi_palette(mode)
  bs_theme(
    version = 5,
    bg = p$bg,
    fg = p$fg,
    primary = p$primary,
    # The anchors, from the palette: see the `link` token above. Left to
    # Bootstrap, $link-color would be $primary and every link on the surface
    # would sit at 4.24:1.
    "link-color" = p$link,
    "link-hover-color" = p$link_hover,
    base_font = font_google("Inter", local = TRUE),
    code_font = font_google("JetBrains Mono", local = TRUE),
    "border-radius" = "0.5rem",
    "enable-shadows" = "false"
  ) |>
    bs_add_rules(c(
      # Palette tokens (6.4). The primary itself comes from shared/brand.yaml;
      # the link token next to it is computed for AA on the surface (see
      # taxi_palette). The rest of this block is app-only (share/ has no
      # light/dark theme). Dark mode follows data-bs-theme, which
      # input_dark_mode() toggles on the page.
      ":root {",
      taxi_palette_rules(taxi_palette("light")),
      "}",
      "[data-bs-theme=\"dark\"] {",
      taxi_palette_rules(taxi_palette("dark")),
      "}",
      "body { background-color: var(--taxi-surface); }",
      ".card { border-color: var(--taxi-border); }"
    ))
}
