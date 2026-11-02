"""Plan requirements: the sum of grants never exceeds stock, and nothing is re-granted before expiry + margin.

Run offline from control-plane/allocator: python -m unittest discover -s tests
The cycle is tested through fakes; allocator.adapters (psycopg, HTTP) is exercised on the local twin.
"""
import random
import unittest
from datetime import UTC, datetime, timedelta

from allocator.core import CellView, Config, Grant, Lease, clip, committed, overrun, plan, remaining_stock
from allocator.cycle import CellUnreachable, StaleGrant, run_cycle

NOW = datetime(2026, 11, 2, 12, 0, tzinfo=UTC)
CFG = Config(lease_ttl=timedelta(minutes=15), regrant_margin=timedelta(seconds=60))
WEIGHTS = {"aws": 70, "gcp": 30}


def view(cell, sold=0, granted=0, epoch=0, expires=None, reachable=True):
    weight = WEIGHTS[cell]
    return CellView(cell, weight, reachable, Lease(sold, granted, epoch, expires))


class Plan(unittest.TestCase):
    def test_first_grants_are_floor_of_remaining_times_weight_times_09(self):
        grants = {g.cell: g for g in plan("S", 1000, [view("aws"), view("gcp")], NOW, CFG)}
        self.assertEqual(grants["aws"].remaining_qty, 630)
        self.assertEqual(grants["gcp"].remaining_qty, 270)
        self.assertEqual(grants["aws"].epoch, 1)
        self.assertEqual(grants["aws"].expires_at, NOW + timedelta(minutes=15))

    def test_sum_of_totals_never_exceeds_stock_for_any_split(self):
        for total in [0, 1, 3, 7, 10, 99, 100, 1000, 12345]:
            for w in [0, 10, 25, 50, 70, 90, 100]:
                views = [CellView("aws", w, True, Lease()), CellView("gcp", 100 - w, True, Lease())]
                grants = plan("S", total, views, NOW, CFG)
                self.assertLessEqual(sum(g.total for g in grants), total)

    def test_drained_cell_gets_nothing(self):
        views = [CellView("aws", 100, True, Lease()), CellView("gcp", 0, True, Lease())]
        grants = {g.cell: g.remaining_qty for g in plan("S", 100, views, NOW, CFG)}
        self.assertEqual(grants, {"aws": 90, "gcp": 0})

    def test_integer_arithmetic_rounds_down(self):
        grants = {g.cell: g.remaining_qty for g in plan("S", 10, [view("aws"), view("gcp")], NOW, CFG)}
        self.assertEqual(grants, {"aws": 6, "gcp": 2})

    def test_sold_units_leave_the_pool(self):
        later = NOW + timedelta(minutes=5)
        views = [view("aws", sold=100, granted=630, epoch=1, expires=later), view("gcp", granted=270, epoch=1, expires=later)]
        grants = {g.cell: g for g in plan("S", 1000, views, NOW, CFG)}
        self.assertEqual(grants["aws"].remaining_qty, 567)
        self.assertEqual(grants["aws"].total, 667)
        self.assertEqual(grants["aws"].reported_sold, 100)
        self.assertEqual(grants["aws"].epoch, 2)

    def test_shrinks_are_sent_before_growth(self):
        later = NOW + timedelta(minutes=5)
        views = [view("aws", sold=100, granted=630, epoch=1, expires=later), view("gcp", granted=270, epoch=1, expires=later)]
        order = [g.cell for g in plan("S", 1000, views, NOW, CFG)]
        self.assertEqual(order, ["gcp", "aws"])  # gcp goes 270 -> 243, aws goes 630 -> 667


class Regrant(unittest.TestCase):
    """An unreachable cell's quantity stays with it until expires_at + margin."""

    def setUp(self):
        self.expiry = NOW + timedelta(minutes=10)
        self.lost = dict(sold=100, granted=630, epoch=3, expires=self.expiry, reachable=False)

    def share(self, now):
        views = [view("aws", **self.lost), view("gcp", epoch=3)]
        return {g.cell: g for g in plan("S", 1000, views, now, CFG)}

    def test_no_regrant_before_expiry(self):
        self.assertEqual(remaining_stock(1000, [view("aws", **self.lost), view("gcp")], NOW, CFG), 370)
        self.assertEqual(self.share(NOW)["gcp"].remaining_qty, 99)  # floor(370 x 0.3 x 0.9)

    def test_no_regrant_just_before_expiry_plus_margin(self):
        at = self.expiry + timedelta(seconds=59)
        self.assertEqual(self.share(at)["gcp"].remaining_qty, 99)

    def test_regrant_exactly_at_expiry_plus_margin(self):
        at = self.expiry + timedelta(seconds=60)
        self.assertEqual(remaining_stock(1000, [view("aws", **self.lost), view("gcp")], at, CFG), 900)
        self.assertEqual(self.share(at)["gcp"].remaining_qty, 243)  # floor(900 x 0.3 x 0.9)

    def test_unreachable_cell_is_never_sent_a_grant(self):
        self.assertNotIn("aws", self.share(NOW))

    def test_unreachable_cell_with_no_record_blocks_the_sku(self):
        views = [CellView("aws", 70, False, None), view("gcp")]
        self.assertEqual(plan("S", 1000, views, NOW, CFG), [])


class Clip(unittest.TestCase):
    def grant(self, remaining, sold=0):
        return Grant("aws", "S", remaining, sold, 2, NOW)

    def test_grant_within_stock_is_untouched(self):
        self.assertEqual(clip(self.grant(600), 1000, {"aws": 0, "gcp": 400}).remaining_qty, 600)

    def test_grant_is_lowered_to_what_the_other_cell_leaves(self):
        self.assertEqual(clip(self.grant(700, sold=100), 1000, {"aws": 0, "gcp": 400}).remaining_qty, 500)

    def test_never_negative(self):
        self.assertEqual(clip(self.grant(50, sold=900), 1000, {"aws": 0, "gcp": 400}).remaining_qty, 0)


class FakeCells:
    """Cells that apply grants as inventory-service does; sales happen between report and grant if asked."""

    def __init__(self, cells, sell_during_grant=None):
        self.leases = {c: {} for c in cells}
        self.down = set()
        self.drop_grants_to = set()
        self.reject_as_stale = set()
        self.sell_during_grant = sell_during_grant
        self.sent = []

    def report(self, cell):
        if cell in self.down:
            raise CellUnreachable("down")
        return dict(self.leases[cell])

    def grant(self, grant):
        self.sent.append(grant)
        if grant.cell in self.down or grant.cell in self.drop_grants_to:
            raise CellUnreachable("no answer")
        if grant.cell in self.reject_as_stale:
            raise StaleGrant("newer epoch")
        if self.sell_during_grant:
            self.sell_during_grant(self, grant)
        lease = self.leases[grant.cell].get(grant.sku, Lease())
        total = max(lease.sold, grant.total)
        self.leases[grant.cell][grant.sku] = Lease(lease.sold, total, grant.epoch, grant.expires_at)
        return total

    def sell(self, cell, sku, qty, now):
        lease = self.leases[cell].get(sku, Lease())
        if lease.expires_at is None or now >= lease.expires_at:
            return 0
        sold = min(qty, lease.granted - lease.sold)
        self.leases[cell][sku] = Lease(lease.sold + sold, lease.granted, lease.epoch, lease.expires_at)
        return sold


class FakeStore:
    def __init__(self, stock):
        self._stock = stock
        self.rows = {}

    def stock(self):
        return self._stock

    def last_lease(self, cell, sku):
        return self.rows.get((cell, sku))

    def record(self, grant, granted_total):
        self.rows[(grant.cell, grant.sku)] = Lease(grant.reported_sold, granted_total, grant.epoch, grant.expires_at)


class Cycle(unittest.TestCase):
    def setUp(self):
        self.cells = FakeCells(WEIGHTS)
        self.store = FakeStore({"S": 1000})

    def cycle(self, now=NOW):
        return run_cycle(WEIGHTS, self.cells, self.store, now, CFG)

    def test_first_cycle_grants_both_cells_and_records_them(self):
        result = self.cycle()
        self.assertEqual({g.cell: g.total for g in result.applied}, {"aws": 630, "gcp": 270})
        self.assertEqual(self.store.last_lease("aws", "S").granted, 630)
        self.assertEqual(self.store.last_lease("aws", "S").epoch, 1)

    def test_each_cycle_uses_epoch_plus_one(self):
        self.cycle()
        self.cycle(NOW + timedelta(minutes=5))
        self.assertEqual(self.cells.leases["aws"]["S"].epoch, 2)

    def test_outage_before_any_record_grants_nothing_anywhere(self):
        self.cells.down.add("aws")
        result = self.cycle()
        self.assertEqual(result.applied, [])
        self.assertEqual(result.unreachable, ["aws"])

    def test_unreachable_cell_holds_its_lease_until_expiry_plus_margin(self):
        self.cycle()
        self.cells.down.add("aws")
        during = self.cycle(NOW + timedelta(minutes=5))
        self.assertEqual({g.cell: g.total for g in during.applied}, {"gcp": 99})  # floor(370 x .3 x .9)
        after = self.cycle(NOW + timedelta(minutes=16))
        self.assertEqual({g.cell: g.total for g in after.applied}, {"gcp": 270})

    def test_unanswered_grant_counts_as_landed_for_the_other_cell(self):
        self.cycle()
        self.cells.sell("gcp", "S", 200, NOW)
        # The POST to aws times out, so the limit for gcp must assume it landed.
        self.cells.drop_grants_to.add("aws")
        self.cycle(NOW + timedelta(minutes=5))
        self.assertEqual(self.store.last_lease("aws", "S").epoch, 1, "unconfirmed grant is not recorded")
        total = self.cells.leases["gcp"]["S"].granted
        self.assertLessEqual(total + max(g.total for g in self.cells.sent if g.cell == "aws"), 1000)

    def test_cell_that_sold_past_a_shrink_keeps_the_other_cell_within_stock(self):
        self.cycle()  # aws 630, gcp 270

        def sell_during_shrink(cells, grant):
            if grant.cell == "aws":
                cells.sell("aws", "S", 500, NOW)

        self.cells.sell_during_grant = sell_during_shrink
        # Steering moves the split: aws is asked down to 90 but sells 500 while that grant travels.
        run_cycle({"aws": 10, "gcp": 90}, self.cells, self.store, NOW + timedelta(minutes=5), CFG)
        aws, gcp = self.cells.leases["aws"]["S"], self.cells.leases["gcp"]["S"]
        self.assertEqual(aws.granted, 500, "aws keeps what it sold")
        self.assertEqual(gcp.granted, 500, "gcp would have got 810 without the answer from aws")

    def test_stale_rejection_is_not_recorded(self):
        self.cycle()
        self.cells.reject_as_stale.add("aws")
        self.cycle(NOW + timedelta(minutes=5))
        self.assertEqual(self.store.last_lease("aws", "S").epoch, 1)

    def test_database_restored_from_backup_never_reuses_an_epoch(self):
        self.cycle()
        self.cycle(NOW + timedelta(minutes=5))
        self.cells.leases["aws"]["S"] = Lease(0, 630, 1, NOW + timedelta(minutes=15))
        self.cycle(NOW + timedelta(minutes=10))
        self.assertEqual(self.cells.leases["aws"]["S"].epoch, 3)

    def test_overrun_is_reported(self):
        self.assertEqual(overrun(100, [view("aws", sold=80), view("gcp", sold=30)]), 10)
        with self.assertLogs("allocator", level="ERROR"):
            self.cells.leases["aws"]["S"] = Lease(1200, 1200, 1, NOW)
            self.cycle()


class NeverOversell(unittest.TestCase):
    """Random sales racing reports and grants, drops and fail-overs: units sold never exceed stock."""

    def simulate(self, seed):
        rng = random.Random(seed)
        stock = rng.choice([10, 37, 100, 1000])
        weights = dict(WEIGHTS)
        now = NOW

        def racing_sale(cells, grant):
            # Sales between the report and the grant, in any cell still holding a lease.
            for cell in weights:
                if rng.random() < 0.5:
                    cells.sell(cell, grant.sku, rng.randint(0, stock // 4 + 1), now)

        cells = FakeCells(weights, racing_sale)
        store = FakeStore({"S": stock})
        for _ in range(40):
            cells.drop_grants_to = {c for c in weights if rng.random() < 0.15}
            cells.reject_as_stale = {c for c in weights if rng.random() < 0.05}
            if rng.random() < 0.2:
                weights["aws"] = rng.choice([0, 10, 30, 50, 70, 90, 100])
                weights["gcp"] = 100 - weights["aws"]
            run_cycle(weights, cells, store, now, CFG)
            for cell in weights:
                cells.sell(cell, "S", rng.randint(0, stock // 3 + 1), now)
            sold = sum(cells.leases[c].get("S", Lease()).sold for c in weights)
            self.assertLessEqual(sold, stock, f"seed {seed}")
            now += timedelta(minutes=rng.choice([1, 5, 5, 5, 30]))
        return sold

    def test_many_random_histories(self):
        for seed in range(300):
            self.simulate(seed)

    def test_the_simulation_does_sell_stock(self):
        self.assertGreater(max(self.simulate(s) for s in range(10)), 0)

    def test_committed_counts_the_whole_lease_until_margin(self):
        lease = Lease(sold=5, granted=50, epoch=1, expires_at=NOW)
        self.assertEqual(committed(lease, NOW + timedelta(seconds=59), CFG), 50)
        self.assertEqual(committed(lease, NOW + timedelta(seconds=60), CFG), 5)


if __name__ == "__main__":
    unittest.main()
