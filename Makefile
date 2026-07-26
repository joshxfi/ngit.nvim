.PHONY: test smoke docs diff-check format-check check benchmark

# Tests shell out to git, so they run without the developer's global and system
# config. macOS ships an Xcode gitconfig that sets init.defaultBranch=main,
# which a stock CI runner does not have; without this the suite passes locally
# and fails there.
GIT_HERMETIC = GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null

test:
	$(GIT_HERMETIC) NVIM_LOG_FILE=/tmp/ngit-nvim.log nvim --headless --clean -u tests/minimal_init.lua -c "lua dofile('tests/run.lua')"

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
