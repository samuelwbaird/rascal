-- init — runs in every Lua state rascal creates (the main state and
-- each thread) before anything else, unless rascal is started with --no-init
--
-- It runs after the standard libraries and module searchers are set up, but
-- before RASCAL_INIT, -e, -l and the script, and before the global 'arg'
-- table exists. Errors here stop rascal from starting.

require('prelude').global()
