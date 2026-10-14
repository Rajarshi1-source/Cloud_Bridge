package dev.cloudbridge.inventory;

import org.springframework.boot.autoconfigure.condition.ConditionalOnBooleanProperty;
import org.springframework.context.annotation.Configuration;
import org.springframework.resilience.annotation.EnableResilientMethods;
import org.springframework.scheduling.annotation.EnableScheduling;

/** Spring Framework 7 resilience annotations (@ConcurrencyLimit) on service methods. */
@Configuration(proxyBeanMethods = false)
@EnableResilientMethods
class InventoryConfig {

	/** Background jobs (reaper, event consumer). Tests turn them off and drive the jobs directly. */
	@Configuration(proxyBeanMethods = false)
	@ConditionalOnBooleanProperty(name = "cloudbridge.scheduling.enabled", matchIfMissing = true)
	@EnableScheduling
	static class Scheduling {

	}

}
