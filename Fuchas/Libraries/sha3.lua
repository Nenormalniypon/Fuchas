-- Compatibility module for users.lua, which does require("sha3").
--
-- The SHA-3 implementation is shipped as sha3.min.lua.  Dots in a module
-- name are translated to path separators by package.searchpath, so
-- require("sha3.min") would look for "sha3/min.lua" and never find it.
-- Load the minified file directly instead.
return assert(loadfile("A:/Fuchas/Libraries/sha3.min.lua"))()
