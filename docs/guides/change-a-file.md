---
status: deprecated
---
# Change a file a pattern gives you

Moved to [Fix a provider from a consumer](fix-a-provider.md). Since v2.13.0 a pattern is a git submodule, a
clone of the provider: you fix a provider in place and upstream the fix. To stop adding a provider,
`git rm .patterns/NAME` ([Add your first pattern](add-a-pattern.md#how-it-works)).
