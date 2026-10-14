-- LOCAL PROFILE ONLY (spring.flyway.locations in application-local.yaml). Never on a real cell:
-- real leases come from the control-plane allocator with a 15-minute expiry (Week 4).
-- Repeatable migration, so it never bumps the versioned schema level the parity check compares.
INSERT INTO inventory.products (sku, name, price_paise) VALUES
    ('SKU-1', 'Demo widget', 49900),
    ('SKU-2', 'Demo gadget', 129900)
ON CONFLICT (sku) DO NOTHING;

INSERT INTO inventory.inventory_lease (sku, granted_qty, sold_qty, lease_epoch, expires_at) VALUES
    ('SKU-1', 100, 0, 1, now() + interval '30 days'),
    ('SKU-2', 20, 0, 1, now() + interval '30 days')
ON CONFLICT (sku) DO NOTHING;
