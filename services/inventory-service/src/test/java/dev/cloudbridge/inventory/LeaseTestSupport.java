package dev.cloudbridge.inventory;

import org.springframework.boot.test.context.TestConfiguration;
import org.springframework.context.annotation.Import;

/** The package-private container configuration, for tests in sub-packages. */
@TestConfiguration(proxyBeanMethods = false)
@Import(TestcontainersConfiguration.class)
public class LeaseTestSupport {

}
