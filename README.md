# pg_cron_utils

A PostgreSQL extension providing utility functions to parse cron expressions
and compute their trigger times. It is useful for answering questions such as
"when is the next time this schedule fires?" or "what were the first and last
triggers within a given window?".

## Installation

Copy the extension files into your PostgreSQL installation's `share/extension`
directory, then run:

```sql
CREATE EXTENSION cron_utils;
```

## Functions

### `parse_cron(expr text) RETURNS cron_parts`

Parses a standard 5-field cron expression (`minute hour day month dow`) into a
`cron_parts` composite type. Supports wildcards (`*`), ranges (`1-5`), steps
(`*/5`, `1/5`, `1-10/2`), and lists (`1,2,3`).

### `cron_first_trigger(cron_expr text, base_time timestamptz, strict boolean DEFAULT false) RETURNS timestamptz`

Returns the first time the cron expression fires at or after `base_time`. When
`strict` is true, a match exactly equal to `base_time` is skipped.

### `cron_last_trigger(cron_expr text, base_time timestamptz, strict boolean DEFAULT true) RETURNS timestamptz`

Returns the last time the cron expression fired at or before `base_time`. When
`strict` is true (the default), a match exactly equal to `base_time` is skipped.

### `cron_first_last_triggers(cron_expr text, start_time timestamptz, end_time timestamptz) RETURNS TABLE(first timestamptz, last timestamptz)`

Returns both the first trigger at or after `start_time` and the last trigger at
or before `end_time`. Either value is `NULL` if no trigger falls within the
window.

### `cron_iterate_n(expr text, base_time timestamptz, strict boolean, direction text, max_matches integer DEFAULT 1) RETURNS SETOF timestamptz`

Returns up to `max_matches` consecutive trigger times in the given `direction`
(`'next'` or `'prev'`) starting from `base_time`.

## Examples

```sql
-- Next daily trigger at midnight
SELECT cron_first_trigger('0 0 * * *', now());

-- Last trigger before now for a weekday 9am schedule
SELECT cron_last_trigger('0 9 * * 1-5', now());

-- First and last triggers within the current month
SELECT * FROM cron_first_last_triggers(
    '0 0 * * *',
    date_trunc('month', now()),
    date_trunc('month', now()) + interval '1 month'
);

-- Next 5 hourly triggers
SELECT cron_iterate_n('0 * * * *', now(), false, 'next', 5);
```

## Notes

- Day-of-week values follow the convention `1 = Monday` ... `7 = Sunday`.
- All functions are `IMMUTABLE` and `PARALLEL SAFE`.
