-- Outbox table for CDC via Debezium Outbox Event Router SMT
CREATE TABLE IF NOT EXISTS outbox (
    id             UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    aggregate_type TEXT        NOT NULL,   -- e.g. 'orders' → routes to topic outbox.events.orders
    aggregate_id   TEXT        NOT NULL,   -- business entity id used as Kafka message key
    event_type     TEXT        NOT NULL,   -- e.g. 'OrderCreated', 'OrderShipped'
    payload        JSONB       NOT NULL,
    created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_outbox_aggregate ON outbox (aggregate_type, aggregate_id);
CREATE INDEX IF NOT EXISTS idx_outbox_created_at ON outbox (created_at);

-- Publication for Debezium logical replication
-- Uses DO block to make it idempotent (safe to re-run)
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_publication WHERE pubname = 'debezium_publication'
  ) THEN
    CREATE PUBLICATION debezium_publication FOR TABLE outbox;
    RAISE NOTICE 'Created publication debezium_publication';
  ELSE
    RAISE NOTICE 'Publication debezium_publication already exists';
  END IF;
END$$;

-- Grant read access to Debezium replication user
GRANT SELECT ON outbox TO debezium;

-- Example: insert a test event (comment out in production migrations)
-- INSERT INTO outbox (aggregate_type, aggregate_id, event_type, payload)
-- VALUES (
--   'orders',
--   gen_random_uuid()::text,
--   'OrderCreated',
--   '{"customerId": "test-customer", "totalAmount": 99.99, "currency": "USD"}'::jsonb
-- );
