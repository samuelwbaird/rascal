-- LPeg, and its re module
local lpeg = require('lpeg')
local re = require('re')

-- a pattern for comma separated numbers, captured as a list
local number = lpeg.C(lpeg.R('09') ^ 1) / tonumber
local list = lpeg.Ct(number * (',' * number) ^ 0) * -1
local numbers = list:match('1,22,333')
expect_equal(#numbers, 3)
expect_equal(numbers[3], 333)
expect_equal(list:match('1,,2'), nil, 'an invalid list does not match')

-- the same with re's regex like syntax
local pattern = re.compile([[ list <- {| number (',' number)* |} !.  number <- {%d+} -> tonumber ]], { tonumber = tonumber })
expect_equal(pattern:match('4,5')[2], 5)
expect_equal(re.gsub('hello world', '%a+', '<%0>'), '<hello> <world>')
