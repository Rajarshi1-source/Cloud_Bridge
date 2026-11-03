-- Why a check came out unknown or excepted: without it the dashboard could only say that it did.
ALTER TABLE parity_findings ADD COLUMN note text;
