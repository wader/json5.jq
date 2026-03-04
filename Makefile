JQ ?= jq
SHELL := /bin/bash
CONFORMANCE_RUNNER := scripts/run_json5_conformance.py
JSON5_TESTS_DIR ?= json5-tests
TEST_FIXTURES_DIR := tests/fixtures
EXAMPLES_DIR := examples

.PHONY: test test-negative test-conformance _check-jq

_check-jq:
	@command -v "${JQ}" >/dev/null 2>&1 || (echo "JQ binary not found: ${JQ}" && exit 1)

test: _check-jq
	@diff -u ${EXAMPLES_DIR}/example.json <(${JQ} -Rs -L . 'include "json5"; fromjson5' ${EXAMPLES_DIR}/example.json5)
	@diff -u ${TEST_FIXTURES_DIR}/test.json <(${JQ} -Rs -L . 'include "json5"; fromjson5' ${TEST_FIXTURES_DIR}/test.json5)
	@test "$$(printf $$'{\xC2\xA0alpha:1,\xE2\x80\xA8beta:2,\xE2\x80\xA9gamma:3,\xEF\xBB\xBFdelta:4}\n' | ${JQ} -cRs -L . 'include "json5"; fromjson5' 2>/dev/null)" = '{"alpha":1,"beta":2,"gamma":3,"delta":4}'
	@test "$$(printf '{NaN:123,Infinity:456}\n' | ${JQ} -cRs -L . 'include "json5"; fromjson5' 2>/dev/null)" = '{"NaN":123,"Infinity":456}'
	@test "$$(printf 'NaN\n' | ${JQ} -Rs -L . 'include "json5"; fromjson5 | isnan' 2>/dev/null)" = 'true'
	@test "$$(printf 'Infinity\n' | ${JQ} -Rs -L . 'include "json5"; fromjson5 | (isinfinite and . > 0)' 2>/dev/null)" = 'true'
	@test "$$(printf '+NaN\n' | ${JQ} -Rs -L . 'include "json5"; fromjson5 | isnan' 2>/dev/null)" = 'true'
	@test "$$(printf -- '-Infinity\n' | ${JQ} -Rs -L . 'include "json5"; fromjson5 | (isinfinite and . < 0)' 2>/dev/null)" = 'true'
	@${MAKE} --no-print-directory test-negative

test-negative: _check-jq
	@! printf '010\n' | ${JQ} -Rs -L . 'include "json5"; fromjson5' >/dev/null 2>&1
	@! printf '"foo\nbar"\n' | ${JQ} -Rs -L . 'include "json5"; fromjson5' >/dev/null 2>&1
	@! printf $$'"foo\xE2\x80\xA8bar"\n' | ${JQ} -Rs -L . 'include "json5"; fromjson5' >/dev/null 2>&1
	@! printf $$'"foo\xE2\x80\xA9bar"\n' | ${JQ} -Rs -L . 'include "json5"; fromjson5' >/dev/null 2>&1
	@err="$$(printf '{foo: }\n' | ${JQ} -Rs -L . 'include "json5"; fromjson5' 2>&1 >/dev/null || true)"; \
		echo "$$err" | grep -Eq 'line [0-9]+, column [0-9]+'

test-conformance: _check-jq
	@test -f "${CONFORMANCE_RUNNER}" || (echo "Missing ${CONFORMANCE_RUNNER} script" && exit 1)
	@test -f "${JSON5_TESTS_DIR}/README.md" || (echo "Missing ${JSON5_TESTS_DIR} fixtures. Run: git submodule update --init --recursive" && exit 1)
	@JQ="${JQ}" JSON5_TESTS_DIR="${JSON5_TESTS_DIR}" python3 ${CONFORMANCE_RUNNER}
