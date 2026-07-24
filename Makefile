.PHONY: test check benchmark

test:
	NVIM_LOG_FILE=/tmp/ngit-nvim.log nvim --headless --clean -u tests/minimal_init.lua -c "lua dofile('tests/run.lua')"

check: test

benchmark:
	NVIM_LOG_FILE=/tmp/ngit-nvim.log nvim --headless --clean -u tests/minimal_init.lua -c "lua dofile('tests/benchmark.lua')"
