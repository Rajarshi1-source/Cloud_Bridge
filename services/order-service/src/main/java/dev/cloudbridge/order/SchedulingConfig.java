package dev.cloudbridge.order;

import org.springframework.boot.autoconfigure.condition.ConditionalOnBooleanProperty;
import org.springframework.context.annotation.Configuration;
import org.springframework.scheduling.annotation.EnableScheduling;

/** Background jobs (outbox relay, sweeps). Tests turn them off and drive the jobs directly. */
@Configuration(proxyBeanMethods = false)
@ConditionalOnBooleanProperty(name = "cloudbridge.scheduling.enabled", matchIfMissing = true)
@EnableScheduling
class SchedulingConfig {

}
