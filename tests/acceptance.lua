-- Run with: nvim --headless -u NONE -l tests/acceptance.lua
-- Requires Dart and installed Neotest, nio, plenary, nvim-dap and Dart parser.
local lazy = vim.env.NEOTEST_DART_LAZY or (vim.fn.stdpath('data') .. '/lazy')
vim.opt.runtimepath:append(vim.fn.getcwd())
for _, plugin in ipairs({ 'neotest', 'nvim-nio', 'plenary.nvim', 'nvim-dap', 'nvim-treesitter' }) do
  vim.opt.runtimepath:append(lazy .. '/' .. plugin)
end
local nio = require('nio')
local dap = require('dap')
local standalone = { type = 'executable', command = 'unrelated-application-sdk' }
dap.adapters.dart_test = standalone
dap.adapters.dart = standalone
local dart = vim.env.DART or vim.fn.exepath('dart')
assert(dart ~= '', 'Dart SDK is required')
local adapter = require('neotest-dart')({ command = { dart }, use_lsp = false })
local fixture = vim.fn.getcwd() .. '/tests/fixtures/dart project'
local scratch = vim.fn.tempname() .. ' switched Dart project'
local failure, completed
local function equal(actual, expected)
  assert(vim.deep_equal(actual, expected), vim.inspect({ actual = actual, expected = expected }))
end
local function process(argv, cwd, code)
  local result = vim.system(argv, { cwd = cwd, text = true }):wait(120000)
  equal(result.code, code)
  return result
end
local names = {
  'outer [x] inner passes (exact)',
  'outer [x] inner passes (exact) sibling',
  'outer [x] inner fails',
  'outer [x] inner skipped',
}
local statuses = { 'passed', 'passed', 'failed', 'skipped' }
local function executed(path)
  local seen = {}
  for _, line in ipairs(vim.fn.readfile(path)) do
    local ok, event = pcall(vim.json.decode, line)
    if ok and event.type == 'testStart' then
      for _, name in ipairs(names) do
        if event.test.name == name then
          seen[name] = event.test.id
        end
      end
    end
  end
  return seen
end
local function check_ids(path, expected)
  local seen = executed(path)
  local actual = vim.tbl_keys(seen)
  table.sort(actual)
  expected = vim.deepcopy(expected)
  table.sort(expected)
  equal(actual, expected)
  print('EXECUTED ' .. vim.json.encode(seen))
end
local function request(session, method, args)
  local future = nio.control.future()
  vim.schedule(function()
    session:request_with_timeout(method, args, 15000, function(err, body)
      future.set({ err = err, body = body })
    end)
  end)
  local response = future.wait()
  assert(not response.err, vim.inspect(response.err))
  return response.body
end
local function completed_result(handle)
  local deadline = vim.loop.hrtime() + 30e9
  while not handle.is_complete() do
    if vim.loop.hrtime() >= deadline then
      handle.stop()
      error('Dart DAP result did not finish')
    end
    nio.sleep(20)
  end
  return handle.result()
end
nio.run(function()
  process({ dart, 'pub', 'get' }, fixture, 0)
  vim.fn.mkdir(scratch .. '/test', 'p')
  for _, path in ipairs({ 'pubspec.yaml', 'test/scopes_test.dart' }) do
    vim.fn.writefile(vim.fn.readfile(fixture .. '/' .. path), scratch .. '/' .. path)
  end
  process({ dart, 'pub', 'get' }, scratch, 0)
  local file = fixture .. '/test/scopes_test.dart'
  local tree = adapter.discover_positions(file)
  assert(tree, 'Real Dart Tree-sitter discovery is required')
  local tests, group = {}, nil
  for _, node in tree:iter_nodes() do
    local value = node:data()
    if value.type == 'test' then
      tests[value.name] = node
    elseif value.type == 'namespace' and value.name == 'inner' then
      group = node
    end
  end
  equal(vim.tbl_count(tests), 4)
  local nearest = assert(tests['passes (exact)'])
  local function run(scope, expected, exit)
    local spec = adapter.build_spec({ tree = scope })
    equal(spec.cwd, fixture)
    local result = process(spec.command, spec.cwd, exit)
    local output = vim.fn.tempname()
    vim.fn.writefile(vim.split(result.stdout, '\n'), output)
    check_ids(output, expected)
    return adapter.results(spec, { output = output, code = exit }, scope)
  end
  -- Switch the editor before executing the captured spec: cwd must not leak.
  local captured = adapter.build_spec({ tree = nearest })
  vim.cmd.cd(vim.fn.fnameescape(scratch))
  local other = adapter.discover_positions(scratch .. '/test/scopes_test.dart')
  equal(adapter.build_spec({ tree = other }).cwd, scratch)
  equal(captured.cwd, fixture)
  local captured_output = process(captured.command, captured.cwd, 0)
  assert(captured_output.stdout:find(names[1], 1, true))
  local results = run(tree, names, 1)
  for index, name in ipairs({ 'passes (exact)', 'passes (exact) sibling', 'fails', 'skipped' }) do
    equal(results[tests[name]:data().id].status, statuses[index])
  end
  run(nearest, { names[1] }, 0)
  run(assert(group), names, 1)
  -- Marked tests are separate Neotest invocations; verify both concrete IDs.
  run(tests['passes (exact) sibling'], { names[2] }, 0)
  run(tests.skipped, { names[4] }, 0)
  run(tests.fails, { names[3] }, 1)

  local breakpoint_line = 8
  local buffer = vim.fn.bufadd(file)
  vim.fn.bufload(buffer)
  vim.bo[buffer].filetype = 'dart'
  require('dap.breakpoints').set({}, buffer, breakpoint_line)
  local strategy = require('neotest.client.strategies.dap')
  local function wait_idle()
    local deadline = vim.loop.hrtime() + 10e9
    while next(dap.sessions()) do
      assert(vim.loop.hrtime() < deadline, 'Previous Dart DAP session did not close')
      nio.sleep(20)
    end
    nio.scheduler()
  end
  local function debug_run(cancel)
    wait_idle()
    nio.scheduler()
    require('dap.breakpoints').clear()
    require('dap.breakpoints').set({}, buffer, breakpoint_line)
    local spec = adapter.build_spec({ tree = nearest, strategy = 'dap' })
    local stopped = nio.control.queue()
    local watchdog = vim.defer_fn(function()
      stopped.put_nowait({ error = 'Timed out waiting for Dart source stop' })
    end, 45000)
    local function wait_stop()
      local event = stopped.get()
      assert(not event.error, event.error)
      return event
    end
    dap.listeners.after.event_stopped.dart_acceptance = function(session, body)
      local args = session.config.toolArgs or {}
      if args[#args] == '--file-reporter=json:' .. spec.context.results_path then
        stopped.put_nowait({ session = session, body = body })
      end
    end
    equal(spec.strategy.program, file)
    local handle = assert(strategy(spec, { adapter = adapter.name, position = nearest:data() }))
    local stop = wait_stop()
    local entries = 0
    while stop.body.reason == 'entry' and entries < 10 do
      entries = entries + 1
      request(stop.session, 'continue', { threadId = stop.body.threadId })
      stop = wait_stop()
    end
    local frames =
      request(stop.session, 'stackTrace', { threadId = stop.body.threadId }).stackFrames
    equal(stop.body.reason, 'breakpoint')
    equal(frames[1].line, breakpoint_line)
    equal(vim.fs.normalize(frames[1].source.path), vim.fs.normalize(file))
    local scopes = request(stop.session, 'scopes', { frameId = frames[1].id }).scopes
    local variables = request(stop.session, 'variables', {
      variablesReference = scopes[1].variablesReference,
    }).variables
    local found = false
    for _, variable in ipairs(variables) do
      if variable.name == 'localValue' then
        equal(variable.value, '40')
        found = true
      end
    end
    assert(found, 'Expected real localValue in Dart stack scope')
    nio.scheduler()
    if cancel then
      handle.stop()
      assert(completed_result(handle) ~= 0, 'Cancellation must not become success')
      nio.scheduler()
      local cancelled = adapter.results(spec, { output = handle.output() }, nearest)
      equal(cancelled[nearest:data().id].status, 'failed')
      print('PASS Dart DAP cancellation at source breakpoint')
    else
      request(stop.session, 'next', { threadId = stop.body.threadId })
      local step = wait_stop()
      equal(step.body.reason, 'step')
      local stepped =
        request(step.session, 'stackTrace', { threadId = step.body.threadId }).stackFrames
      equal(stepped[1].line, breakpoint_line + 1)
      local value = request(step.session, 'evaluate', {
        expression = 'localValue',
        frameId = stepped[1].id,
        context = 'watch',
      })
      equal(value.result, '42')
      request(step.session, 'continue', { threadId = step.body.threadId })
      equal(completed_result(handle), 0)
      nio.scheduler()
      check_ids(spec.context.results_path, { names[1] })
      local debugged = adapter.results(spec, { output = handle.output() }, nearest)
      equal(debugged[nearest:data().id].status, 'passed')
      print('PASS Dart DAP breakpoint, step, variables, exact ID and authoritative report')
    end
    watchdog:stop()
    watchdog:close()
    dap.listeners.after.event_stopped.dart_acceptance = nil
    equal(dap.adapters.dart_test, standalone)
    equal(dap.adapters.dart, standalone)
  end
  debug_run(false)
  debug_run(true)
  debug_run(false)
  require('dap.breakpoints').clear()
  dap.listeners.after.event_stopped.dart_acceptance = function(session, body)
    -- Report-only runs do not request a breakpoint; resume SDK isolate entry.
    vim.schedule(function()
      session:request('continue', { threadId = body.threadId })
    end)
  end
  for index, name in ipairs({ 'fails', 'skipped' }) do
    local node = tests[name]
    wait_idle()
    local spec = adapter.build_spec({ tree = node, strategy = 'dap' })
    local handle = assert(strategy(spec, { adapter = adapter.name, position = node:data() }))
    equal(completed_result(handle), index == 1 and 1 or 0)
    nio.scheduler()
    check_ids(spec.context.results_path, { names[index == 1 and 3 or 4] })
    local reported = adapter.results(spec, { output = handle.output() }, node)
    equal(reported[node:data().id].status, index == 1 and 'failed' or 'skipped')
  end
  nio.scheduler()
  vim.fn.mkdir(scratch .. '/.fvm', 'p')
  local sdk = vim.fn.fnamemodify(vim.fn.resolve(dart), ':h:h')
  assert(vim.loop.fs_symlink(sdk, scratch .. '/.fvm/flutter_sdk'))
  adapter({ command = 'fvm dart', use_lsp = false })
  wait_idle()
  local fvm_spec = adapter.build_spec({ tree = other, strategy = 'dap' })
  equal(fvm_spec.cwd, scratch)
  equal(
    vim.loop.fs_realpath(fvm_spec.strategy._neotest_dart_adapter.command),
    vim.loop.fs_realpath(dart)
  )
  local fvm_handle = assert(strategy(fvm_spec, { adapter = adapter.name, position = other:data() }))
  equal(completed_result(fvm_handle), 1)
  nio.scheduler()
  check_ids(fvm_spec.context.results_path, names)
  local fvm_results = adapter.results(fvm_spec, { output = fvm_handle.output() }, other)
  local actual = {}
  for _, node in other:iter_nodes() do
    if node:data().type == 'test' then
      actual[node:data().name] = fvm_results[node:data().id].status
    end
  end
  equal(actual, {
    ['passes (exact)'] = 'passed',
    ['passes (exact) sibling'] = 'passed',
    fails = 'failed',
    skipped = 'skipped',
  })
  wait_idle()
  print('PASS Dart DAP project-local SDK symlink after project switch (not FVM CLI)')
  dap.listeners.after.event_stopped.dart_acceptance = nil
  print('PASS Dart DAP failing and skipped authoritative reports')
  print('PASS Dart fixture file/nearest/group/marked/project switching and DAP restart')
end, function(ok, err)
  failure = not ok and (err or 'Unknown acceptance failure') or nil
  completed = true
end)
assert(
  vim.wait(240000, function()
    return completed
  end, 20),
  'Dart acceptance timed out'
)
vim.fn.delete(scratch, 'rf')
if failure then
  dap.terminate({ all = true, hierarchy = true })
  vim.wait(5000, function()
    return next(dap.sessions()) == nil
  end, 20)
  error(failure)
end
