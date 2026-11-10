-- argparse
local argparse = require('argparse')

local parser = argparse('tool', 'a tool for tests')
parser:argument('input', 'the input file')
parser:option('-o --output', 'the output file', 'out.txt')
parser:flag('-v --verbose', 'more output')
	:count('*')

local args = parser:parse({ 'in.txt', '-vv', '--output', 'result.txt' })
expect_equal(args.input, 'in.txt')
expect_equal(args.output, 'result.txt')
expect_equal(args.verbose, 2)
expect_equal(parser:parse({ 'in.txt' }).output, 'out.txt', 'a default')

-- errors are returned by pparse rather than exiting
local ok, err = parser:pparse({})
expect_equal(ok, false)
assert(err:find('missing argument'), err)
assert(parser:get_usage():find('Usage: tool'))
