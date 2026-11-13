local async = require('neotest.async')
local Path = require('plenary.path')
local lib = require('neotest.lib')
local utils = require('neotest-dart.utils')
local parser = require('neotest-dart.parser')
local outline_parser = require('neotest-dart.lsp_outline_parser')

---@type neotest.Adapter
local adapter = { name = 'neotest-dart' }

adapter.root = lib.files.match_root_pattern('pubspec.yaml')

--- Command string/argv or resolver(pubspec_root) -> argv. Value is set from config.
local command = 'flutter'
local custom_test_method_names = {}
local additional_args = {}
local use_lsp = true

local outline = {}
local lsp_autocmd_registered = false
local wrapped_outline_clients = {}

local function flatten(list)
  local result = {}

  local function visit(value)
    if type(value) == 'table' then
      for _, item in ipairs(value) do
        visit(item)
      end
      return
    end

    table.insert(result, value)
  end

  visit(list)
  return result
end

local function command_argv(root)
  local resolved = command
  if type(resolved) == 'function' then
    resolved = resolved(root)
  end
  if type(resolved) == 'table' then
    return vim.deepcopy(resolved)
  end
  if resolved == 'fvm flutter' or resolved == 'fvm dart' then
    return vim.split(resolved, ' ')
  end
  return { resolved }
end

local function uses_flutter(argv)
  return vim.fn.fnamemodify(argv[#argv], ':t'):gsub('%.bat$', '') == 'flutter'
end

local function resolve_dap_command(argv, root)
  local executable = uses_flutter(argv) and 'flutter' or 'dart'
  if argv[1] == 'fvm' then
    local suffix = vim.fn.has('win32') == 1 and (executable == 'flutter' and '.bat' or '.exe') or ''
    local sdk = utils.join_path(root, '.fvm', 'flutter_sdk', 'bin', executable .. suffix)
    assert(vim.fn.executable(sdk) == 1, 'Missing project FVM executable: ' .. sdk)
    return vim.loop.fs_realpath(sdk) or sdk
  end
  assert(#argv == 1, 'DAP command must be an SDK executable or fvm dart/flutter')
  return argv[1]
end

function adapter.is_test_file(file_path)
  if not vim.endswith(file_path, '.dart') then
    return false
  end
  local elems = vim.split(file_path, Path.path.sep)
  local file_name = elems[#elems]
  local is_test = vim.endswith(file_name, 'test.dart')
  return is_test
end

--- Dart LSP has all the correct test names - they should take precedence if available
local function on_outline_changed(data)
  local new_outline = outline_parser.parse(data)
  if new_outline then
    for key, value in pairs(new_outline) do
      outline[key] = value
    end
  end
end

---@async
---@return neotest.Tree| nil
function adapter.discover_positions(path)
  local names = vim.tbl_map(function(name)
    return '"' .. name .. '"'
  end, custom_test_method_names)
  local names_string = table.concat(names, ' ')

  local query = [[
  ;; group blocks
  (expression_statement
    (identifier) @group (#eq? @group "group")
    (selector (argument_part (arguments . (argument (_) @namespace.name )))))
    @namespace.definition

  ;; tests blocks
  (expression_statement
    (identifier) @testFunc (#any-of? @testFunc "test" "testWidgets" ]] .. names_string .. [[)
    (selector (argument_part (arguments (argument (string_literal) @test.name)))))
    @test.definition
  ]]
  local tree = lib.treesitter.parse_positions(path, query, {
    require_namespaces = false,
  })
  for _, position in tree:iter() do
    if position.type == 'test' or position.type == 'namespace' then
      local outline_test_name = utils.get_test_name_from_outline(position, outline)
      if outline_test_name then
        local parts = vim.split(position.id, '::')
        -- last component is test name
        parts[#parts] = outline_test_name
        position.id = table.concat(parts, '::')
        position.name = outline_test_name
      else
        position.name = utils.remove_surrounding_quates(position.name, true)
      end
    end
  end
  return tree
end

local dap_factory = function(callback, config)
  callback(vim.deepcopy(config._neotest_dart_adapter))
end

local function get_strategy_config(strategy, position, root, argv, extra_args, results_path)
  if strategy ~= 'dap' then
    return
  end
  local dap = require('dap')
  assert(
    dap.adapters.neotest_dart == nil or dap.adapters.neotest_dart == dap_factory,
    'DAP adapter neotest_dart is already owned by another integration'
  )
  dap.adapters.neotest_dart = dap_factory
  local tool_args = vim.deepcopy(extra_args)
  if uses_flutter(argv) then
    table.insert(tool_args, '--no-pub')
  end
  -- The SDK adapter requires a source file as program, not a ?line URI.
  -- --name is a regex; anchor and escape it to avoid selecting sibling tests.
  if position.type == 'test' or position.type == 'namespace' then
    local name = utils.construct_test_name(position, outline)
    local pattern = '^' .. name:gsub('([\\.^$|?*+(){}%[%]])', '\\%1')
    pattern = pattern .. (position.type == 'test' and '$' or ' ')
    vim.list_extend(tool_args, { '--name', pattern })
  end
  table.insert(tool_args, '--file-reporter=json:' .. results_path)
  return {
    type = 'neotest_dart',
    name = 'Neotest Debugger',
    request = 'launch',
    stopOnEntry = false,
    program = position.path,
    cwd = root,
    args = {},
    toolArgs = tool_args,
    evaluateToStringInDebugViews = true,
    _neotest_dart_adapter = {
      type = 'executable',
      command = resolve_dap_command(argv, root),
      args = { uses_flutter(argv) and 'debug-adapter' or 'debug_adapter', '--test' },
      options = { initialize_timeout_sec = 30 },
    },
  }
end

---@async
---@param args neotest.RunArgs
---@return neotest.RunSpec
function adapter.build_spec(args)
  local partial_output = {}
  local results_path = async.fn.tempname()
  local tree = args.tree
  if not tree then
    return {}
  end
  local position = tree:data()
  local root = assert(adapter.root(position.path), 'No pubspec.yaml owner for ' .. position.path)
  local argv = command_argv(root)
  local target = utils.position_target(position)
  if position.type == 'dir' then
    target = position.path == root and utils.join_path(root, 'test') or position.path
  end
  local extra_args = {}
  vim.list_extend(extra_args, flatten(args.extra_args or {}))
  vim.list_extend(extra_args, flatten(additional_args))
  local command_parts = vim.deepcopy(argv)
  vim.list_extend(command_parts, { 'test', target, '--reporter', 'json' })
  if uses_flutter(argv) then
    table.insert(command_parts, '--no-pub')
  end
  vim.list_extend(command_parts, extra_args)
  local strategy_config =
    get_strategy_config(args.strategy, position, root, argv, extra_args, results_path)

  return {
    command = command_parts,
    cwd = root,
    context = {
      results_path = args.strategy == 'dap' and results_path or nil,
      file = position.path,
      root = root,
    },
    strategy = strategy_config,
    stream = function(data)
      return function()
        for _, line in ipairs(data()) do
          table.insert(partial_output, line)
        end
        return parser.parse_lines(tree, partial_output, outline, { write_output = false })
      end
    end,
  }
end

local function register_lsp_outline_handler()
  if lsp_autocmd_registered then
    return
  end

  lsp_autocmd_registered = true
  vim.api.nvim_create_autocmd('LspAttach', {
    callback = function(args)
      if not use_lsp then
        return
      end

      local client_id = args.data and args.data.client_id
      local client = client_id and vim.lsp.get_client_by_id(client_id) or nil
      if not client or client.name ~= 'dartls' or not adapter.is_test_file(args.file) then
        return
      end

      if wrapped_outline_clients[client.id] then
        return
      end

      wrapped_outline_clients[client.id] = true
      local original_outline = client.handlers['dart/textDocument/publishOutline']
      client.handlers['dart/textDocument/publishOutline'] = function(_, data)
        if original_outline then
          original_outline(_, data)
        end
        on_outline_changed(data)
      end
    end,
  })
end

---@async
---@param spec neotest.RunSpec
---@param result neotest.StrategyResult
---@param tree neotest.Tree
---@return table<string, neotest.Result>
function adapter.results(spec, result, tree)
  local report = spec.context and spec.context.results_path or result.output
  local success, data = pcall(lib.files.read, report)
  if not success or type(data) ~= 'string' then
    return parser.failed_result(
      tree,
      'Unable to read Dart test report: ' .. tostring(report),
      result.output
    )
  end
  return parser.parse_lines(tree, vim.split(data, '\n'), outline, { final = true })
end

setmetatable(adapter, {
  __call = function(_, config)
    config = config or {}
    if config.command then
      command = config.command
    end
    if config.custom_test_method_names then
      custom_test_method_names = config.custom_test_method_names
    end
    if config.additional_args then
      additional_args = config.additional_args
    end
    if config.use_lsp ~= nil then
      use_lsp = config.use_lsp
    end
    register_lsp_outline_handler()
    return adapter
  end,
})

return adapter
