# Every resource that can carry labels carries the four the cost ledger and the parity check join on.
package main

import rego.v1

required := {"cb-cell", "cb-cloud", "cb-env", "managed-by"}

creates_or_updates(rc) if "create" in rc.change.actions

creates_or_updates(rc) if "update" in rc.change.actions

# The attribute that holds the merged tags: a resource without one can't be tagged, so it is skipped.
tags(rc) := t if {
	t := rc.change.after.tags_all
} else := t if {
	t := rc.change.after.terraform_labels
} else := t if {
	t := rc.change.after.labels
} else := t if {
	t := rc.change.after.resource_labels
}

deny contains msg if {
	some rc in input.resource_changes
	creates_or_updates(rc)
	t := tags(rc)
	missing := required - {k | t[k]}
	count(missing) > 0
	msg := sprintf("%s is missing labels/tags %v", [rc.address, sort(missing)])
}
