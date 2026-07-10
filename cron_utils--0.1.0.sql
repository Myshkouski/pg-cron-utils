-- Drop the existing type if it exists to avoid conflicts
DROP TYPE IF EXISTS "cron_parts" CASCADE;

-- Create a composite type to store parsed parts of a cron expression
CREATE TYPE "cron_parts" AS (
    minutes INT[],  -- Array of minutes
    hours INT[],    -- Array of hours
    days INT[],     -- Array of days
    months INT[],   -- Array of months
    dow INT[]       -- Array of days of the week (1-7, where 1 = Monday)
);

-- DROP FUNCTION public.cron_first_last_triggers(text, timestamptz, timestamptz);

CREATE OR REPLACE FUNCTION public.cron_first_last_triggers(cron_expr text, start_time timestamp with time zone, end_time timestamp with time zone)
 RETURNS TABLE(first timestamp with time zone, last timestamp with time zone)
 LANGUAGE plpgsql
 IMMUTABLE PARALLEL SAFE
AS $function$
DECLARE
    first TIMESTAMPTZ;      -- Variable to store the first trigger
    last TIMESTAMPTZ;       -- Variable to store the last trigger
BEGIN
    SELECT cron_first_trigger(cron_expr, start_time, FALSE),
           cron_last_trigger(cron_expr, end_time, TRUE)
    INTO first, last;

    IF first > end_time THEN first := NULL; END IF;
    IF last < start_time THEN last := NULL; END IF;

    -- Return the first and last triggers
    RETURN QUERY SELECT first, last;
END;
$function$
;

-- DROP FUNCTION public.cron_first_trigger(text, timestamptz, bool);

CREATE OR REPLACE FUNCTION public.cron_first_trigger(cron_expr text, base_time timestamp with time zone, strict boolean DEFAULT false)
 RETURNS timestamp with time zone
 LANGUAGE plpgsql
 IMMUTABLE PARALLEL SAFE
AS $function$
BEGIN
    RETURN cron_iterate(cron_expr, base_time, strict, 'next');
END;
$function$
;

-- DROP FUNCTION public.cron_iterate(text, timestamptz, bool, text);

CREATE OR REPLACE FUNCTION public.cron_iterate(expr text, base_time timestamp with time zone, strict boolean, direction text)
 RETURNS timestamp with time zone
 LANGUAGE plpgsql
 IMMUTABLE PARALLEL SAFE
AS $function$
DECLARE
    cp cron_parts;          -- Parsed cron parts
    candidate TIMESTAMPTZ;  -- Current candidate time
    iteration INT := 0;     -- Iteration counter to prevent infinite loops
    candidate_month INT;    -- Candidate month
    candidate_day INT;      -- Candidate day
    candidate_dow INT;      -- Candidate day of the week
    candidate_hour INT;     -- Candidate hour
    candidate_minute INT;   -- Candidate minute
    time_interval INTERVAL; -- Interval to add/subtract
    min_max_func TEXT;      -- Function to use for min/max calculations
    compare_func TEXT;      -- Comparison operator for filtering
BEGIN
    -- Parse the cron expression
    cp := parse_cron(expr);
    candidate := base_time;

    -- Determine the direction of iteration
    IF direction = 'next' THEN
        time_interval := INTERVAL '1 minute';
        min_max_func := 'MIN';
        compare_func := '>=';
    ELSIF direction = 'prev' THEN
        time_interval := INTERVAL '-1 minute';
        min_max_func := 'MAX';
        compare_func := '<=';
    ELSE
        RAISE EXCEPTION 'Invalid direction: %', direction;
    END IF;

    -- Iterate to find the next/previous valid cron trigger
    WHILE TRUE LOOP
        iteration := iteration + 1;

        -- Prevent infinite loops
        IF iteration > 1 + 2 * 5 + 28 THEN
            RAISE EXCEPTION 'Infinite loop detected in cron_iterate';
        END IF;

        -- Find the next/previous valid month
        candidate_month := EXTRACT(MONTH FROM candidate)::INT;
        EXECUTE format('SELECT %s(m) FROM unnest($1) m WHERE m %s $2', min_max_func, compare_func)
        INTO candidate_month
        USING cp.months, candidate_month;
        IF (candidate_month IS NULL) THEN
            candidate := date_trunc('year', candidate) + (CASE WHEN direction = 'next' THEN INTERVAL '1 year' ELSE INTERVAL '-1 second' END);
            CONTINUE;
        END IF;

        -- Find the next/previous valid day
        candidate_day := EXTRACT(DAY FROM candidate)::INT;
        EXECUTE format('SELECT %s(m) FROM unnest($1) m WHERE m %s $2', min_max_func, compare_func)
        INTO candidate_day
        USING cp.days, candidate_day;
        IF (candidate_day IS NULL) THEN
            candidate := date_trunc('month', candidate) + (CASE WHEN direction = 'next' THEN INTERVAL '1 month' ELSE INTERVAL '-1 second' END);
            CONTINUE;
        END IF;

        -- Find the next/previous valid hour
        candidate_hour := EXTRACT(HOUR FROM candidate)::INT;
        EXECUTE format('SELECT %s(m) FROM unnest($1) m WHERE m %s $2', min_max_func, compare_func)
        INTO candidate_hour
        USING cp.hours, candidate_hour;
        IF (candidate_hour IS NULL) THEN
            candidate := date_trunc('day', candidate) + (CASE WHEN direction = 'next' THEN INTERVAL '1 day' ELSE INTERVAL '-1 second' END);
            CONTINUE;
        END IF;

        -- Find the next/previous valid minute
        candidate_minute := EXTRACT(MINUTE FROM candidate)::INT;
        EXECUTE format('SELECT %s(m) FROM unnest($1) m WHERE m %s $2', min_max_func, compare_func)
        INTO candidate_minute
        USING cp.minutes, candidate_minute;
        IF (candidate_minute IS NULL) THEN
            candidate := date_trunc('hour', candidate) + (CASE WHEN direction = 'next' THEN INTERVAL '1 hour' ELSE INTERVAL '-1 second' END);
            CONTINUE;
        END IF;

        -- Construct the candidate timestamp
        candidate := MAKE_TIMESTAMP(
            EXTRACT(YEAR FROM candidate)::INT,
            candidate_month,
            candidate_day,
            candidate_hour,
            candidate_minute,
            0
        );

        -- Validate the day of the week
        candidate_dow := EXTRACT(DOW FROM candidate)::INT;
		IF (candidate_dow = 0) THEN
            candidate_dow = 7;
        END IF;
		
        IF NOT (candidate_dow = ANY(cp.dow)) THEN
            candidate := date_trunc('day', candidate) + (CASE WHEN direction = 'next' THEN INTERVAL '1 day' ELSE INTERVAL '-1 second' END);
            CONTINUE;
        END IF;

        -- Exclude the base_time if strict mode is enabled
        IF (strict AND candidate = base_time) THEN
            candidate := candidate + time_interval;
            CONTINUE;
        END IF;

        -- Exit the loop if a valid candidate is found
        EXIT;
    END LOOP;

    -- Return the valid candidate
    RETURN candidate;
END;
$function$
;

-- DROP FUNCTION public.cron_iterate_n(text, timestamptz, bool, text, int4);

CREATE OR REPLACE FUNCTION public.cron_iterate_n(expr text, base_time timestamp with time zone, strict boolean, direction text, max_matches integer DEFAULT 1)
 RETURNS SETOF timestamp with time zone
 LANGUAGE plpgsql
 IMMUTABLE PARALLEL SAFE
AS $function$
DECLARE
    next_time TIMESTAMPTZ := base_time;
    matches_found INT := 0;
BEGIN
    -- Find up to max_matches occurrences
    WHILE matches_found < max_matches LOOP
        -- Get the next/previous occurrence using the existing function
        next_time := cron_iterate(
            base_time := next_time,
            expr := expr,
            strict := CASE WHEN matches_found = 0 THEN strict ELSE true END,
            direction := direction
        );

		-- Return the found time
        matches_found := 1 + matches_found;
        RETURN NEXT next_time;
    END LOOP;

    RETURN;
END;
$function$
;

-- DROP FUNCTION public.cron_last_trigger(text, timestamptz, bool);

CREATE OR REPLACE FUNCTION public.cron_last_trigger(cron_expr text, base_time timestamp with time zone, strict boolean DEFAULT true)
 RETURNS timestamp with time zone
 LANGUAGE plpgsql
 IMMUTABLE PARALLEL SAFE
AS $function$
BEGIN
    RETURN cron_iterate(cron_expr, base_time, strict, 'prev');
END;
$function$
;

-- DROP FUNCTION public.parse_cron(text);

CREATE OR REPLACE FUNCTION public.parse_cron(expr text)
 RETURNS cron_parts
 LANGUAGE plpgsql
 IMMUTABLE PARALLEL SAFE
AS $function$
DECLARE
    parts TEXT[];  -- Array to store the split cron expression
BEGIN
    -- Split the cron expression into parts (minutes, hours, days, months, dow)
    parts := regexp_split_to_array(expr, '\s+');
    IF array_length(parts, 1) < 5 THEN
        RAISE EXCEPTION 'Invalid cron expression: %', expr;
    END IF;

    -- Return the parsed parts as a cron_parts type
    RETURN (
        parse_cron_part(parts[1], 0, 59),   -- Parse minutes
        parse_cron_part(parts[2], 0, 23),   -- Parse hours
        parse_cron_part(parts[3], 1, 31),   -- Parse days
        parse_cron_part(parts[4], 1, 12),   -- Parse months
        parse_cron_part(parts[5], 1, 7)     -- Parse days of the week
    );
END;
$function$
;

-- DROP FUNCTION public.parse_cron_part(text, int4, int4);

CREATE OR REPLACE FUNCTION public.parse_cron_part(part text, min_val integer, max_val integer)
 RETURNS integer[]
 LANGUAGE plpgsql
 IMMUTABLE PARALLEL SAFE
AS $function$
DECLARE
    result INT[];   -- Array to store the result
    elem TEXT;      -- Temporary variable for list elements
    subparts TEXT[];-- Temporary array for subparts
    step INT;       -- Step value for ranges (e.g., "*/5" => step = 5)
    start_val INT;  -- Start value for ranges (e.g., "1-3" => start_val = 1)
BEGIN
    -- Handle step values (e.g., "*/5")
    IF part ~ '^\*/(\d+)$' THEN
        step := SUBSTRING(part FROM 3)::INT;
        RETURN ARRAY(SELECT generate_series(min_val, max_val, step));
    END IF;

    -- Handle step values with a start (e.g., "1/5")
    IF part ~ '^(\d+)/(\d+)$' THEN
        subparts := regexp_split_to_array(part, '/');
        start_val := subparts[1]::INT;
        step := subparts[2]::INT;
        RETURN ARRAY(SELECT generate_series(start_val, max_val, step));
    END IF;

    -- Handle ranges with steps (e.g., "1-10/2")
    IF part ~ '^(\d+-\d+)/(\d+)$' THEN
        subparts := regexp_split_to_array(part, '[-/]');
        RETURN ARRAY(SELECT generate_series(
            subparts[1]::INT, 
            subparts[2]::INT, 
            subparts[3]::INT
        ));
    END IF;

    -- Handle simple ranges (e.g., "1-5")
    IF part ~ '^(\d+)-(\d+)$' THEN
        subparts := regexp_split_to_array(part, '-');
        RETURN ARRAY(SELECT generate_series(
            subparts[1]::INT, 
            subparts[2]::INT
        ));
    END IF;

    -- Handle lists (e.g., "1,2,3")
    IF part LIKE '%,%' THEN
        FOR elem IN SELECT unnest(string_to_array(part, ',')) LOOP
            result := result || parse_cron_part(elem, min_val, max_val);
        END LOOP;
        RETURN result;
    END IF;

    -- Handle wildcard (*)
    IF part = '*' THEN
        RETURN ARRAY(SELECT generate_series(min_val, max_val));
    END IF;

    -- Handle single numbers (e.g., "5")
    IF part ~ '^\d+$' THEN
        RETURN ARRAY[part::INT];
    END IF;

    -- Raise an exception for invalid cron parts
    RAISE EXCEPTION 'Invalid cron part: %', part;
END;
$function$
;