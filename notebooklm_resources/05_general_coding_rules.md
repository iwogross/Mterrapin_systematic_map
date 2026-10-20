# General coding rules for NotebookLM extraction

These rules supplement `03_codebook.csv`. The codebook remains the authoritative variable-level reference. Use these rules only for cross-variable conventions that recur across modules.

## 1. Source hierarchy
Use only the uploaded study PDFs, uploaded supplementary materials, and extraction resources in the NotebookLM workspace. Do not use outside knowledge, unless explicitly allowed by `03_codebook.csv` or by section 9 of these rules. Do not externally verify URLs, DOIs, repository records, or accession numbers during extraction. Extract reported data and code locations exactly as stated and flag them for later verification when required.

If benchmark materials are present in the workspace (`06_benchmark_extraction.csv` and associated benchmark PDFs), use them to calibrate output formatting and to inform how nuanced or complex variables are classified in practice. Do not use them to infer allowed values or variable definitions. If any conflict arises between the benchmark data and `03_codebook.csv` or these rules, follow `03_codebook.csv` and these rules.

## 2. Missing and uncertainty values
Use missing values consistently, if definitions are not explicitly stated within `03_codebook.csv`.

- `Not reported` = the source does not mention the information required for that variable.
- `Unclear` = the source mentions the relevant topic, but the correct value cannot be determined from the source.
- `NA` = the variable does not apply to this study, record type, or module.
- `Partially` = some, but not all, required information is reported, or the criterion is met for only part of the study.
- `No` = the source clearly does not report or does not satisfy the criterion.
- `Yes` = the source clearly reports or satisfies the criterion.
- `Not assessed` = the variable is filled manually after extraction. Enter it only for variables whose `machine_rule` in `03_codebook.csv` says so (`extractor`, `extraction_date`, `n_citations`, `n_policy_citations`), and always enter it for those variables.

Do not leave blank cells.

## 3. Multi-response fields
If `multi_response_allowed = Yes`, record multiple valid values separated by semicolons. Do not create new categories outside the allowed values. If several values are possible but the correct coding is uncertain, extract the best-supported value and add a manual-review flag.

## 4. Affiliation state fields
For `corr_author_state` and `all_state`, record all reported states for the relevant author or authors if multiple affiliations are listed. Separate states with semicolons. Do not infer states from outside knowledge or email domains alone.

## 5. Count variables
Count only the unit specified in the codebook definition. Do not substitute numbers of search records, screened records, raw observations, species, sites, datasets, or included studies unless the variable explicitly asks for that unit.

## 6. Reported but not verified links and repositories
Extract URLs, DOIs, accession numbers, repository names, data/code locations, and access statements exactly as reported. During NotebookLM extraction, code location-verification fields as `Not attempted` unless a separate verification step is explicitly being performed in the same workspace. Add a manual-review flag for later verification when the reported location affects reproducibility coding.

## 7. Source-grounding variables and flagging

Variables ending in `_text` (e.g., `research_scope_text`) are source-grounding companions defined in `03_codebook.csv`. Each must immediately follow its named parent variable in the extraction table. Populate each `_text` cell with a direct quote and page citation from the source PDF to facilitate human validation. Format citations as `[filename; pg. X]: 'quote'`, where `filename` is the exact PDF filename including `.pdf`. If a quote spans multiple pages or passages, separate them with an ellipsis (e.g., `[smith_2005_copeia.pdf; pg. 4-5, 8]: 'Quote1a... Quote1b...'`). Keep the total content of each `_text` cell under 100 words.

When the parent variable is `No`, `Not reported`, or `NA` because the source contains nothing to quote, enter `Not found` in the `_text` cell without a manual-review flag. When the parent variable has any other value and no supporting text can be located, enter `Not found` and add a manual-review flag.

For items where evidence is weak, missing, conflicting, or ambiguous in any variable, extract the best-supported value and add a manual-review flag in `MANUAL_REVIEW_FLAGS`. Include a short quote, page, section, table, figure, or supplement reference when possible.

## 8. Paper-level extraction confidence
`extractor_confidence` is confidence in the extraction for one paper across all extraction modules, coded once in the final review module after those modules have been run in the same chat. It is not confidence in the study conclusions. Use:

- `High` when most values are explicit, source-supported, and map cleanly to the codebook with no major conflicts.
- `Medium` when extraction is mostly supported but some values require interpretation, synthesis across sections, or minor flags.
- `Low` when important values are ambiguous, conflicting, missing, or require substantial judgement, or when high-severity manual-review flags are needed.

Variable-specific uncertainty belongs in `MANUAL_REVIEW_FLAGS`.

## 9. Spatial coordinates (spatial_frame_start / spatial_frame_end)
For `spatial_frame_start` and `spatial_frame_end`, provide decimal degree coordinates even when exact coordinates are not reported in the source. When the source names a location but does not give coordinates, use outside knowledge to derive the coordinates for that location, and begin the companion `_text` cell with `Derived from location name:` followed by the location name or description from the source. When the source reports coordinates, quote them in the `_text` cell as in section 7. If no geographic information of any kind is present in the source, enter `Not reported`.

## 10. Conflict-of-interest field consistency
Use the following standard pattern for the conflict-of-interest variable cluster to ensure consistency across papers:

| Scenario | `conflict_of_interest_reported` | `conflict_of_interest_type` | `_text` fields |
|---|---|---|---|
| No COI statement present | `No` | `Not reported` | `Not found` |
| COI statement present, no conflicts declared | `Yes` | `No competing interests declared` | quote from source |
| COI statement present, conflict disclosed | `Yes` | appropriate type(s) | quote from source |
| Statement present but uninterpretable | `Unclear` | `Statement present but details unclear` | quote from source |

Do not mix `No` and `Not reported` within the same field across rows. `No` belongs in the `reported` field (meaning the paper has no statement); `Not reported` belongs in the `type` field (meaning the type is unknown because nothing was stated). `Not found` in the `_text` fields does not require a manual-review flag (section 7).

## 11. Conservation scope: direct aims only
Record `conservation_scope` values only when the conservation topic is directly addressed as an active subject of investigation, data collection, or intervention in the methods or results. Do not record conservation values based on:
- implications or relevance mentioned in the introduction or discussion;
- future directions statements;
- general sentences about the species' conservation status.

A study must actively collect data on, evaluate, or implement the conservation action to receive that code. If no conservation topic meets this standard, enter `NA`.

## 12. Corresponding author
If no corresponding author is explicitly designated in the paper (e.g., marked with an asterisk, footnote, or "corresponding author" label), enter `Not reported` for `corr_author` and `corr_author_state`. Do not infer corresponding authorship from email address placement alone. Do not default to the first or last author. Exception: for a single-author paper, code the sole author as the corresponding author.

## 13. Source-grounding quote length and species specificity
When populating `_text` companion fields, the quoted passage must be long enough to confirm that the data, observation, or finding being coded pertains specifically to terrapins, not to another species incidentally mentioned in the same study. A quote that describes data collected from a non-terrapin taxon is not valid evidence for coding a variable, even if terrapins are referenced elsewhere in the paper. If no sufficiently specific terrapin-relevant passage can be found to support a value, enter `Not found` and flag for review rather than using a passage that only partially supports the classification.

## 14. Author affiliations: ignore present and current address lines
When extracting author affiliation information for `affil_corr`, `affils_all`, and `all_state`, use only the institutional affiliation listed at the time of publication. Ignore any lines labelled "current address", "present address", "permanent address", or equivalent. These post-publication addresses are not the affiliation of record.
