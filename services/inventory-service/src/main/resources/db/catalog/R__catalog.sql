-- The demo catalog, on every cell, so the allocator's grants name SKUs the cell knows.
-- Stock is not here: a cell sells a product only once the allocator has granted it a lease.
-- Repeatable migration, so it never bumps the versioned schema level the parity check compares.
INSERT INTO inventory.products (sku, name, price_paise) VALUES
    ('SKU-1', 'Demo widget', 49900),
    ('SKU-2', 'Demo gadget', 129900)
ON CONFLICT (sku) DO NOTHING;
