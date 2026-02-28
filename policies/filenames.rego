package governance.filenames

import future.keywords.if
import future.keywords.contains

# Check if file is markdown and NOT SCREAMING_SNAKE_CASE
deny contains msg if {
	endswith(input.filename, ".md")
	name_root := trim_suffix(input.filename, ".md")
	not regex.match(`^[A-Z0-9_]+$`, name_root)

	msg := {
		"id": "markdown-naming-violation",
		"level": "error",
		"message": sprintf("Markdown file '%s' must be SCREAMING_SNAKE_CASE", [input.filename]),
		"location": {"line": 1, "column": 1},
		"fix": {
			"type": "rename",
			"value": sprintf("%s.md", [upper(replace(name_root, "-", "_"))]),
		},
	}
}
