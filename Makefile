JQ ?= jq
SHELL := /bin/bash

.PHONY: test
test:
	@diff -u example.json <(${JQ} -Rs -L . 'include "json5"; fromjson5' example.json5)
	@diff -u test.json <(${JQ} -Rs -L . 'include "json5"; fromjson5' test.json5)
