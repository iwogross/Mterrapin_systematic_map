# ============================================================
# fuse_notebook.R
# Fuse NotebookLM extraction outputs, one workbook per batch
# ============================================================
# Part of: Mterrapin_systematic_map
# Run from the project root (open Mterrapin_systematic_map.Rproj);
# all paths resolve through here::here().
#
# Purpose:
#   - Read one extraction CSV and one flag CSV per module
#   - Repair known NotebookLM CSV formatting errors
#   - Standardise key columns and join module outputs by study
#   - Check outputs against the codebook and the batch manifest
#   - Write one Excel workbook per batch for manual review
#
# Inputs (raw NotebookLM outputs, saved as returned):
#   notebook_outputs/b001/
#     b001_1.csv          extraction table, module 1
#     b001_1_flag.csv     manual-review flags, module 1
#     ...
#   The folder and file prefix may also be the full batch ID
#   (terrapin_b001/terrapin_b001_1.csv).
#
#   notebooklm_resources/01_module_registry.csv  (from batch_maker.R)
#   notebooklm_resources/03_codebook.csv
#   notebooklm_batches/<batch_id>/04_batch_manifest.csv
#
# Output:
#   fused_extractions/<batch_id>_fused_extraction.xlsx
#
# Conventions:
#   - Join keys: batch_id, source_document_name, study_ID.
#   - study_ID, not study_id.
#   - run_id is metadata, taken from the batch manifest; never a join key.
#   - Literal "NA" is kept as text because it is codebook vocabulary.
# ============================================================

library(here)
library(fs)
library(dplyr)
library(purrr)
library(readr)
library(stringr)
library(tibble)
library(openxlsx)

# ------------------------------------------------------------
# User settings
# ------------------------------------------------------------

# TRUE fuses every subfolder of notebook_outputs/.
# FALSE fuses only batch_folder.
run_all      <- TRUE
batch_folder <- "b002"

project_prefix <- "terrapin"   # must match batch_maker.R

outputs_root <- here::here("notebook_outputs")
batches_root <- here::here("notebooklm_batches")
resource_dir <- here::here("notebooklm_resources")
fused_dir    <- here::here("fused_extractions")

module_registry_file <- fs::path(resource_dir, "01_module_registry.csv")
codebook_file        <- fs::path(resource_dir, "03_codebook.csv")

# Used only if 01_module_registry.csv is missing
fallback_expected_modules <- 1:8

join_keys <- c("batch_id", "source_document_name", "study_ID")

flag_cols <- c(
  "batch_id",
  "source_document_name",
  "study_ID",
  "variable_name",
  "flag_type",
  "flag_severity",
  "extracted_value",
  "reason_for_flag",
  "evidence_location_or_quote",
  "suggested_manual_action"
)

helper_cols <- c(".module_number", ".module_label", ".source_file")

# ------------------------------------------------------------
# Helper functions
# ------------------------------------------------------------

regex_escape <- function(x) {
  stringr::str_replace_all(x, "([\\\\.^$|()\\[\\]{}*+?])", "\\\\\\1")
}

sort_c <- function(x) x[order(x, method = "radix")]

# "b001" and "terrapin_b001" both resolve to "terrapin_b001"
canonical_batch_id <- function(bf) {
  if (stringr::str_starts(bf, paste0(project_prefix, "_"))) bf
  else paste0(project_prefix, "_", bf)
}

# Known NotebookLM CSV bug: four consecutive quotes before a comma
# should be three. Occurs when a cell value ends with a quotation mark.
repair_trailing_quotes <- function(raw_text) {
  stringr::str_replace_all(raw_text, '"""",', '""",')
}

clean_colnames <- function(x) {
  names(x) <- stringr::str_trim(names(x))
  renames <- c(
    study_ID             = "study_id",
    batch_id             = "Batch_ID",
    source_document_name = "Source_document_name"
  )
  for (new in names(renames)) {
    old <- renames[[new]]
    if (old %in% names(x) && !new %in% names(x)) {
      names(x)[names(x) == old] <- new
    }
  }
  x
}

file_pattern <- function(prefix, flag) {
  paste0("^", regex_escape(prefix), "_(\\d+)", if (flag) "_flag" else "", "\\.csv$")
}

get_module_number <- function(file, prefix) {
  as.integer(stringr::str_match(
    fs::path_file(file),
    paste0("^", regex_escape(prefix), "_(\\d+)(?:_flag)?\\.csv$")
  )[, 2])
}

is_flag_file <- function(file, prefix) {
  stringr::str_detect(fs::path_file(file), file_pattern(prefix, flag = TRUE))
}

is_extraction_file <- function(file, prefix) {
  stringr::str_detect(fs::path_file(file), file_pattern(prefix, flag = FALSE))
}

read_chr_csv <- function(file) {
  readr::read_csv(
    file,
    col_types      = readr::cols(.default = readr::col_character()),
    na             = c(""),
    show_col_types = FALSE,
    progress       = FALSE
  )
}

read_module_registry <- function(file) {
  if (!fs::file_exists(file)) {
    warning("01_module_registry.csv not found; run batch_maker.R first. ",
            "Using fallback modules: ", paste(fallback_expected_modules, collapse = ", "))
    return(tibble(
      module_order       = fallback_expected_modules,
      module_name        = paste0("module_", stringr::str_pad(fallback_expected_modules, 2, pad = "0")),
      module_description = NA_character_,
      variable_list      = NA_character_,
      n_variables        = NA_character_
    ))
  }
  x <- read_chr_csv(file)
  if (!"module_order" %in% names(x)) stop("01_module_registry.csv is missing module_order.")
  x |> mutate(module_order = as.integer(module_order)) |> arrange(module_order)
}

read_codebook <- function(file) {
  if (!fs::file_exists(file)) {
    warning("03_codebook.csv not found. Skipping codebook-based variable checks.")
    return(NULL)
  }
  read_chr_csv(file)
}

# Manifest written by batch_maker.R; source of run_id and expected studies
read_manifest <- function(batch_id) {
  candidates <- c(
    fs::path(batches_root, batch_id, "04_batch_manifest.csv"),
    fs::path(batches_root, batch_id, "upload_to_notebooklm", "04_batch_manifest.csv")
  )
  file <- candidates[fs::file_exists(candidates)][1]
  if (is.na(file)) {
    warning("04_batch_manifest.csv not found for ", batch_id,
            ". run_id will be NA and the coverage check is skipped.")
    return(NULL)
  }
  read_chr_csv(file)
}

read_notebook_csv <- function(file, ctx) {
  message("Reading: ", fs::path_file(file))

  x <- readr::read_file(file) |>
    repair_trailing_quotes() |>
    I() |>
    read_chr_csv() |>
    clean_colnames()

  if (!"source_document_name" %in% names(x)) {
    alt <- intersect(
      c("source_document", "source_file", "document_name",
        "pdf_name", "pdf_file", "file_name", "source"),
      names(x)
    )
    if (length(alt) > 0) {
      x <- dplyr::rename(x, source_document_name = dplyr::all_of(alt[1]))
    }
  }

  # batch_id is fixed by the folder, not by NotebookLM. Overwriting it
  # prevents a mis-typed batch_id in one module from splitting rows.
  if ("batch_id" %in% names(x) && any(x$batch_id != ctx$batch_id, na.rm = TRUE)) {
    warning("batch_id in ", fs::path_file(file), " differs from ", ctx$batch_id,
            "; standardised.")
  }
  x$batch_id <- ctx$batch_id

  # Trim whitespace in keys so stray spaces do not break joins
  for (k in intersect(c("source_document_name", "study_ID"), names(x))) {
    x[[k]] <- stringr::str_trim(x[[k]])
  }

  x$run_id <- ctx$run_id

  module_n <- get_module_number(file, ctx$prefix)
  x |>
    mutate(
      .module_number = module_n,
      .module_label  = paste0("module_", stringr::str_pad(module_n, 2, pad = "0")),
      .source_file   = fs::path_file(file)
    )
}

ensure_join_keys <- function(x, file) {
  missing_keys <- setdiff(join_keys, names(x))
  if (length(missing_keys) > 0) {
    stop("Missing required join key(s) after repair: ",
         paste(missing_keys, collapse = ", "), "\nFile: ", file)
  }
  x
}

ensure_flag_cols <- function(x, file) {
  missing_cols <- setdiff(flag_cols, names(x))
  if (length(missing_cols) > 0) {
    warning("Flag file is missing column(s): ", paste(missing_cols, collapse = ", "),
            "\nFile: ", file, "\nMissing columns are filled with \"NA\".")
    for (col in missing_cols) x[[col]] <- "NA"
  }
  x |> select(all_of(flag_cols), any_of(c("run_id", helper_cols)), everything())
}

safe_full_join <- function(x, y) {
  y <- y |> select(-any_of("run_id"))
  overlapping <- intersect(setdiff(names(x), join_keys), setdiff(names(y), join_keys))
  if (length(overlapping) > 0) {
    warning("Overlapping non-key columns: ", paste(overlapping, collapse = ", "),
            ". Both versions kept with .x/.y suffixes.")
  }
  full_join(x, y, by = join_keys)
}

make_file_inventory <- function(csv_files, prefix) {
  tibble(
    file          = fs::path_file(csv_files),
    module_number = purrr::map_int(csv_files, get_module_number, prefix = prefix),
    file_type     = dplyr::case_when(
      purrr::map_lgl(csv_files, is_flag_file, prefix = prefix)       ~ "flag",
      purrr::map_lgl(csv_files, is_extraction_file, prefix = prefix) ~ "extraction",
      TRUE                                                           ~ "unrecognised"
    )
  ) |>
    arrange(module_number, file_type, file)
}

expected_variables_for_module <- function(module_number, codebook) {
  if (is.null(codebook) || !all(c("module", "variable_name") %in% names(codebook))) {
    return(character())
  }
  pattern <- paste0("^", stringr::str_pad(module_number, 2, pad = "0"), "(_|$)")
  codebook |>
    filter(stringr::str_detect(module, pattern)) |>
    pull(variable_name) |>
    unique() |>
    setdiff(join_keys)
}

make_module_output_check <- function(file, x, codebook, prefix) {
  module_n      <- get_module_number(file, prefix)
  expected_vars <- expected_variables_for_module(module_n, codebook)
  present_vars  <- setdiff(names(x), c(join_keys, "run_id", helper_cols))
  tibble(
    source_file                = fs::path_file(file),
    module_number              = module_n,
    n_expected_variables       = length(expected_vars),
    n_present_variables        = length(present_vars),
    missing_expected_variables = paste(setdiff(expected_vars, present_vars), collapse = "; "),
    unexpected_variables       = paste(setdiff(present_vars, expected_vars), collapse = "; "),
    order_matches_codebook     = identical(intersect(present_vars, expected_vars),
                                           intersect(expected_vars, present_vars))
  )
}

# Compares the fused table against the manifest on both document name
# and study_ID, so a renamed or mistyped study_ID is caught.
make_coverage_check <- function(extraction_fused, manifest) {
  empty <- tibble(
    source_document_name = character(),
    expected_study_ID    = character(),
    extracted_study_ID   = character(),
    coverage_status      = character()
  )
  if (is.null(manifest) ||
      !all(c("source_document_name", "expected_study_ID") %in% names(manifest))) {
    return(empty)
  }

  expected <- manifest |>
    distinct(source_document_name, expected_study_ID) |>
    mutate(.in_manifest = TRUE)

  present <- extraction_fused |>
    distinct(source_document_name, extracted_study_ID = study_ID) |>
    mutate(.in_extraction = TRUE)

  full_join(expected, present, by = "source_document_name") |>
    mutate(
      .in_manifest   = dplyr::coalesce(.in_manifest, FALSE),
      .in_extraction = dplyr::coalesce(.in_extraction, FALSE),
      coverage_status = dplyr::case_when(
        .in_manifest & !.in_extraction ~ "missing_from_extraction",
        !.in_manifest & .in_extraction ~ "unexpected_in_workspace",
        is.na(extracted_study_ID) |
          expected_study_ID != extracted_study_ID ~ "study_ID_mismatch",
        TRUE ~ "processed"
      )
    ) |>
    select(-.in_manifest, -.in_extraction) |>
    arrange(coverage_status, source_document_name)
}

add_sheet <- function(wb, name, data) {
  openxlsx::addWorksheet(wb, name)
  openxlsx::writeData(wb, name, data)
  openxlsx::freezePane(wb, name, firstRow = TRUE)
  if (ncol(data) > 0) {
    openxlsx::setColWidths(wb, name, cols = seq_len(ncol(data)), widths = "auto")
  }
}

# ------------------------------------------------------------
# Shared resources
# ------------------------------------------------------------

module_registry <- read_module_registry(module_registry_file)
codebook        <- read_codebook(codebook_file)

expected_modules <- sort(unique(stats::na.omit(module_registry$module_order)))
if (length(expected_modules) == 0) expected_modules <- fallback_expected_modules

# ------------------------------------------------------------
# fuse_one_batch()
# ------------------------------------------------------------

fuse_one_batch <- function(bf) {

  batch_dir <- fs::path(outputs_root, bf)
  batch_id  <- canonical_batch_id(bf)
  manifest  <- read_manifest(batch_id)

  run_id <- if (!is.null(manifest) && "run_id" %in% names(manifest)) {
    unique(manifest$run_id)[1]
  } else {
    NA_character_
  }

  ctx <- list(prefix = bf, batch_id = batch_id, run_id = run_id)

  message("\n", strrep("=", 60))
  message("Fusing batch: ", batch_id, " (folder ", bf, ", ", run_id, ")")
  message(strrep("=", 60))

  if (!fs::dir_exists(batch_dir)) {
    warning("Batch directory does not exist, skipping: ", batch_dir)
    return(invisible(NULL))
  }

  csv_files <- sort_c(fs::dir_ls(batch_dir, regexp = "(?i)\\.csv$", type = "file"))
  if (length(csv_files) == 0) {
    warning("No CSV files in ", batch_dir, "; skipping.")
    return(invisible(NULL))
  }

  file_inventory <- make_file_inventory(csv_files, bf)
  print(file_inventory)

  unrecognised <- file_inventory |> filter(file_type == "unrecognised")
  if (nrow(unrecognised) > 0) {
    warning("CSV file(s) not matching ", bf, "_<module>.csv or ", bf,
            "_<module>_flag.csv:\n", paste(unrecognised$file, collapse = "\n"))
  }

  by_module <- function(files) files[order(purrr::map_int(files, get_module_number, prefix = bf))]
  extraction_files <- by_module(csv_files[purrr::map_lgl(csv_files, is_extraction_file, prefix = bf)])
  flag_files       <- by_module(csv_files[purrr::map_lgl(csv_files, is_flag_file, prefix = bf)])

  if (length(extraction_files) == 0) {
    warning("No extraction CSVs for ", bf, "; skipping.")
    return(invisible(NULL))
  }

  missing_ext  <- setdiff(expected_modules, purrr::map_int(extraction_files, get_module_number, prefix = bf))
  missing_flag <- setdiff(expected_modules, purrr::map_int(flag_files, get_module_number, prefix = bf))
  if (length(missing_ext) > 0) {
    warning("Missing extraction CSVs for module(s): ", paste(missing_ext, collapse = ", "))
  }
  if (length(missing_flag) > 0) {
    warning("Missing flag CSVs for module(s): ", paste(missing_flag, collapse = ", "))
  }

  # ---- Extraction tables ----

  extraction_list <- purrr::map(extraction_files, function(file) {
    read_notebook_csv(file, ctx) |> ensure_join_keys(file)
  })

  module_output_check <- purrr::map2_dfr(
    extraction_files, extraction_list,
    make_module_output_check, codebook = codebook, prefix = bf
  )

  extraction_fused <- extraction_list |>
    purrr::map(\(x) select(x, -any_of(helper_cols))) |>
    purrr::reduce(safe_full_join) |>
    select(any_of(c(join_keys, "run_id")), everything()) |>
    arrange(source_document_name, study_ID)

  # ---- Flag tables ----

  flags_fused <- if (length(flag_files) > 0) {
    purrr::map_dfr(flag_files, \(file) read_notebook_csv(file, ctx) |> ensure_flag_cols(file)) |>
      arrange(source_document_name, study_ID, variable_name)
  } else {
    tibble(!!!setNames(rep(list(character()), length(flag_cols)), flag_cols))
  }

  # ---- Checks ----

  message("Rows in fused extraction table: ", nrow(extraction_fused))
  message("Rows in fused flags table:      ", nrow(flags_fused))

  dup_rows <- extraction_fused |> count(across(all_of(join_keys))) |> filter(n > 1)
  if (nrow(dup_rows) > 0) {
    warning("Duplicate joined rows in ", batch_id, ". See sheet duplicate_key_check.")
  }

  n_high <- sum(tolower(flags_fused$flag_severity) == "high", na.rm = TRUE)
  if (n_high > 0) message("High-severity flags: ", n_high)

  coverage_check <- make_coverage_check(extraction_fused, manifest)
  if (any(coverage_check$coverage_status != "processed")) {
    warning("Coverage issues in ", batch_id, ". See sheet coverage_check.")
  }

  # ---- Workbook ----

  fs::dir_create(fused_dir)
  out_xlsx <- fs::path(fused_dir, paste0(batch_id, "_fused_extraction.xlsx"))

  wb <- openxlsx::createWorkbook()
  add_sheet(wb, "extraction_fused",    extraction_fused)
  add_sheet(wb, "manual_review_flags", flags_fused)
  add_sheet(wb, "coverage_check",      coverage_check)
  add_sheet(wb, "module_output_check", module_output_check)
  add_sheet(wb, "file_inventory",      file_inventory)
  add_sheet(wb, "duplicate_key_check", dup_rows)
  add_sheet(wb, "module_registry",     module_registry)
  openxlsx::saveWorkbook(wb, out_xlsx, overwrite = TRUE)

  message("Wrote: ", fs::path_rel(out_xlsx, here::here()))
  invisible(out_xlsx)
}

# ------------------------------------------------------------
# Dispatch
# ------------------------------------------------------------

if (!fs::dir_exists(outputs_root)) {
  stop("notebook_outputs/ not found. Save NotebookLM CSVs to ",
       "notebook_outputs/<batch>/ before running this script.")
}

if (run_all) {
  batch_folders <- sort_c(fs::path_file(fs::dir_ls(outputs_root, type = "directory")))
  if (length(batch_folders) == 0) stop("No batch folders found in: ", outputs_root)
  message("Fusing ", length(batch_folders), " batch(es): ", paste(batch_folders, collapse = ", "))
  purrr::walk(batch_folders, fuse_one_batch)
  message("\nAll batches complete.")
} else {
  fuse_one_batch(batch_folder)
}
