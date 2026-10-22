# Workspace fixtures

One folder per workspace version a build still reads, from
`WorkspaceMigration.oldestReadable` on: `v<N>/Project.json`, written by the
build of version N (`WorkspaceVersionTests.version<N>Sample()`).

A fixture is never rewritten. When `Workspace.currentVersion` goes up, the
folder of the version left behind stays as it is, a new one is added for the
new version, and the old one's test then checks that the migration brings it
to what the new types describe.
