.PHONY: test smoke docs diff-check format-check check benchmark

test:
	NVIM_LOG_FILE=/tmp/ngit-nvim.log nvim --headless --clean -u tests/minimal_init.lua -c "lua dofile('tests/run.lua')"

smoke:
	NVIM_LOG_FILE=/tmp/ngit-nvim.log nvim --headless --clean -u tests/minimal_init.lua -c "lua assert(require('ngit'))" -c "qa!"

docs:
	NVIM_LOG_FILE=/tmp/ngit-nvim.log nvim --headless --clean -u tests/minimal_init.lua -c "silent help ngit" -c "qa!"

diff-check:
	git diff --check

format-check:
	stylua --check lua plugin tests

check: test smoke docs diff-check

benchmark:
	NVIM_LOG_FILE=/tmp/ngit-nvim.log nvim --headless --clean -u tests/minimal_init.lua -c "lua dofile('tests/benchmark.lua')"
