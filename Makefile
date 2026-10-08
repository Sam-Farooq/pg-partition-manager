# pg-partition-manager
#
# Everything here is psql and sh. There is no build step, because the product
# is a set of SQL files that a database runs.

PSQL            ?= psql
VERSION         := $(shell cat VERSION)

# pgTAP is a dev dependency, pinned by tag and by checksum. It is fetched into
# .pgtap/ and never committed.
PGTAP_VERSION   ?= 1.3.3
PGTAP_SHA256    ?= 325ea79d0d2515bce96bce43f6823dcd3effbd6c54cb2a4d6c2384fffa3a14c7
PGTAP_DIR       ?= .pgtap
PGTAP_SQL       ?= $(PGTAP_DIR)/pgtap-$(PGTAP_VERSION).sql

# The suite builds and drops this database. It must not be a database you care
# about: run_tests.sh refuses to touch one that already exists unless
# TEST_DB_REUSE=1.
TEST_DB         ?= pg_partition_manager_test

.PHONY: help install uninstall test lint pgtap clean

help:
	@echo "make install    load sql/install.sql into the database psql would connect to"
	@echo "make uninstall  drop the ppm schema from that database"
	@echo "make test       build $(TEST_DB), run the pgTAP suite, drop it"
	@echo "make lint       convention checks over sql/, test/ and the version string"
	@echo "make pgtap      fetch pgTAP $(PGTAP_VERSION) into $(PGTAP_DIR)"
	@echo "make clean      remove $(PGTAP_DIR) and test/out"
	@echo ""
	@echo "version $(VERSION), connection comes from PGHOST/PGPORT/PGUSER/PGDATABASE"

install:
	$(PSQL) --quiet --no-psqlrc -v ON_ERROR_STOP=1 -f sql/install.sql

uninstall:
	$(PSQL) --quiet --no-psqlrc -v ON_ERROR_STOP=1 -c 'DROP SCHEMA IF EXISTS ppm CASCADE'

test: $(PGTAP_SQL)
	PGTAP_SQL=$(PGTAP_SQL) TEST_DB=$(TEST_DB) PSQL=$(PSQL) test/run_tests.sh

lint:
	test/lint.sh

pgtap: $(PGTAP_SQL)

$(PGTAP_SQL):
	test/fetch-pgtap.sh $(PGTAP_VERSION) $(PGTAP_SHA256) $(PGTAP_DIR)

clean:
	rm -rf $(PGTAP_DIR) test/out
