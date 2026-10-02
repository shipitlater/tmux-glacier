SHELL := /bin/bash
.PHONY: test

test:
	$(SHELL) tests/run_tests.sh
