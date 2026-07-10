# PostgreSQL Makefile for the cron_utils extension (PGXS compatible)
EXTENSION = cron_utils
EXTVERSION = $(shell grep default_version $(EXTENSION).control | \
    sed -e "s/default_version[[:space:]]*=[[:space:]]*'\([^']*\)'/\1/")

DATA = $(wildcard $(EXTENSION)--*.sql)
DOCS = README.md
REGRESS = cron_utils
REGRESS_OPTS = --inputdir=$(CURDIR)/test

PG_CONFIG = pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)
