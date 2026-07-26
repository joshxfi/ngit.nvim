local diff_parser = require("ngit.git.diff")
local records = require("ngit.git.records")
local runner = require("ngit.git.runner")

local M = {}

---@class NgitRangeFile
---@field path string
---@field old_path? string
---@field kind "modified"|"added"|"deleted"|"renamed"|"copied"|"typechange"
---@field status string Raw status letter git reported.

local kinds = {
  A = "added",
  C = "copied",
  D = "deleted",
  M = "modified",
  R = "renamed",
  T = "typechange",
}

--- Parses `--name-status -z` output. A rename or copy spends three fields on one
--- entry - the score, then both paths - so the walk cannot assume a fixed stride.
---@param output string
---@return NgitRangeFile[]
function M.parse(output)
  local fields = records.split(output, "\0")
  local files = {}
  local index = 1
  while index <= #fields do
    local status = fields[index]
    if status == nil or status == "" then
      index = index + 1
    else
      local letter = status:sub(1, 1)
      if letter == "R" or letter == "C" then
        local old_path, path = fields[index + 1], fields[index + 2]
        if path and path ~= "" then
          files[#files + 1] = {
            path = path,
            old_path = old_path,
            kind = kinds[letter],
            status = status,
          }
        end
        index = index + 3
      else
        local path = fields[index + 1]
        if path and path ~= "" then
          files[#files + 1] = {
            path = path,
            kind = kinds[letter] or "modified",
            status = status,
          }
        end
        index = index + 2
      end
    end
  end
  return files
end

---@param root string
---@param spec string
---@param callback fun(files: NgitRangeFile[]?, err: string?)
function M.files(root, spec, callback)
  return runner.run({
    "diff",
    "--name-status",
    "-z",
    "--find-renames",
    "--no-color",
    "--no-ext-diff",
    spec,
  }, { cwd = root }, function(result)
    if not runner.ok(result) then
      callback(nil, runner.error_message(result))
      return
    end
    callback(M.parse(result.stdout), nil)
  end)
end

---@param root string
---@param spec string
---@param path string
---@param context integer
---@param max_bytes integer
---@param callback fun(diff: NgitDiff?, err: string?)
function M.diff(root, spec, path, context, max_bytes, callback)
  return runner.run({
    "diff",
    "--no-color",
    "--no-ext-diff",
    "--binary",
    "--find-renames",
    "--src-prefix=a/",
    "--dst-prefix=b/",
    ("--unified=%d"):format(context),
    spec,
    "--",
    path,
  }, { cwd = root, max_stdout_bytes = max_bytes }, function(result)
    if not result.truncated and not runner.ok(result) then
      callback(nil, runner.error_message(result))
      return
    end
    callback(diff_parser.parse(result.stdout, max_bytes, result.truncated), nil)
  end)
end

--- Whole-range summary, used as the preview when no single file is selected.
---@param root string
---@param spec string
---@param max_bytes integer
---@param callback fun(diff: NgitDiff?, err: string?)
function M.summary(root, spec, max_bytes, callback)
  return runner.run({
    "diff",
    "--no-color",
    "--no-ext-diff",
    "--stat",
    "--find-renames",
    spec,
  }, { cwd = root, max_stdout_bytes = max_bytes }, function(result)
    if not result.truncated and not runner.ok(result) then
      callback(nil, runner.error_message(result))
      return
    end
    callback(diff_parser.parse(result.stdout, max_bytes, result.truncated), nil)
  end)
end

---@param root string
---@param spec string
---@param callback fun(ok: boolean, err: string?)
function M.validate(root, spec, callback)
  return runner.run({ "rev-parse", "--verify", "--quiet", spec }, { cwd = root }, function(result)
    if runner.ok(result) then
      callback(true, nil)
      return
    end
    -- `A...B` and `A..B` are not object names, so rev-parse cannot verify them.
    -- Asking diff to resolve the same expression with no output is the check that
    -- covers every form ngit accepts.
    runner.run({ "diff", "--quiet", "--exit-code", "--name-only", spec }, {
      cwd = root,
    }, function(second)
      if runner.ok(second, { [1] = true }) then
        callback(true, nil)
      else
        callback(false, runner.error_message(second))
      end
    end)
  end)
end

--- The range that answers "what have I changed on this branch".
---
--- The upstream is preferred because it is what the branch will be compared
--- against when it is pushed. Without one, the repository's default branch is the
--- next best base, and the three-dot form is used throughout so the answer is the
--- work on this branch rather than everything that landed on the base meanwhile.
---@param root string
---@param callback fun(spec: string?, err: string?)
function M.review_spec(root, callback)
  return runner.run(
    { "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}" },
    { cwd = root },
    function(result)
      if runner.ok(result) then
        local upstream = vim.trim(result.stdout)
        if upstream ~= "" then
          callback(upstream .. "...HEAD", nil)
          return
        end
      end
      runner.run({ "symbolic-ref", "--short", "refs/remotes/origin/HEAD" }, {
        cwd = root,
      }, function(head)
        if runner.ok(head) and vim.trim(head.stdout) ~= "" then
          callback(vim.trim(head.stdout) .. "...HEAD", nil)
          return
        end
        runner.run({ "for-each-ref", "--format=%(refname:short)", "refs/heads" }, {
          cwd = root,
        }, function(refs)
          if not runner.ok(refs) then
            callback(nil, runner.error_message(refs))
            return
          end
          local names = {}
          for _, name in ipairs(vim.split(refs.stdout, "\n", { plain = true, trimempty = true })) do
            names[name] = true
          end
          for _, candidate in ipairs({ "main", "master", "develop", "trunk" }) do
            if names[candidate] then
              callback(candidate .. "...HEAD", nil)
              return
            end
          end
          callback(nil, "No upstream or default branch to review against")
        end)
      end)
    end
  )
end

return M
