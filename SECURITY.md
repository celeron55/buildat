Security
========

Report a vulnerability to **sec@buildat.org**, not in a public issue.
Say what it reaches, how to reproduce it, and which version or commit you
used.

What counts most here:

- an app escaping the server's sandbox (Landlock and seccomp on Linux, the
  AppContainer on Windows);
- a server's Lua escaping the client's sandbox, or imitating the client's
  own Starport and consent dialogs;
- Starport, accounts and their tokens: taking over an ID or an account,
  or learning what a community should not see.

Only the latest release is supported. A fix and its public description go
out together, in a release; the reporter is credited unless they ask not
to be.
