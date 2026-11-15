# assets

Files packed into every package, exactly as in the packages already published. Their SHA-256 values are
recorded in `config/repos.json`.

- `icon.png`: SHA-256 `c841a6d75edd0c216075df32e3c3e3ec0012d3e85b8b566e39fa0ed02d93b6fd`
- `licence.txt`: GNU LGPL v3, SHA-256 `cfb70a2be6b545997020a3b024d0adcb1a4f06cd4bf1029e5a24ee7825a1785a`,
  used only when a repository has no `licence.txt` of its own

There is no readme fallback. Every package carries its own repository's README, as the bot's packages of
the 16 do, and a repository without one fails the build with a message naming it.
