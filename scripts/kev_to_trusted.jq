# ---------------------------------------------------------------------------
# raw -> trusted transformation for the CISA KEV feed.
#
# Input : the raw KEV catalog document (one JSON object with a .vulnerabilities array)
# Output: line-delimited JSON, one object per CVE, matching the Glue schema declared
#         in parte-1/modules/data-lake/locals.tf (trusted_columns).
#
# Run with: jq -c --arg catalog_version X --arg ingested_at Y -f kev_to_trusted.jq
#
# What this actually cleans, and why (numbers measured on catalogVersion 2026.09.14):
#   * camelCase -> snake_case, so the SQL surface matches the catalog convention.
#   * Whitespace trimmed on vendor/product: 18 of 1710 rows (1.05%) carry a leading or
#     trailing space (e.g. "SimpleHelp ", " PeopleSoft Enterprise PeopleTools"). Left
#     untouched they split GROUP BY buckets and corrupt the business question's ranking.
#   * "Known"/"Unknown" and "Yes"/"No" -> real booleans, so the query uses count_if()
#     instead of comparing magic strings.
#   * cwe_count precomputed, so ranking by CWE breadth never needs array expansion.
#   * catalog_version / ingested_at stamped on every row for lineage: any result can be
#     traced back to the exact source snapshot that produced it.
# ---------------------------------------------------------------------------

def trim: if type == "string" then sub("^\\s+"; "") | sub("\\s+$"; "") else . end;
def text($k): (.[$k] // "") | tostring | trim;

.catalogVersion as $source_version
| .vulnerabilities[]
| {
    cve_id:                   text("cveID"),
    vendor_project:           text("vendorProject"),
    product:                  text("product"),
    vulnerability_name:       text("vulnerabilityName"),
    date_added:               text("dateAdded"),
    due_date:                 text("dueDate"),
    short_description:        text("shortDescription"),
    required_action:          text("requiredAction"),
    notes:                    text("notes"),

    # Booleans, not strings. Anything other than the documented positive value is
    # treated as false rather than guessed at.
    is_known_ransomware_use:  (text("knownRansomwareCampaignUse") == "Known"),
    requires_forensic_triage: (text("forensicTriage") == "Yes"),

    cwes:                     [ (.cwes // [])[] | tostring | trim ],
    cwe_count:                ((.cwes // []) | length),

    catalog_version:          ($source_version // "unknown"),
    ingested_at:              $ingested_at,
  }
