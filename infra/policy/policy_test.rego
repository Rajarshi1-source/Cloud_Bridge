# conftest verify -p infra/policy
package main

import rego.v1

good_tags := {"cb-cell": "cb-aws-budget", "cb-cloud": "aws", "cb-env": "budget", "managed-by": "terraform"}

plan(rc) := {"resource_changes": [rc]}

resource(actions, after) := {"address": "x.y", "change": {"actions": actions, "after": after}}

test_tagged_resource_passes if {
	count(deny) == 0 with input as plan(resource(["create"], {"tags_all": good_tags, "region": "ap-south-1"}))
}

test_gcp_labels_pass if {
	count(deny) == 0 with input as plan(resource(["create"], {"terraform_labels": good_tags, "region": "asia-south1"}))
}

test_missing_tag_is_denied if {
	some msg in deny with input as plan(resource(["create"], {"tags_all": {"cb-cell": "x"}}))
	contains(msg, "cb-cloud")
}

test_update_is_checked_too if {
	count(deny) == 1 with input as plan(resource(["update"], {"labels": {}}))
}

test_an_untaggable_resource_is_skipped if {
	count(deny) == 0 with input as plan(resource(["create"], {"role": "cb-x"}))
}

test_a_delete_is_not_this_policys_business if {
	count(deny) == 0 with input as plan(resource(["delete"], null))
}

test_another_region_is_denied if {
	some msg in deny with input as plan(resource(["create"], {"tags_all": good_tags, "region": "us-east-1"}))
	contains(msg, "us-east-1")
}

test_location_is_checked if {
	count(deny) == 1 with input as plan(resource(["create"], {"location": "europe-west1"}))
}

test_mumbai_zone_is_allowed if {
	count(deny) == 0 with input as plan(resource(["create"], {"location": "asia-south1-a"}))
}
