# .gitignore ignores `*.html` (it comes from the Quarto/RMarkdown template,
# where HTML is build output). These two are not build output -- they are
# served at runtime -- so they carry an explicit negation, and this test is
# what stops someone from deleting it and shipping a 404.

RUNTIME_HTML <- c(
  "app/www/privacy.html",              # 9.1, mandatory before publishing
  "infra/nginx/html/capacity-full.html" # 8.2, served on an upstream 503
)

test_that("the runtime HTML pages are present on disk", {
  for (f in RUNTIME_HTML) {
    expect_true(file.exists(file.path(repo_root, f)), label = f)
  }
})

test_that("and they are tracked by git, not swallowed by *.html", {
  skip_if_not(dir.exists(file.path(repo_root, ".git")), "not a git checkout")
  # nix/system.nix deliberately ships no git (it is a layer the images reuse),
  # so this runs on a workstation and in CI -- exactly where a fresh checkout
  # would be missing the file.
  skip_if_not(nzchar(Sys.which("git")),
              "git is not on the PATH in the Nix shell")
  tracked <- system2("git",
                     c("-C", repo_root, "ls-files", "--", "app", "infra"),
                     stdout = TRUE, stderr = FALSE)
  tracked <- tracked[grepl("\\.html$", tracked)]
  for (f in RUNTIME_HTML) {
    expect_true(f %in% tracked,
                label = paste(f, "-- a fresh checkout would 404 it"))
  }
})
