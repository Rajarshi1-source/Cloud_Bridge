package dev.cloudbridge.inventory;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;

/**
 * Releases HELD reservations whose order never committed. Confirmation arrives two ways (a direct
 * call right after the order commits, and the order.created event), so a HELD line older than
 * the hold window really is abandoned. Residual risk, documented: if BOTH paths fail for longer
 * than the window, a committed order's line is released and the cell may sell that unit again.
 */
@Component
class ReservationReaper {

	private static final Logger log = LoggerFactory.getLogger(ReservationReaper.class);

	private final ReservationService reservations;

	private final int holdMinutes;

	ReservationReaper(ReservationService reservations,
			@Value("${cloudbridge.reservations.hold-minutes:15}") int holdMinutes) {
		this.reservations = reservations;
		this.holdMinutes = holdMinutes;
	}

	@Scheduled(fixedDelayString = "${cloudbridge.reservations.reap-interval-ms:60000}")
	void reap() {
		int released = this.reservations.releaseExpired(this.holdMinutes);
		if (released > 0) {
			log.info("reaper returned stock for {} SKU(s) from abandoned reservations", released);
		}
	}

}
