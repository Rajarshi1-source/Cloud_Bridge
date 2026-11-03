# Both cells stay in Mumbai: a fair cost comparison and one data residency story.
package main

import rego.v1

allowed_regions := {"ap-south-1", "asia-south1", "asia-south1-a", "ASIA-SOUTH1", "global"}

deny contains msg if {
	some rc in input.resource_changes
	creates_or_updates(rc)
	some attribute in ["region", "location"]
	region := rc.change.after[attribute]
	is_string(region)
	region != ""
	not region in allowed_regions
	msg := sprintf("%s targets %s, and CloudBridge keeps both cells in Mumbai", [rc.address, region])
}
