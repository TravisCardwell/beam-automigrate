# beam-automigrate tc-develop branch

The [`tc-develop` branch][] will contain all of my proposed changes to
[`beam-automigrate`][].  This file documents each change, with details about
migration when changes are breaking.  Changes to the code and changes to this
document are done in separate commits, to allow for cherry-picking.  (I am
happy to create incremental pull requests if that is easier.)  This file
should help with creating a migration guide for any changes that are included
in a future release.

[`tc-develop` branch]: <https://github.com/TravisCardwell/beam-automigrate/tree/tc-develop>
[`beam-automigrate`]: <https://github.com/obsidiansystems/beam-automigrate>

## Composite foreign key constraint column order sometimes incorrect

* **Severity**: Critical (prevents modeling real-world databases)
* **Compatibility**: Non-Breaking (only previously broken behavior changes)
* **Status**: Merged into `develop`
* **Commit**: [`0715cd4`](https://github.com/obsidiansystems/beam-automigrate/commit/0715cd42cfcdef67e5fd27579916c189c46f9390)
* **Issue**: [#36](https://github.com/obsidiansystems/beam-automigrate/issues/36)
* **Pull request**: [#37](https://github.com/obsidiansystems/beam-automigrate/pull/37)

### Problem

When loading a `Schema` from PostgreSQL, foreign key constraints are
discovered by referencing the `information_schema` tables using the query
defined in [`foreignKeysQ`][].  The ordering of the columns in the foreign
table must match the ordering of the columns in the primary table.  The query
does not specify the order, however, resulting in incorrect `ForeignKey`s when
the returned order does not happen to match the correct order.  Since the
order of `ForeignKey` column pairs is determined by `Set.toList`, it often
does not match the order of columns in composite primary keys, which makes
hitting this bug pretty likely when using composite keys.

[`foreignKeysQ`]: <https://github.com/obsidiansystems/beam-automigrate/blob/8144bc7f8bbd0ac043b5abb0b1000e369ae8c776/src/Database/Beam/AutoMigrate/Postgres.hs#L146>

### Solution

The query is changed to specify the order within the aggregate functions.

### Migration

No migration is required.
