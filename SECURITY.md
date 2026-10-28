# Security policy

Wicket sits in front of business data, so security reports are taken seriously.

## Reporting a vulnerability

Please **do not open a public issue** for a security problem. Report it privately through GitHub's
private vulnerability reporting: the repository's **Security** tab → **Report a vulnerability**.

Include what you found, the steps or request that reproduce it, and the version (`app.json` of the
core extension, and of the actions companion if it is involved). You will get an acknowledgement, and
the fix and its disclosure will be coordinated with you.

## Supported versions

Fixes are made on the latest release. Business Central upgrades an installed extension only to a
higher version, so upgrade to the release that carries the fix.

## Scope

In scope: the AL extensions (`app/`, `actions/`). Issues in the MCP server, the plugin or the skill
belong to the [plugin repository](https://github.com/davesmith7403/wicket) and are reported there the same way. Issues in
Business Central itself, in Microsoft's System or Base Application, or in a tenant's own
configuration (for example an over-broad exposure or permission assignment) should go to the
respective owner.
