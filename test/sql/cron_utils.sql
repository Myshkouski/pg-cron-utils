-- Basic trigger-time tests for cron_utils
CREATE EXTENSION cron_utils;
SET timezone = 'UTC';

-- next daily midnight trigger on/after 2024-01-01 12:00
SELECT cron_first_trigger('0 0 * * *', '2024-01-01 12:00+00');
SELECT cron_first_trigger('0 0 * * *', '2024-01-01 00:00+00', strict => true);

-- last weekday 9am trigger on/before 2024-01-08 00:00 (Sunday -> Friday)
SELECT cron_last_trigger('0 9 * * 1-5', '2024-01-08 00:00+00', strict => true);

-- first/last triggers within a window
SELECT * FROM cron_first_last_triggers(
    '0 0 * * *',
    '2024-01-01 00:00+00',
    '2024-01-31 23:59+00'
);

-- step expression: every 15 minutes
SELECT cron_first_trigger('*/15 * * * *', '2024-01-01 00:07+00', strict => true);

-- multiple triggers
SELECT cron_iterate_n('0 * * * *', '2024-01-01 00:00+00', false, 'next', 3);
