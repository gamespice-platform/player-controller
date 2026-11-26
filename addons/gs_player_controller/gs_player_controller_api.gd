extends RefCounted

## GameSpice Player Controller's API level; the bumping rule is on GameSpice Core's GSAddonApi.
## LEVEL rises by one for anything new a game could call; OLDEST rises to LEVEL when
## something a game could have called is removed or changes meaning.

# One line per level, 1..45: docs/api-levels.md.
const LEVEL := 45
const OLDEST := 1
