# Shiny's loadSupport() would otherwise source every top-level file in this
# directory into the environment that app.R is evaluated in, leaving two
# copies of every object -- including `constants_state`, which has to be
# exactly one. ADR-0007: the package is loaded once, by app.R itself
# (library() in the image, pkgload::load_all() in development).
#
# This file exists purely to be found by loadSupport()'s
# `^_disable_autoload\.r$` check, which returns before sourcing anything.
# Do not rename it, and do not put code in it: R sources it like any other
# file of the package.
