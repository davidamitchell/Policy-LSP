package governance.content

import future.keywords.if
import future.keywords.contains

# Non-test Go files must begin with a comment (copyright notice or package doc).
#
# A file "begins with a comment" when its first non-whitespace characters are
# either // (line comment) or /* (block comment). Test files ending in _test.go
# are exempt because they do not typically carry package-level documentation.
#
# The `^\s*` prefix in file_starts_with_comment intentionally permits optional
# leading whitespace (including blank lines) before the comment. In practice
# Go files should not have leading blank lines, but allowing them here avoids
# false positives if a file has a trailing newline or BOM artefact.
deny contains msg if {
	input.extension == ".go"
	not endswith(input.filename, "_test.go")
	not file_starts_with_comment
	msg := {
		"id":      "missing-package-comment",
		"level":   "warning",
		"message": sprintf("Go file '%s' should begin with a package comment", [input.filename]),
		"location": {"line": 1, "column": 1},
	}
}

# file_starts_with_comment is true when the file opens with a line comment.
file_starts_with_comment if {
	regex.match(`^\s*//`, input.file_contents)
}

# file_starts_with_comment is true when the file opens with a block comment.
file_starts_with_comment if {
	regex.match(`^\s*/\*`, input.file_contents)
}
