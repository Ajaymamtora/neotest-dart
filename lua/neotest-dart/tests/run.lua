package.path = table.concat({
  vim.loop.cwd() .. '/lua/?.lua',
  vim.loop.cwd() .. '/lua/?/init.lua',
  package.path,
}, ';')

local failures = {}

local function reset_modules(names)
  for _, name in ipairs(names) do
    package.loaded[name] = nil
    package.preload[name] = nil
  end
end

local function assert_eq(actual, expected)
  assert(
    vim.deep_equal(actual, expected),
    string.format('Expected %s, got %s', vim.inspect(expected), vim.inspect(actual))
  )
end

local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then
    print('PASS ' .. name)
    return
  end

  table.insert(failures, name .. '\n' .. err)
  print('FAIL ' .. name)
end

test('outline parser extracts widget names', function()
  reset_modules({ 'neotest-dart.lsp_outline_parser' })
  local parser = require('neotest-dart.lsp_outline_parser')
  local data = {
    outline = {
      children = {
        {
          children = {
            {
              children = {
                {
                  codeRange = {
                    ['end'] = { character = 6, line = 6 },
                    start = { character = 4, line = 4 },
                  },
                  element = {
                    kind = 'UNIT_TEST_TEST',
                    name = 'testWidgets("a \' \' b")',
                  },
                },
              },
            },
          },
        },
      },
    },
    uri = 'file:///tmp/project/test/foo_test.dart',
  }

  local output = parser.parse(data)
  assert_eq(output['/tmp/project/test/foo_test.dart::4_4_6_7'], "a ' ' b")
end)

test('parser handles generic dart test filenames in diagnostics', function()
  reset_modules({ 'neotest.async', 'neotest-dart.utils', 'neotest-dart.parser' })
  package.preload['neotest.async'] = function()
    return {
      fn = {
        tempname = function()
          return '/tmp/neotest-dart-output'
        end,
      },
    }
  end

  local parser = require('neotest-dart.parser')
  local tree = {
    iter_nodes = function()
      local yielded = false
      local node = {
        data = function()
          return {
            type = 'test',
            id = '/tmp/project/test/foo_test.dart::"group"::"works"',
            path = '/tmp/project/test/foo_test.dart',
            range = { 4, 4, 6, 7 },
          }
        end,
      }

      return function()
        if yielded then
          return nil
        end
        yielded = true
        return 1, node
      end
    end,
  }

  local lines = {
    vim.json.encode({ test = { id = 1, name = 'group works' } }),
    vim.json.encode({
      testID = 1,
      result = 'failure',
      message = 'Expected true but was false in foo_test.dart line 12',
      time = 42,
    }),
  }

  local results = parser.parse_lines(tree, lines, {}, { write_output = false })
  local result = results['/tmp/project/test/foo_test.dart::"group"::"works"']
  assert_eq(result.status, 'failed')
  assert_eq(result.errors[1].line, 11)
  assert(result.output:match('Elapsed: 0%.042s%.'), 'Expected elapsed time in in-memory output')
end)

test('parser matches runtime tests by location instead of name', function()
  reset_modules({ 'neotest.async', 'neotest-dart.utils', 'neotest-dart.parser' })
  package.preload['neotest.async'] = function()
    return {
      fn = {
        tempname = function()
          return '/tmp/neotest-dart-output'
        end,
      },
    }
  end

  local parser = require('neotest-dart.parser')
  local tree = {
    iter_nodes = function()
      local yielded = false
      local node = {
        data = function()
          return {
            type = 'test',
            id = '/tmp/project/test/foo_test.dart::"works"',
            name = 'works',
            path = '/tmp/project/test/foo_test.dart',
            range = { 4, 2, 6, 7 },
          }
        end,
      }

      return function()
        if yielded then
          return nil
        end
        yielded = true
        return 1, node
      end
    end,
  }

  local lines = {
    vim.json.encode({
      type = 'testStart',
      test = {
        id = 1,
        name = 'generated runtime name',
        url = 'file:///tmp/project/test/foo_test.dart',
        line = 5,
        column = 3,
      },
    }),
    vim.json.encode({
      type = 'testDone',
      testID = 1,
      result = 'success',
      hidden = false,
      skipped = false,
      time = 42,
    }),
  }

  local results = parser.parse_lines(tree, lines, {}, { write_output = false })
  local result = results['/tmp/project/test/foo_test.dart::"works"']
  assert(result, 'Expected runtime test to be matched by location')
  assert_eq(result.status, 'passed')
end)

test('parser aggregates multiple runtime tests from same source location', function()
  reset_modules({ 'neotest.async', 'neotest-dart.utils', 'neotest-dart.parser' })
  package.preload['neotest.async'] = function()
    return {
      fn = {
        tempname = function()
          return '/tmp/neotest-dart-output'
        end,
      },
    }
  end

  local parser = require('neotest-dart.parser')
  local tree = {
    iter_nodes = function()
      local yielded = false
      local node = {
        data = function()
          return {
            type = 'test',
            id = '/tmp/project/test/foo_test.dart::"loop"',
            name = 'loop',
            path = '/tmp/project/test/foo_test.dart',
            range = { 9, 4, 12, 6 },
          }
        end,
      }

      return function()
        if yielded then
          return nil
        end
        yielded = true
        return 1, node
      end
    end,
  }

  local lines = {
    vim.json.encode({
      type = 'testStart',
      test = {
        id = 1,
        name = 'case 1',
        root_url = 'file:///tmp/project/test/foo_test.dart',
        root_line = 10,
        root_column = 5,
        url = 'file:///tmp/project/test/helpers.dart',
        line = 30,
        column = 2,
      },
    }),
    vim.json.encode({
      type = 'testDone',
      testID = 1,
      result = 'success',
      hidden = false,
      skipped = false,
      time = 11,
    }),
    vim.json.encode({
      type = 'testStart',
      test = {
        id = 2,
        name = 'case 2',
        url = 'file:///tmp/project/test/foo_test.dart',
        line = 10,
        column = 5,
      },
    }),
    vim.json.encode({
      type = 'error',
      testID = 2,
      error = "'file:///tmp/project/test/foo_test.dart': Expected true but was false",
      stackTrace = 'foo_test.dart line 14',
      isFailure = true,
    }),
    vim.json.encode({
      type = 'testDone',
      testID = 2,
      result = 'failure',
      hidden = false,
      skipped = false,
      time = 17,
    }),
  }

  local results = parser.parse_lines(tree, lines, {}, { write_output = false })
  local result = results['/tmp/project/test/foo_test.dart::"loop"']
  assert(result, 'Expected loop-generated tests to be aggregated')
  assert_eq(result.status, 'failed')
  assert(result.output:match('Expected true but was false'), 'Expected combined failure output')
  assert_eq(result.errors[1].line, 13)
end)

test('adapter respects use_lsp and avoids duplicate wrapping', function()
  reset_modules({
    'neotest.async',
    'plenary.path',
    'neotest.lib',
    'neotest-dart.utils',
    'neotest-dart.parser',
    'neotest-dart.lsp_outline_parser',
    'neotest-dart',
  })

  local autocmd_callback
  local autocmd_count = 0
  local parser_opts
  local outline_parse_calls = 0
  local client = {
    id = 7,
    name = 'dartls',
    handlers = {},
  }
  local original_handler_calls = 0
  local original_handler = function()
    original_handler_calls = original_handler_calls + 1
  end
  client.handlers['dart/textDocument/publishOutline'] = original_handler

  package.preload['neotest.async'] = function()
    return {
      fn = {
        tempname = function()
          return '/tmp/neotest-dart-results'
        end,
      },
    }
  end
  package.preload['plenary.path'] = function()
    return { path = { sep = '/' } }
  end
  package.preload['neotest.lib'] = function()
    return {
      files = {
        match_root_pattern = function()
          return function()
            return '/tmp/project'
          end
        end,
        read = function()
          return ''
        end,
      },
      treesitter = {
        parse_positions = function()
          return {
            iter = function()
              return function()
                return nil
              end
            end,
          }
        end,
      },
    }
  end
  package.preload['neotest-dart.utils'] = function()
    return {
      get_test_name_from_outline = function()
        return nil
      end,
      remove_surrounding_quates = function(name)
        return name
      end,
      construct_test_name = function()
        return 'works'
      end,
      position_target = function(position)
        return string.format('%s?line=%s', position.path, position.range[1] + 1)
      end,
      join_path = function(...)
        return table.concat({ ... }, '/')
      end,
    }
  end
  package.preload['neotest-dart.parser'] = function()
    return {
      parse_lines = function(_, _, _, opts)
        parser_opts = opts
        return {}
      end,
    }
  end
  package.preload['neotest-dart.lsp_outline_parser'] = function()
    return {
      parse = function()
        outline_parse_calls = outline_parse_calls + 1
        return {}
      end,
    }
  end

  local original_create_autocmd = vim.api.nvim_create_autocmd
  local original_get_client = vim.lsp.get_client_by_id
  vim.api.nvim_create_autocmd = function(_, opts)
    autocmd_count = autocmd_count + 1
    autocmd_callback = opts.callback
  end
  vim.lsp.get_client_by_id = function(id)
    if id == client.id then
      return client
    end
  end

  local ok, err = pcall(function()
    local adapter = require('neotest-dart')
    adapter({ use_lsp = false })
    assert_eq(autocmd_count, 1)

    autocmd_callback({ file = '/tmp/project/test/foo_test.dart', data = { client_id = client.id } })
    assert_eq(client.handlers['dart/textDocument/publishOutline'], original_handler)

    adapter({ use_lsp = true })
    assert_eq(autocmd_count, 1)

    autocmd_callback({ file = '/tmp/project/test/foo_test.dart', data = { client_id = client.id } })
    local wrapped_handler = client.handlers['dart/textDocument/publishOutline']
    assert(
      wrapped_handler ~= original_handler,
      'Expected outline handler to be wrapped once when enabled'
    )

    autocmd_callback({ file = '/tmp/project/test/foo_test.dart', data = { client_id = client.id } })
    assert_eq(client.handlers['dart/textDocument/publishOutline'], wrapped_handler)

    wrapped_handler(
      nil,
      { outline = { children = {} }, uri = 'file:///tmp/project/test/foo_test.dart' }
    )
    assert_eq(original_handler_calls, 1)
    assert_eq(outline_parse_calls, 1)

    local spec = adapter.build_spec({
      tree = {
        data = function()
          return {
            type = 'test',
            id = '/tmp/project/test/foo_test.dart::"works"',
            path = '/tmp/project/test/foo_test.dart',
            range = { 1, 0, 1, 4 },
          }
        end,
      },
    })
    local stream = spec.stream(function()
      return { vim.json.encode({ event = 'testStart' }) }
    end)
    stream()
    assert_eq(parser_opts.write_output, false)
  end)

  vim.api.nvim_create_autocmd = original_create_autocmd
  vim.lsp.get_client_by_id = original_get_client
  if not ok then
    error(err)
  end
end)

local function load_adapter(config)
  reset_modules({
    'neotest.async',
    'plenary.path',
    'neotest.lib',
    'neotest-dart.utils',
    'neotest-dart.parser',
    'neotest-dart.lsp_outline_parser',
    'neotest-dart',
    'dap',
  })
  package.preload['neotest.async'] = function()
    return { fn = { tempname = vim.fn.tempname } }
  end
  package.preload['plenary.path'] = function()
    return { path = { sep = '/' } }
  end
  package.preload['neotest.lib'] = function()
    return {
      files = {
        match_root_pattern = function()
          return function(path)
            return path:match('^(.-)/test/') or path
          end
        end,
        read = function(path)
          return table.concat(vim.fn.readfile(path), '\n')
        end,
      },
    }
  end
  local standalone = { type = 'executable', command = 'application-sdk' }
  local dap = { adapters = { dart_test = standalone, dart = standalone } }
  package.preload['dap'] = function()
    return dap
  end
  local adapter = require('neotest-dart')(config or { command = 'dart', use_lsp = false })
  return adapter, dap, standalone
end

local function scope(kind, path, name)
  local position = {
    type = kind,
    path = path or '/tmp/project with spaces/test/foo_test.dart',
    range = { 4, 2, 6, 7 },
  }
  position.id = position.path .. (name and ('::"outer [x]"::"' .. name .. '"') or '')
  local tree = {}
  function tree:data()
    return position
  end
  function tree:iter_nodes()
    local yielded = false
    return function()
      if not yielded then
        yielded = true
        return 1, tree
      end
    end
  end
  return tree
end

test('argv is immutable and captures owner independently of editor cwd', function()
  local configured = { '--define', 'message=spaces; $(touch nope)' }
  local extra = { '--name', 'literal "quoted" name' }
  local config_command = { '/tmp/sdk with spaces/dart' }
  local adapter = load_adapter({
    command = config_command,
    additional_args = configured,
    use_lsp = false,
  })
  local tree = scope('test', nil, 'works')
  local first = adapter.build_spec({ tree = tree, extra_args = extra })
  local second = adapter.build_spec({ tree = tree, extra_args = extra })
  assert_eq(first.command, {
    config_command[1],
    'test',
    tree:data().path .. '?line=5',
    '--reporter',
    'json',
    '--name',
    'literal "quoted" name',
    '--define',
    'message=spaces; $(touch nope)',
  })
  assert_eq(first.command, second.command)
  assert_eq(first.cwd, '/tmp/project with spaces')
  assert_eq(extra, { '--name', 'literal "quoted" name' })
  assert_eq(configured, { '--define', 'message=spaces; $(touch nope)' })
  first.command[1] = 'mutated'
  assert_eq(config_command, { '/tmp/sdk with spaces/dart' })
  assert_eq(adapter.build_spec({ tree = tree, extra_args = '--verbose' }).command[6], '--verbose')
end)

test('DAP owns only a private factory with immutable per-project SDK and file program', function()
  local adapter, dap, standalone = load_adapter()
  local first = adapter.build_spec({ tree = scope('test', nil, 'works (exact)'), strategy = 'dap' })
  local factory = dap.adapters.neotest_dart
  adapter({ command = '/other sdk/dart', use_lsp = false })
  local second = adapter.build_spec({
    tree = scope('test', '/tmp/other project/test/foo_test.dart', 'works (exact)'),
    strategy = 'dap',
  })
  local resolved
  factory(function(value)
    resolved = value
  end, first.strategy)
  assert_eq(resolved.command, 'dart')
  assert_eq(resolved.args, { 'debug_adapter', '--test' })
  assert_eq(second.strategy._neotest_dart_adapter.command, '/other sdk/dart')
  assert_eq(second.cwd, '/tmp/other project')
  assert_eq(dap.adapters.dart_test, standalone)
  assert_eq(dap.adapters.dart, standalone)
  assert_eq(dap.adapters.neotest_dart, factory)
  assert_eq(first.strategy.program, '/tmp/project with spaces/test/foo_test.dart')
  assert_eq(first.strategy.toolArgs[2], '^outer \\[x\\] works \\(exact\\)$')
  assert(first.strategy.toolArgs[3]:match('^%-%-file%-reporter=json:'))
  dap.adapters.neotest_dart = standalone
  assert(not pcall(adapter.build_spec, { tree = scope('file'), strategy = 'dap' }))
  assert_eq(dap.adapters.neotest_dart, standalone)
end)

test(
  'FVM resolves from each project and refuses a missing SDK rather than global fallback',
  function()
    local root = vim.fn.tempname() .. ' fvm project'
    local bin = root .. '/.fvm/flutter_sdk/bin'
    vim.fn.mkdir(bin, 'p')
    local executable = bin .. '/dart'
    vim.fn.writefile({ '#!/bin/sh', 'exit 0' }, executable)
    vim.fn.setfperm(executable, 'rwx------')
    local adapter = load_adapter({ command = 'fvm dart', use_lsp = false })
    local spec = adapter.build_spec({
      tree = scope('file', root .. '/test/foo_test.dart'),
      strategy = 'dap',
    })
    assert_eq(spec.strategy._neotest_dart_adapter.command, vim.loop.fs_realpath(executable))
    assert_eq(spec.command[1], 'fvm')
    assert_eq(spec.command[2], 'dart')
    assert(not pcall(adapter.build_spec, {
      tree = scope('file', root .. '/missing/test/foo_test.dart'),
      strategy = 'dap',
    }))
    vim.fn.delete(root, 'rf')
  end
)

test('Flutter and nested directories retain their scope without claiming live support', function()
  local adapter = load_adapter({ command = 'flutter', use_lsp = false })
  local tree = scope('namespace', nil, 'nested')
  local spec = adapter.build_spec({ tree = tree, strategy = 'dap' })
  assert_eq(spec.strategy._neotest_dart_adapter.args, { 'debug-adapter', '--test' })
  assert_eq(spec.strategy.program, tree:data().path)
  assert_eq(spec.strategy.toolArgs[1], '--no-pub')
  assert_eq(spec.strategy.toolArgs[3], '^outer \\[x\\] nested ')
  local nested = adapter.build_spec({ tree = scope('dir', '/tmp/project/test/nested') })
  assert_eq(nested.command[3], '/tmp/project/test/nested')
end)

test('final reports reject unreadable, empty, scalar, malformed and incomplete evidence', function()
  local adapter = load_adapter()
  local tree = scope('test', nil, 'works')
  local function check(data)
    local path = vim.fn.tempname()
    if data then
      vim.fn.writefile(data, path)
    end
    local results = adapter.results({ context = {} }, { output = path }, tree)
    assert_eq(results[tree:data().id].status, 'failed')
    assert(results[tree:data().id].errors[1].message)
    vim.fn.delete(path)
  end
  check(nil)
  check({})
  check({ 'null' })
  check({ 'true' })
  check({ '{truncated' })
  check({ vim.json.encode({ test = { id = 1, name = 'outer [x] works' } }) })
  check({
    vim.json.encode({ test = { id = 1, name = 'outer [x] works' } }),
    vim.json.encode({ testID = 1, result = 'success' }),
  })
  check({ vim.json.encode({ type = 'done', success = true }) })
  check({
    vim.json.encode({ test = { id = 1, name = 'outer [x] works' } }),
    vim.json.encode({ testID = 1, result = 'success', message = {} }),
    vim.json.encode({ type = 'done', success = true }),
  })
end)

test('final reports retain actual pass fail skip and decode escaped source URIs', function()
  local adapter = load_adapter()
  local tree = scope('test', nil, 'works')
  for _, status in ipairs({ 'success', 'failure', 'skipped' }) do
    local report = vim.fn.tempname()
    vim.fn.writefile({
      vim.json.encode({
        test = {
          id = 9,
          name = 'dynamic name',
          url = vim.uri_from_fname(tree:data().path),
          line = 5,
          column = 3,
        },
      }),
      vim.json.encode({
        testID = 9,
        result = status == 'skipped' and 'success' or status,
        skipped = status == 'skipped',
        error = status == 'failure' and 'real failure' or nil,
      }),
      vim.json.encode({ type = 'done', success = status ~= 'failure' }),
    }, report)
    local results = adapter.results(
      { context = { results_path = report } },
      { output = '/not-the-report' },
      tree
    )
    assert_eq(
      results[tree:data().id].status,
      ({ success = 'passed', failure = 'failed', skipped = 'skipped' })[status]
    )
    vim.fn.delete(report)
  end
end)

test('unreadable group reports fail descendants instead of leaving apparent skips', function()
  local adapter = load_adapter()
  local root = scope('file')
  local child = scope('test', nil, 'works')
  root.iter_nodes = function()
    return ipairs({ root, child })
  end
  local results = adapter.results({ context = {} }, { output = vim.fn.tempname() }, root)
  assert_eq(results[root:data().id].status, 'failed')
  assert_eq(results[child:data().id].status, 'failed')
end)

test('a skipped generated case does not hide a passing case at the same location', function()
  load_adapter()
  local tree = scope('test', nil, 'works')
  local lines = {}
  for id, skipped in ipairs({ false, true }) do
    table.insert(
      lines,
      vim.json.encode({
        test = {
          id = id,
          name = 'generated case ' .. id,
          url = vim.uri_from_fname(tree:data().path),
          line = 5,
          column = 3,
        },
      })
    )
    table.insert(lines, vim.json.encode({ testID = id, result = 'success', skipped = skipped }))
  end
  table.insert(lines, vim.json.encode({ type = 'done', success = true }))
  local results = require('neotest-dart.parser').parse_lines(
    tree,
    lines,
    {},
    { final = true, write_output = false }
  )
  assert_eq(results[tree:data().id].status, 'passed')
end)

if #failures > 0 then
  error(table.concat(failures, '\n\n'))
end
