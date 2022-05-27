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
* **Commit**: [`0715cd42`](https://github.com/obsidiansystems/beam-automigrate/commit/0715cd42cfcdef67e5fd27579916c189c46f9390)
* **Issue**: [#36](https://github.com/obsidiansystems/beam-automigrate/issues/36)
* **Pull request**: [#37](https://github.com/obsidiansystems/beam-automigrate/pull/37)

### Problem

When loading a `Schema` from PostgreSQL, foreign key constraints are
discovered by referencing the `information_schema` tables using the query
defined in `foreignKeysQ`.  The ordering of the columns in the foreign table
must match the ordering of the columns in the primary table.  The query does
not specify the order, however, resulting in incorrect `ForeignKey`s when the
returned order does not happen to match the correct order.  Since the order of
`ForeignKey` column pairs is determined by `Set.toList`, it often does not
match the order of columns in composite primary keys, which makes hitting this
bug pretty likely when using composite keys.

### Solution

The query is changed to specify the order within the aggregate functions.

### Migration

No migration is required.

## Annotated foreign key constraint names not unique

* **Severity**: Critical (prevents modeling real-world databases)
* **Compatibility**: Breaking
* **Status**: Pending
* **Commits**:
    * [`2f197aab`](https://github.com/TravisCardwell/beam-automigrate/commit/2f197aab5f3fabee9646410b77eb923ff0bfbc89)
    * [`58df62d8`](https://github.com/TravisCardwell/beam-automigrate/commit/58df62d86af30862258e35bca32e5ad832d9432d)
* **Issue**: [#38](https://github.com/obsidiansystems/beam-automigrate/issues/38)
* **Pull request**: [#39](https://github.com/obsidiansystems/beam-automigrate/pull/39)

### Problem

When annotating foreign key constraints using `foreignKeyOnPk` or
`foreignKeyOn`, constraint names are automatically created based on the table
and columns of the *referenced* unique constraint.  The name is not
necessarily unique because many tables may have foreign key constraints that
reference the same unique constraint.  The constraint name clashes prevent
`beam-automigrate` from being able to model non-trivial databases.

When automatic foreign key discovery is used, constraint names are already
based on the table and columns of the foreign key constraint, but only the
first column is taken into account.  Constraint names are not unique in cases
where more than more than one constraint have the same first column.

### Solution

The above functions are changed so that constraint names are based on the
table and columns of the foreign key constraint.  This provides unique
constraint names in *normal* usage.

It is not normal to specify more than one foreign key constraint on the same
columns, though it is conceivable in a database with "is-a" relationships
where multiple tables share the same primary keys.  This fix does *not* help
with this case.  If we want to provide a solution for this case, we should
provide an additional function that allows the developer to specify the
constraint name.  (With "is-a" relationships, one normally creates a hierarchy
of foreign key constraints, so there are no constraints on the same columns.)

The `GTableConstraintColumns` instance is changed so that the constraint name
includes all of the constraint columns.

### Migration

When annotating foreign key constraints, all foreign key constraint names
change.  In a production PostgreSQL database where performance is a
consideration, constraints should be renamed using `RENAME CONSTRAINT`
commands.  Note that this command is only available in PostgreSQL 9.2 or
newer.  The developer must order the commands so that there are no conflicts.
Conflicts are likely because of the very problem that this fix resolves.

```sql
ALTER TABLE name RENAME CONSTRAINT old_name TO new_name;
```

Migrations created by `beam-automigrate` work in simple cases, but even then
adding and dropping constraints is not production-friendly.  Moreover, the
migrations are incorrect in non-simple cases since `beam-automigrate` does not
handle name collisions and naively orders migration steps.

## Foreign key constraints with nullable references

* **Severity**: Critical (prevents modeling real-world databases)
* **Compatibility**: Non-Breaking (new API functions)
* **Status**: Pending
* **Commit**: [`94043de3`](https://github.com/TravisCardwell/beam-automigrate/commit/94043de3babdad706d61ddc4b4134eb0f9a91ca2)
* **Issue**: [#40](https://github.com/obsidiansystems/beam-automigrate/issues/40)
* **Pull request**: Pending

### Problem

The current API does not provide a way to annotate a table with a foreign key
constraint when the column is nullable.  This type of constraint is very
common, as it used for optional one-to-one relations (often marked as `?` or
`0|1` in database software).

### Solution

I implemented new functions `nullableForeignKeyOnPk` and
`nullableForeignKeyOn` to support this.

### Migration

No migration is required.
