# Response-body conformance against contract/openapi.yaml (ADR-0006).
#
# The route checks in integration/ prove that the API exposes the paths the
# contract documents; nothing proved that a body still has the shape the
# contract promises. A field can be renamed, a type loosened or a required
# key dropped and every other test stays green.
#
# The contract is the single source of truth, so the check is done by a real
# JSON Schema validator (jsonvalidate + V8 running ajv) against the schemas
# extracted from the contract itself. Building our own checker would mean a
# second implementation of JSON Schema that can silently disagree with the
# first -- exactly the drift this test exists to catch.
#
# Everything here is lazy: testthat sources helper-*.R in alphabetical order,
# so this file runs before helper-load.R and must not touch api_dir,
# model_state or the database at load time.

.contract_cache <- new.env(parent = emptyenv())

# The contract lives next to api/, in every layout this repo uses (repo root,
# /app inside an image, the dev container's /root/NycTaxiApp).
contract_path <- function() {
  if (!is.null(.contract_cache$path)) return(.contract_cache$path)
  roots <- if (exists("api_dir", inherits = TRUE)) {
    c(file.path(get("api_dir", inherits = TRUE), ".."), getwd())
  } else {
    getwd()
  }
  for (root in unique(c(roots, file.path(getwd(), ".."), "..", "../.."))) {
    candidate <- file.path(root, "contract", "openapi.yaml")
    if (file.exists(candidate)) {
      .contract_cache$path <- normalizePath(candidate)
      return(.contract_cache$path)
    }
  }
  stop("contract/openapi.yaml not found from ", getwd())
}

contract_doc <- function() {
  if (is.null(.contract_cache$doc)) {
    .contract_cache$doc <- yaml::read_yaml(contract_path())
  }
  .contract_cache$doc
}

# Keywords whose JSON Schema value is always an array. yaml returns a plain
# character vector for `required: [experiment_id]`, and toJSON(auto_unbox)
# turns a length-1 vector into a scalar -- so the schema would read
# `required: "experiment_id"` and ajv would refuse to compile it ("required
# value must be array"). as.list() restores the brackets for every length,
# including zero.
.contract_array_keys <- c("required", "enum", "allOf", "anyOf", "oneOf")

# Two normalisation passes over the whole schema tree, so one schema can be
# handed to the validator on its own while its cross-references still resolve:
# "#/components/schemas/X" becomes "#/$defs/X", and the array keywords above
# keep their brackets. The validator resolves that pointer against the document
# it was given, which is the $defs root.
contract_rewrite_refs <- function(x) {
  if (!is.list(x)) return(x)
  if (!is.null(x[["$ref"]]) && is.character(x[["$ref"]])) {
    x[["$ref"]] <- sub("^#/components/schemas/", "#/$defs/", x[["$ref"]])
  }
  for (k in intersect(names(x), .contract_array_keys)) {
    if (!is.list(x[[k]])) x[[k]] <- as.list(x[[k]])
  }
  lapply(x, contract_rewrite_refs)
}

# One compiled validator per schema. jsonvalidate 1.5.0 exposes no
# `reference` argument, so each root carries the whole $defs table (shared
# schemas keep resolving) and opens with an allOf/$ref pair -- the wrapper is
# needed because draft-07 lets $ref have siblings only at the cost of ignoring
# them, and $defs has to survive that.
contract_root_for <- function(schema) {
  if (is.null(.contract_cache$roots[[schema]])) {
    .contract_cache$roots[[schema]] <- as.character(jsonlite::toJSON(
      list(
        `$defs` = contract_rewrite_refs(contract_doc()$components$schemas),
        allOf = list(list(`$ref` = paste0("#/$defs/", schema)))
      ),
      auto_unbox = TRUE
    ))
  }
  .contract_cache$roots[[schema]]
}

contract_validator <- function(schema) {
  if (is.null(.contract_cache$validators[[schema]])) {
    .contract_cache$validators[[schema]] <- jsonvalidate::json_validator(
      contract_root_for(schema), engine = "ajv", strict = FALSE
    )
  }
  .contract_cache$validators[[schema]]
}

# Validates one response body against a named components/schemas entry.
# Returns NULL when it matches, or a data frame of ajv's errors when not.
contract_errors <- function(body, schema) {
  json <- if (is.character(body)) body else
    as.character(jsonlite::toJSON(body, auto_unbox = TRUE))
  out <- contract_validator(schema)(
    json, error = FALSE, greedy = TRUE, verbose = TRUE
  )
  if (isTRUE(out)) return(NULL)
  errs <- attr(out, "errors")
  if (is.data.frame(errs)) errs else
    data.frame(message = paste(as.character(out), collapse = " "))
}

expect_contract <- function(body, schema) {
  testthat::expect_true(
    schema %in% names(contract_doc()$components$schemas),
    label = paste0("schema '", schema, "' exists in contract/openapi.yaml")
  )
  errs <- contract_errors(body, schema)
  testthat::expect_true(
    is.null(errs),
    label = paste0("body matches #/components/schemas/", schema),
    info = if (is.null(errs)) NULL else paste(
      c("ajv says:",
        utils::capture.output(print(errs, row.names = FALSE))),
      collapse = "\n"
    )
  )
}

# Looks up what the contract promises for (method, path, status).
# Returns the components/schemas name, "" when that response is documented
# without a body, or NA when the status itself is not documented at all --
# which is the case worth failing on: an undocumented status is exactly the
# sort of thing nobody notices until a client breaks.
contract_response_schema <- function(method, path, status) {
  doc <- contract_doc()
  method <- tolower(method)
  for (p in names(doc$paths)) {
    pattern <- paste0("^", gsub("\\{[^}]+\\}", "[^/]+", p), "$")
    if (!grepl(pattern, path)) next
    op <- doc$paths[[p]][[method]]
    if (is.null(op)) next
    resp <- op$responses[[as.character(status)]]
    if (is.null(resp)) return(NA_character_)
    if (!is.null(resp[["$ref"]])) {
      key <- sub(".*/", "", resp[["$ref"]])
      resp <- doc$components$responses[[key]]
    }
    sch <- resp$content[["application/json"]]$schema
    if (is.null(sch)) return("")
    return(sub("^#/components/schemas/", "", sch[["$ref"]]))
  }
  NA_character_
}

# The assertion the conformance tests are built from: a handler's response
# must document its status and its body must match the schema for it.
expect_contract_response <- function(response, method, path) {
  status <- if (is.null(response$status)) 200L else response$status
  schema <- contract_response_schema(method, path, status)
  testthat::expect_false(
    is.na(schema),
    label = sprintf(
      "%s %s answers %s, which contract/openapi.yaml does not document",
      toupper(method), path, status
    )
  )
  if (is.na(schema)) return(invisible(NULL))
  if (identical(schema, "")) return(invisible(NULL))
  testthat::expect_true(
    !is.null(response$body) && !identical(response$body, ""),
    label = sprintf("%s %s body is present", toupper(method), path)
  )
  expect_contract(response$body, schema)
}
