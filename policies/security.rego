package governance.security

import future.keywords.if
import future.keywords.contains

# Deny files that appear to contain hardcoded credentials.
#
# This policy scans file_contents for common patterns where a credential-named
# variable is assigned a literal string value that looks like an actual secret
# (long alphanumeric string, not a placeholder).
#
# Patterns matched (case-insensitive):
#   api_key = "actual_value"
#   api-key: "actual_value"
#   access_token = "actual_value"
#   secret_key = "actual_value"
#   password = "actual_value"
#
# Excluded file types:
#   *.example  *.template  *.sample  *.test  *_test.go
#   (These commonly contain placeholder values for documentation or testing.)

deny contains msg if {
    # Only scan source and config files (not binaries or lock files).
    not is_excluded_file
    regex.match(
        `(?i)"?(api[_-]?key|api[_-]?secret|access[_-]?token|secret[_-]?key|client[_-]?secret|password|passwd)"?\s*[:=]\s*["'][a-zA-Z0-9+/\-_]{20,}["']`,
        input.file_contents,
    )
    msg := {
        "id":      "hardcoded-credential",
        "level":   "error",
        "message": sprintf(
            "Potential hardcoded credential in '%v'. Store secrets in environment variables, not source code.",
            [input.filename],
        ),
        "location": {"line": 1, "column": 1},
    }
}

# is_excluded_file returns true for file types that are expected to contain
# credential-shaped strings for legitimate reasons (examples, tests, docs).
is_excluded_file if {
    regex.match(`\.(example|template|sample)$`, input.filename)
}

is_excluded_file if {
    endswith(input.filename, "_test.go")
}

is_excluded_file if {
    input.filename == "go.sum"
}
