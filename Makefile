.PHONY: test smoke docs diff-check format-check check benchmark

# Tests shell out to git, so they run without the developer's global and system
# config. macOS ships an Xcode gitconfig that sets init.defaultBranch=main,
# which a stock CI runner does not have; without this the suite passes locally
# and fails there.
GIT_HERMETIC = GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null

test:
	$(GIT_HERMETIC) NVIM_LOG_FILE=/tmp/ngit-nvim.log nvim --headless --clean -u tests/minimal_init.lua -c "lua local ok, err = pcall(dofile, 'tests/run.lua') if not ok then io.stderr:write(tostring(err) .. '\n') vim.cmd('cquit 1') end"

smoke:
	NVIM_LOG_FILE=/tmp/ngit-nvim.log nvim --headless --clean -u tests/minimal_init.lua -c "lua local ok, err = pcall(require, 'ngit') if not ok then io.stderr:write(tostring(err) .. '\n') vim.cmd('cquit 1') end" -c "qa!"

docs:
	NVIM_LOG_FILE=/tmp/ngit-nvim.log nvim --headless --clean -u tests/minimal_init.lua -c "try | helptags doc | silent help ngit | catch | echo v:exception | cquit 1 | endtry" -c "qa!"

diff-check:
	git diff --check

format-check:
	stylua --check lua plugin tests

check: test smoke docs diff-check

benchmark:
	NVIM_LOG_FILE=/tmp/ngit-nvim.log nvim --headless --clean -u tests/minimal_init.lua -c "lua dofile('tests/benchmark.lua')"
