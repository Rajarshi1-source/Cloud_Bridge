package dev.cloudbridge.inventory.lease;

import dev.cloudbridge.inventory.LeaseTestSupport;
import dev.cloudbridge.inventory.lease.LeaseGrantService.Grant;
import dev.cloudbridge.inventory.lease.LeaseGrantService.Outcome;
import dev.cloudbridge.inventory.lease.LeaseGrantService.Result;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.context.annotation.Import;
import org.springframework.jdbc.core.simple.JdbcClient;

import java.time.OffsetDateTime;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;

/** Every bound holds even for an authenticated caller, and every attempt leaves exactly one audit row. */
@Import(LeaseTestSupport.class)
@SpringBootTest
class LeaseGrantServiceIT {

	@Autowired
	LeaseGrantService grants;

	@Autowired
	JdbcClient jdbc;

	String sku;

	OffsetDateTime expiry;

	@BeforeEach
	void product() {
		this.sku = "SKU-" + UUID.randomUUID();
		this.expiry = OffsetDateTime.now().plusMinutes(15).withNano(0);
		this.jdbc.sql("INSERT INTO inventory.products (sku, name, price_paise, max_cell_grant) VALUES (:s, 'W', 1, 500)")
			.param("s", this.sku)
			.update();
	}

	private Result grant(int qty, int reportedSold, long epoch, OffsetDateTime expires) {
		return this.grants.apply(new Grant(this.sku, qty, reportedSold, epoch, expires), "allocator", "jti");
	}

	private long epoch() {
		return this.jdbc.sql("SELECT lease_epoch FROM inventory.inventory_lease WHERE sku = :s")
			.param("s", this.sku)
			.query(Long.class)
			.single();
	}

	private int granted() {
		return this.jdbc.sql("SELECT granted_qty FROM inventory.inventory_lease WHERE sku = :s")
			.param("s", this.sku)
			.query(Integer.class)
			.single();
	}

	private void sold(int qty) {
		this.jdbc.sql("UPDATE inventory.inventory_lease SET sold_qty = :q WHERE sku = :s")
			.param("q", qty)
			.param("s", this.sku)
			.update();
	}

	private long logRows() {
		return this.jdbc.sql("SELECT count(*) FROM inventory.lease_grant_log WHERE sku = :s")
			.param("s", this.sku)
			.query(Long.class)
			.single();
	}

	@Test
	void olderEpochIsFencedOff() {
		assertThat(grant(10, 0, 5, this.expiry).outcome()).isEqualTo(Outcome.APPLIED);
		assertThat(grant(99, 0, 4, this.expiry).outcome()).isEqualTo(Outcome.STALE);
		assertThat(epoch()).isEqualTo(5);
		assertThat(granted()).isEqualTo(10);
		assertThat(logRows()).isEqualTo(2);
	}

	@Test
	void hugeEpochCannotBurnTheEpochSpace() {
		Result r = grant(10, 0, 1_000_001, this.expiry);
		assertThat(r.outcome()).isEqualTo(Outcome.OUT_OF_BOUNDS);
		assertThat(r.rule()).isEqualTo("epoch-jump");
	}

	@Test
	void leaseLongerThanTheTtlCapIsRejected() {
		Result r = grant(10, 0, 1, OffsetDateTime.now().plusHours(2));
		assertThat(r.outcome()).isEqualTo(Outcome.OUT_OF_BOUNDS);
		assertThat(r.rule()).isEqualTo("ttl");
		assertThat(grant(10, 0, 1, OffsetDateTime.now().minusMinutes(1)).rule()).isEqualTo("ttl");
	}

	@Test
	void quantityAboveThePerProductCapIsRejected() {
		Result r = grant(501, 0, 1, this.expiry);
		assertThat(r.outcome()).isEqualTo(Outcome.OUT_OF_BOUNDS);
		assertThat(r.rule()).isEqualTo("quantity");
		assertThat(logRows()).isEqualTo(1);
	}

	@Test
	void reportedSoldBeyondWhatWasEverGrantedIsRejected() {
		Result r = grant(10, 1000, 1, this.expiry);
		assertThat(r.outcome()).isEqualTo(Outcome.OUT_OF_BOUNDS);
		assertThat(r.rule()).isEqualTo("reported-sold");
	}

	@Test
	void sameGrantTwiceIsAReplayAndChangesNothing() {
		assertThat(grant(10, 0, 1, this.expiry).outcome()).isEqualTo(Outcome.APPLIED);
		assertThat(grant(10, 0, 1, this.expiry).outcome()).isEqualTo(Outcome.REPLAYED);
		assertThat(granted()).isEqualTo(10);
		assertThat(logRows()).isEqualTo(2);
	}

	@Test
	void sameEpochWithDifferentContentIsRejected() {
		grant(10, 0, 1, this.expiry);
		assertThat(grant(11, 0, 1, this.expiry).outcome()).isEqualTo(Outcome.EPOCH_REUSED);
		assertThat(granted()).isEqualTo(10);
	}

	@Test
	void unknownSkuIsRejectedAndStillAudited() {
		String unknown = "NO-SUCH-" + this.sku;
		Result r = this.grants.apply(new Grant(unknown, 1, 0, 1, this.expiry), "allocator", null);
		assertThat(r.outcome()).isEqualTo(Outcome.UNKNOWN_SKU);
		assertThat(this.jdbc.sql("SELECT count(*) FROM inventory.lease_grant_log WHERE sku = :s AND outcome = 'UNKNOWN_SKU'")
			.param("s", unknown)
			.query(Long.class)
			.single()).isEqualTo(1);
	}

	@Test
	void salesAfterTheReportComeOutOfTheNewGrant() {
		grant(10, 0, 1, this.expiry);
		sold(4); // the allocator's report saw 2 sold; two more sold before the grant arrived
		assertThat(grant(5, 2, 2, this.expiry).outcome()).isEqualTo(Outcome.APPLIED);
		assertThat(granted()).as("reported sold + remaining, not current sold + remaining").isEqualTo(7);
	}

	@Test
	void shrinkingBelowWhatIsAlreadySoldStopsSalesWithoutBreakingTheCheck() {
		grant(10, 0, 1, this.expiry);
		sold(9);
		Result r = grant(1, 2, 2, this.expiry);
		assertThat(r.outcome()).isEqualTo(Outcome.APPLIED);
		assertThat(r.grantedQty()).as("the caller learns the cell holds more than it asked for").isEqualTo(9);
		assertThat(granted()).isEqualTo(9);
	}

}
