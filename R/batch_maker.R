# ============================================================
# batch_maker.R
# Build NotebookLM extraction batches from the codebook
# ============================================================
# Part of: Mterrapin_systematic_map
# Run from the project root (open Mterrapin_systematic_map.Rproj);
# all paths resolve through here::here().
#
# Purpose:
#   - Split included PDFs into fixed-size batches
#   - Derive 01_module_registry.csv from 03_codebook.csv
#   - Build one folder per batch containing the PDFs, resource files,
#     benchmark files and a batch manifest for upload to NotebookLM
#   - Write one runner prompt per codebook module per batch; the last
#     module (holding extractor_confidence) gets a review prompt that
#     rates each study across all earlier modules in the same chat
#   - Log run provenance (input checksums, session info)
#
# Inputs:
#   Included/*.pdf                         (not tracked; see README)
#   notebooklm_resources/
#     00_extraction_protocol.md
#     02_flag_schema.csv
#     03_codebook.csv
#     05_general_coding_rules.md
#   benchmarks/                            (optional)
#     06_benchmark_extraction.csv
#     <benchmark PDF>
#
# Generated:
#   notebooklm_resources/01_module_registry.csv
#   notebooklm_batches/
#     batch_summary.csv
#     module_registry_used_by_R.csv
#     run_log.csv
#     session_info.txt
#     text_layer_check.csv    (PDFs lacking a text layer; needs pdftools)
#     terrapin_b001/
#       04_batch_manifest.csv
#       upload_to_notebooklm/   (PDFs, 00-06 resources)
#       prompts/                (one runner prompt per module)
#
# Notes:
#   - 03_codebook.csv is the variable-level authority.
#   - Column names are case-sensitive; use study_ID, not study_id.
#   - upload_to_notebooklm/ and prompts/ are rebuilt from scratch on
#     every run so no file from a previous run can leak into a batch.
# ============================================================

library(here)
library(fs)
library(dplyr)
library(purrr)
library(readr)
library(stringr)
library(tibble)
library(glue)

# ------------------------------------------------------------
# User settings
# ------------------------------------------------------------

pdf_dir        <- here::here("Included")
resource_dir   <- here::here("notebooklm_resources")
benchmarks_dir <- here::here("benchmarks")
out_dir        <- here::here("notebooklm_batches")

project_prefix <- "terrapin"
batch_size     <- 10

# Set run_suffix manually when rerunning on the same day ("b", "c", ...)
run_suffix <- "a"
run_id     <- paste0("run_", format(Sys.Date(), "%Y%m%d"), "_", run_suffix)

module_registry_file <- fs::path(resource_dir, "01_module_registry.csv")
codebook_file        <- fs::path(resource_dir, "03_codebook.csv")

# Must exist before the script runs
required_input_resources <- c(
  "00_extraction_protocol.md",
  "02_flag_schema.csv",
  "03_codebook.csv",
  "05_general_coding_rules.md"
)

# Uploaded to NotebookLM with every batch
upload_resources <- c(
  "00_extraction_protocol.md",
  "01_module_registry.csv",
  "02_flag_schema.csv",
  "03_codebook.csv",
  "05_general_coding_rules.md"
)

# ------------------------------------------------------------
# Helper functions
# ------------------------------------------------------------

make_batch_id <- function(i, prefix = project_prefix) {
  paste0(prefix, "_b", stringr::str_pad(i, width = 3, pad = "0"))
}

split_into_batches <- function(x, size) {
  split(x, ceiling(seq_along(x) / size))
}

pad_module_order <- function(x) {
  stringr::str_pad(as.integer(x), width = 2, pad = "0")
}

safe_filename_text <- function(x) {
  x |>
    stringr::str_replace_all("[^A-Za-z0-9_\\-]+", "_") |>
    stringr::str_replace_all("_+", "_") |>
    stringr::str_remove("^_") |>
    stringr::str_remove("_$")
}

# Empty a directory without removing the directory itself
reset_dir <- function(dir) {
  if (fs::dir_exists(dir)) {
    fs::dir_delete(dir)
  }
  fs::dir_create(dir)
}

prompt_shared_sections <- "UPLOADED RESOURCES
Follow 00_extraction_protocol.md for the full task, output structure, and CSV formatting rules.
Use 03_codebook.csv as the authoritative variable-level reference.
Use 05_general_coding_rules.md for cross-variable coding conventions.
Use 02_flag_schema.csv for manual-review flag types and severity levels.
Use 01_module_registry.csv to confirm the module variables.
Use 04_batch_manifest.csv to confirm that every expected study PDF is processed.

CORE RULES
Use only uploaded PDFs, supplements, and resource files.
Do not use outside knowledge, except where 00_extraction_protocol.md or 03_codebook.csv explicitly allow it.
Do not verify links externally.
Do not create variables or response categories.
Use study_ID exactly, not study_id.

OUTPUT
Return only the two CSV outputs required by 00_extraction_protocol.md:
1. EXTRACTION_TABLE
2. MANUAL_REVIEW_FLAGS"

# Extraction modules: one prompt per module, run in module order
write_runner_prompt <- function(batch_id, run_id, module_name, module_order,
                                module_description, variable_list, out_file) {
  prompt <- glue::glue(
    "Run the structured extraction workflow for this batch and module.

BATCH INFORMATION
batch_id: {batch_id}
run_id: {run_id}
module_name: {module_name}
module_order: {module_order}

MODULE DESCRIPTION
{module_description}

VARIABLES TO EXTRACT
Extract only these variables, in exactly this order:
{variable_list}

{prompt_shared_sections}"
  )
  writeLines(prompt, out_file, useBytes = TRUE)
}

# Review module (contains extractor_confidence): run last, in the same
# NotebookLM chat as the extraction modules, so the earlier outputs are
# in the conversation history.
write_review_prompt <- function(batch_id, run_id, module_name, module_order,
                                module_description, variable_list,
                                extraction_modules, out_file) {
  prompt <- glue::glue(
    "Run the extraction review for this batch. This is the final step for the batch.

BATCH INFORMATION
batch_id: {batch_id}
run_id: {run_id}
module_name: {module_name}
module_order: {module_order}

MODULE DESCRIPTION
{module_description}

REVIEW TASK
Earlier in this chat you returned EXTRACTION_TABLE and MANUAL_REVIEW_FLAGS outputs for these modules:
{extraction_modules}

For each study PDF listed in 04_batch_manifest.csv, review all of your earlier outputs for that study together with the source PDF, and code the variables below once per study.
extractor_confidence rates the whole extraction for that study across all modules, using the definitions in 03_codebook.csv and section 8 of 05_general_coding_rules.md. Account for every manual-review flag you raised for that study in any module.
If any earlier module output for this batch is missing from this chat, or you cannot see it, code extractor_confidence as Low for every study and add a High-severity Possible extraction omission flag naming the missing module.
Do not change or re-output values from earlier modules. Record any problem you find with an earlier value as a new manual-review flag in this module's MANUAL_REVIEW_FLAGS.

VARIABLES TO EXTRACT
Extract only these variables, in exactly this order:
{variable_list}

{prompt_shared_sections}"
  )
  writeLines(prompt, out_file, useBytes = TRUE)
}

# ------------------------------------------------------------
# Safety checks
# ------------------------------------------------------------

message("Project root: ", here::here())
message("run_id: ", run_id)

if (!fs::dir_exists(pdf_dir))      stop("pdf_dir does not exist: ", pdf_dir)
if (!fs::dir_exists(resource_dir)) stop("resource_dir does not exist: ", resource_dir)

missing_resources <- required_input_resources[
  !fs::file_exists(fs::path(resource_dir, required_input_resources))
]
if (length(missing_resources) > 0) {
  stop("Missing required file(s) in notebooklm_resources/: ",
       paste(missing_resources, collapse = ", "))
}

# ------------------------------------------------------------
# Read codebook and derive module registry
# ------------------------------------------------------------

codebook <- readr::read_csv(
  codebook_file,
  col_types = readr::cols(.default = readr::col_character()),
  na = c(""),
  show_col_types = FALSE
)

required_codebook_cols <- c("module", "variable_name", "notebooklm_step")
missing_codebook_cols  <- setdiff(required_codebook_cols, names(codebook))
if (length(missing_codebook_cols) > 0) {
  stop("03_codebook.csv is missing required column(s): ",
       paste(missing_codebook_cols, collapse = ", "))
}

if (any(is.na(codebook$module) | codebook$module == "")) {
  stop("Some rows in 03_codebook.csv have missing module values.")
}
if (any(is.na(codebook$variable_name) | codebook$variable_name == "")) {
  stop("Some rows in 03_codebook.csv have missing variable_name values.")
}

dup_vars <- codebook |> count(module, variable_name) |> filter(n > 1)
if (nrow(dup_vars) > 0) {
  print(dup_vars)
  stop("Duplicate variable_name values within one or more modules in 03_codebook.csv.")
}

# Key columns are written by NotebookLM as the first three columns of
# every table; listing them again as module variables would duplicate them.
key_cols <- c("batch_id", "source_document_name", "study_ID")

# Variable order within each module follows codebook row order
module_registry <- codebook |>
  filter(!variable_name %in% key_cols) |>
  mutate(
    module_order = as.integer(stringr::str_extract(module, "^\\d+")),
    module_name  = module,
    notebooklm_step = dplyr::if_else(
      is.na(notebooklm_step) | notebooklm_step == "",
      module,
      notebooklm_step
    )
  ) |>
  group_by(module_order, module_name) |>
  summarise(
    module_description = dplyr::first(notebooklm_step),
    variable_list      = paste(variable_name, collapse = ";"),
    n_variables        = dplyr::n(),
    .groups = "drop"
  ) |>
  arrange(module_order)

if (any(is.na(module_registry$module_order))) {
  stop("Could not parse module_order from module names. ",
       "Expected module names like 01_study_identity.")
}
if (anyDuplicated(module_registry$module_order) > 0) {
  stop("Two or more modules share the same numeric prefix in 03_codebook.csv.")
}

# The review module is the one holding extractor_confidence. It must be
# the last module so the review prompt runs after every extraction module.
review_module <- codebook |>
  filter(variable_name == "extractor_confidence") |>
  pull(module) |>
  unique()

if (length(review_module) != 1) {
  stop("extractor_confidence must appear in exactly one module of 03_codebook.csv.")
}
if (review_module != dplyr::last(module_registry$module_name)) {
  stop("The module containing extractor_confidence (", review_module,
       ") must have the highest module number in 03_codebook.csv.")
}

extraction_module_list <- module_registry |>
  filter(module_name != review_module) |>
  pull(module_name) |>
  paste(collapse = "\n")

readr::write_csv(module_registry, module_registry_file)

message("Module registry derived from 03_codebook.csv:")
print(module_registry |> select(module_order, module_name, n_variables))

# ------------------------------------------------------------
# Locate PDFs
# ------------------------------------------------------------

# Radix sort gives C-locale ordering, so batch composition is
# identical on macOS, Windows and Linux.
pdf_files <- fs::dir_ls(pdf_dir, regexp = "(?i)\\.pdf$", type = "file")
pdf_files <- pdf_files[order(fs::path_file(pdf_files), method = "radix")]

if (length(pdf_files) == 0) stop("No PDF files found in: ", pdf_dir)

study_ids <- tolower(fs::path_ext_remove(fs::path_file(pdf_files)))
if (anyDuplicated(study_ids) > 0) {
  stop("PDF file names collide after lowercasing: ",
       paste(unique(study_ids[duplicated(study_ids)]), collapse = ", "))
}

message("Found ", length(pdf_files), " PDF file(s) in: ", pdf_dir)

# ------------------------------------------------------------
# Text-layer check
# ------------------------------------------------------------

# Scanned PDFs without OCR give NotebookLM nothing to read. A page with
# fewer than min_chars_per_page non-whitespace characters is counted as
# having no text; a PDF is flagged when more than max_blank_share of its
# pages have no text. Flagged PDFs are listed in text_layer_check.csv and
# noted in the batch manifest. They are not removed from batches.
min_chars_per_page <- 50
max_blank_share    <- 0.5

check_text_layer <- function(file) {
  pages <- tryCatch(
    suppressMessages(suppressWarnings(pdftools::pdf_text(file))),
    error = function(e) NULL
  )
  if (is.null(pages)) {
    return(tibble::tibble(n_pages = NA_integer_, n_blank_pages = NA_integer_,
                          text_layer_status = "unreadable"))
  }
  n_chars <- nchar(gsub("\\s", "", pages))
  n_blank <- sum(n_chars < min_chars_per_page)
  tibble::tibble(
    n_pages       = length(pages),
    n_blank_pages = n_blank,
    text_layer_status = dplyr::case_when(
      n_blank == length(pages)                  ~ "no_text_layer",
      n_blank / length(pages) > max_blank_share ~ "mostly_no_text",
      TRUE                                      ~ "ok"
    )
  )
}

if (requireNamespace("pdftools", quietly = TRUE)) {
  message("Checking PDF text layers...")
  text_layer_check <- tibble::tibble(source_document_name = fs::path_file(pdf_files)) |>
    dplyr::bind_cols(purrr::map_dfr(pdf_files, check_text_layer))

  no_text <- text_layer_check |> filter(text_layer_status != "ok")
  if (nrow(no_text) > 0) {
    warning(
      nrow(no_text), " PDF(s) have little or no text layer and need OCR before upload:\n",
      paste0("  ", no_text$source_document_name, " (", no_text$text_layer_status, ", ",
             no_text$n_blank_pages, "/", no_text$n_pages, " pages without text)",
             collapse = "\n"),
      call. = FALSE
    )
  }
} else {
  warning("Package pdftools is not installed; skipping the text-layer check. ",
          "Install it with install.packages(\"pdftools\").", call. = FALSE)
  text_layer_check <- tibble::tibble(
    source_document_name = fs::path_file(pdf_files),
    n_pages = NA_integer_, n_blank_pages = NA_integer_,
    text_layer_status = "not_checked"
  )
}

manifest_note <- function(files) {
  status <- text_layer_check$text_layer_status[
    match(fs::path_file(files), text_layer_check$source_document_name)
  ]
  dplyr::case_when(
    status == "no_text_layer"  ~ "No text layer detected; PDF may be an unOCRed scan.",
    status == "mostly_no_text" ~ "Most pages lack a text layer; PDF may be partly an unOCRed scan.",
    status == "unreadable"     ~ "PDF could not be opened by pdftools.",
    TRUE                       ~ ""
  )
}

benchmark_files <- if (fs::dir_exists(benchmarks_dir)) {
  fs::dir_ls(benchmarks_dir, type = "file", all = FALSE)
} else {
  character(0)
}

overlap <- intersect(fs::path_file(benchmark_files), fs::path_file(pdf_files))
if (length(overlap) > 0) {
  warning("Benchmark file(s) also present in Included/: ",
          paste(overlap, collapse = ", "))
}

message(
  if (length(benchmark_files) > 0) {
    paste0("Benchmark files to include in every batch: ", length(benchmark_files))
  } else {
    "No benchmark files found; batches will not include benchmarks."
  }
)

# ------------------------------------------------------------
# Prepare output folder
# ------------------------------------------------------------

fs::dir_create(out_dir)
readr::write_csv(module_registry, fs::path(out_dir, "module_registry_used_by_R.csv"))

pdf_batches <- split_into_batches(pdf_files, batch_size)
batch_ids   <- make_batch_id(seq_along(pdf_batches))

# Warn about batch folders left over from a run with more PDFs
existing_batches <- fs::path_file(
  fs::dir_ls(out_dir, type = "directory",
             regexp = paste0(project_prefix, "_b\\d{3}$"))
)
orphans <- setdiff(existing_batches, batch_ids)
if (length(orphans) > 0) {
  warning("Batch folder(s) from a previous run are not part of this run: ",
          paste(orphans, collapse = ", "),
          ". Delete them before uploading.")
}

# ------------------------------------------------------------
# Build each batch folder
# ------------------------------------------------------------

batch_summary <- purrr::imap_dfr(pdf_batches, function(batch_files, batch_index) {

  batch_id    <- make_batch_id(as.integer(batch_index))
  batch_dir   <- fs::path(out_dir, batch_id)
  upload_dir  <- fs::path(batch_dir, "upload_to_notebooklm")
  prompts_dir <- fs::path(batch_dir, "prompts")

  # Rebuild from scratch: removes stale PDFs, old benchmarks and
  # prompts for renamed or deleted modules.
  reset_dir(upload_dir)
  reset_dir(prompts_dir)

  fs::file_copy(batch_files, fs::path(upload_dir, fs::path_file(batch_files)))
  fs::file_copy(fs::path(resource_dir, upload_resources),
                fs::path(upload_dir, upload_resources))
  if (length(benchmark_files) > 0) {
    fs::file_copy(benchmark_files,
                  fs::path(upload_dir, fs::path_file(benchmark_files)))
  }

  manifest <- tibble::tibble(
    batch_id             = batch_id,
    run_id               = run_id,
    source_document_name = fs::path_file(batch_files),
    expected_study_ID    = tolower(fs::path_ext_remove(fs::path_file(batch_files))),
    source_type          = "main_pdf",
    notes                = manifest_note(batch_files)
  )
  readr::write_csv(manifest, fs::path(upload_dir, "04_batch_manifest.csv"))
  readr::write_csv(manifest, fs::path(batch_dir, "04_batch_manifest.csv"))

  purrr::pwalk(
    module_registry,
    function(module_order, module_name, module_description, variable_list, n_variables) {
      prompt_file <- fs::path(
        prompts_dir,
        paste0(batch_id, "_m", pad_module_order(module_order), "_",
               safe_filename_text(module_name), "_runner_prompt.txt")
      )
      if (module_name == review_module) {
        write_review_prompt(batch_id, run_id, module_name, module_order,
                            module_description, variable_list,
                            extraction_module_list, prompt_file)
      } else {
        write_runner_prompt(batch_id, run_id, module_name, module_order,
                            module_description, variable_list, prompt_file)
      }
    }
  )

  tibble::tibble(
    batch_id     = batch_id,
    run_id       = run_id,
    n_pdfs       = length(batch_files),
    n_benchmarks = length(benchmark_files),
    n_modules    = nrow(module_registry),
    # Relative paths so the summary is portable across machines
    batch_dir    = fs::path_rel(batch_dir, here::here()),
    upload_dir   = fs::path_rel(upload_dir, here::here()),
    prompts_dir  = fs::path_rel(prompts_dir, here::here())
  )
})

readr::write_csv(batch_summary, fs::path(out_dir, "batch_summary.csv"))
readr::write_csv(text_layer_check, fs::path(out_dir, "text_layer_check.csv"))

# ------------------------------------------------------------
# Provenance log
# ------------------------------------------------------------

logged_inputs <- c(
  fs::path(resource_dir, c(required_input_resources, "01_module_registry.csv")),
  benchmark_files
)

run_log <- tibble::tibble(
  run_id    = run_id,
  run_time  = format(Sys.time(), "%Y-%m-%d %H:%M:%S %Z"),
  file      = fs::path_rel(logged_inputs, here::here()),
  md5       = unname(tools::md5sum(logged_inputs)),
  n_pdfs    = length(pdf_files),
  n_batches = length(pdf_batches),
  batch_size = batch_size
)
readr::write_csv(run_log, fs::path(out_dir, "run_log.csv"))

writeLines(capture.output(sessionInfo()), fs::path(out_dir, "session_info.txt"))

message("Done.")
message("Wrote ", nrow(batch_summary), " batch folder(s) to: ", out_dir)
message("Generated ", nrow(module_registry), " runner prompt(s) per batch.")

print(batch_summary)
