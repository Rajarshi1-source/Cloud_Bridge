from parity.engine import FactUnavailable


class FakeFacts:
    def __init__(self, cell: str, values: dict):
        self.cell, self.values = cell, values

    def get(self, source: str):
        if source not in self.values:
            raise FactUnavailable(f"fixture has no {source}")
        value = self.values[source]
        if value == "!unavailable":
            raise FactUnavailable("simulated read failure")
        return value
