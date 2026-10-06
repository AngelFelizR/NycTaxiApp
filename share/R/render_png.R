# The share card (section 7.1): 1200x630, three cumulative curves plus one
# big label, built with patchwork and written with ragg::agg_png(). No personal
# data and no experiment_id ever reach this file -- only what GET
# /share-data/{token} returns, which is already aggregated (5.7).
#
# The colours match the Results screen so the card and the page agree: purple
# for the player, blue for the model, grey for accept-everything. No red/green
# anywhere on the curves -- the label carries the verdict (3.11).

PNG_WIDTH <- 1200L
PNG_HEIGHT <- 630L

# curve_specs()/curve_labels()/curve_colours() come from shared/load.R
# (shared/curves.yaml) -- the one spec this card and the Results screen share.
# They are named by label, so the manual scale can never look up a colour by a
# name the data does not have ("no shared levels found"), and their row order
# is the legend order.

# /share-data returns history already simplified into a data.frame, but a
# hand-written fixture (and jsonlite with simplifyVector = FALSE) may not be.
share_history <- function(history) {
  if (is.data.frame(history)) {
    return(data.frame(
      step = as.numeric(history$step),
      user = as.numeric(history$user),
      policy = as.numeric(history$policy),
      baseline = as.numeric(history$baseline)
    ))
  }
  rows <- lapply(history %||% list(), function(p) {
    data.frame(step = as.numeric(p$step %||% 0),
               user = as.numeric(p$user %||% 0),
               policy = as.numeric(p$policy %||% 0),
               baseline = as.numeric(p$baseline %||% 0))
  })
  if (length(rows) == 0) {
    return(data.frame(step = numeric(), user = numeric(),
                      policy = numeric(), baseline = numeric()))
  }
  do.call(rbind, rows)
}

# Long form: one row per (step, trajectory), which is what geom_line wants.
share_history_long <- function(history) {
  h <- share_history(history)
  labs <- curve_labels()
  n <- nrow(h)
  do.call(rbind, lapply(names(labs), function(nm) {
    data.frame(step = h$step, value = h[[nm]],
               # rep(): with an empty history the label would otherwise be
               # length 1 against 0 rows, and data.frame() refuses.
               series = factor(rep(labs[[nm]], n), levels = unname(labs)),
               stringsAsFactors = FALSE)
  }))
}

share_head <- function(data) {
  ggplot2::ggplot() +
    ggplot2::annotate("text", x = 0, y = 0.66, label = data$day_label %||% "",
                      hjust = 0, vjust = 0.5, size = 7.5, colour = "#64748b",
                      fontface = "bold") +
    ggplot2::annotate("text", x = 0, y = 0.2, label = data$label %||% "",
                      hjust = 0, vjust = 0.5, size = 17, colour = "#1f2328",
                      fontface = "bold") +
    ggplot2::xlim(0, 1) + ggplot2::ylim(0, 1) +
    ggplot2::labs(x = NULL, y = NULL) +
    ggplot2::theme_void()
}

share_curves <- function(data) {
  long <- share_history_long(data$history)
  labs <- curve_labels()
  ggplot2::ggplot(long, ggplot2::aes(step, value, colour = series)) +
    ggplot2::geom_line(linewidth = 2.4) +
    # `limits` fixes the level set: with an empty history the data would
    # contribute none, ggplot2 would find no shared level with the named
    # palette and warn on the legend.
    ggplot2::scale_colour_manual(values = curve_colours(),
                                 limits = unname(labs), name = NULL) +
    ggplot2::labs(x = NULL, y = NULL) +
    ggplot2::theme_minimal(base_size = 15) +
    ggplot2::theme(
      panel.grid.minor = ggplot2::element_blank(),
      legend.position = "top",
      legend.text = ggplot2::element_text(size = 13),
      plot.margin = ggplot2::margin(6, 12, 6, 12)
    )
}

share_foot <- function(data) {
  left <- sprintf("%s/h vs %s/h policy",
                  show_num(data$final_user_wage, 2, prefix = "$"),
                  show_num(data$final_policy_wage, 2, prefix = "$"))
  right <- if (is.null(data$user_percentile) || is.na(data$user_percentile)) {
    ""
  } else {
    sprintf("%s percentile", ordinal(data$user_percentile))
  }
  ggplot2::ggplot() +
    ggplot2::annotate("text", x = 0, y = 0.5, label = left, hjust = 0,
                      vjust = 0.5, size = 6.5, colour = "#1f2328") +
    ggplot2::annotate("text", x = 1, y = 0.5, label = right, hjust = 1,
                      vjust = 0.5, size = 6.5, colour = "#64748b") +
    ggplot2::xlim(0, 1) + ggplot2::ylim(0, 1) +
    ggplot2::labs(x = NULL, y = NULL) +
    ggplot2::theme_void()
}

share_plot <- function(data) {
  share_head(data) / share_curves(data) / share_foot(data) +
    patchwork::plot_layout(heights = c(1.25, 3.4, 0.85))
}

# Render to memory and return the bytes. ragg needs a filename (it does not
# accept a raw vector), so a temporary file is used and removed immediately --
# section 7.1 forbids *storing* the PNG on disk, not writing one transiently.
share_png <- function(data) {
  tf <- tempfile(fileext = ".png")
  on.exit({
    try(grDevices::dev.off(), silent = TRUE)
    unlink(tf)
  }, add = TRUE)
  ragg::agg_png(filename = tf, width = PNG_WIDTH, height = PNG_HEIGHT,
                res = 96, background = "white")
  print(share_plot(data))
  grDevices::dev.off()
  readBin(tf, what = "raw", n = file.size(tf))
}
