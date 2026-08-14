# sql/test

A harness for the three answers in `sql/`. It does not touch the answer
files; it runs them against synthetic fixtures and checks the output.

## Dialect caveat

This runs on SQLite (3.44.4). The answers were verified against w3schools'
SQL Server (ODBC Driver 17) editor -- see the "Dialect note" in
`level1_germany_count.sql`. The three queries happen to use no dialect-
specific syntax (no `TOP`, no bracket identifiers, no SQL Server functions),
so the same SQL runs unchanged on both engines. That is a coincidence of
these particular queries, not a general guarantee, and it is a real
limitation of this harness: it proves the query logic is correct against
these fixtures, not that the query is valid SQL Server syntax. The
screenshots in `docs/evidence/` remain the evidence for that.

## What the fixtures cover

`schema.sql` and `seed.sql` build a small Customers/Orders dataset designed
to hit the boundaries the answer comments argue, not to look like Northwind:

- a customer with exactly 5 orders (kept by `HAVING COUNT(...) >= 5`) and one
  with exactly 4 (dropped)
- two customers with the same name but different CustomerIDs, both with
  enough orders to qualify -- this is why level 3 groups by CustomerID as
  well as CustomerName; grouping by name alone would collapse them into one
  row
- a customer with zero orders, to back up the INNER JOIN argument: it never
  reaches HAVING because the join drops it first
- a country with exactly 5 customers (kept) and one with exactly 4 (dropped),
  for the level 2 boundary
- a Germany / non-Germany mix, for level 1

## Running it

```
sql/test/run.sh
```

Works from any working directory. Exits 0 if all three queries match their
expected output, non-zero otherwise (with a diff printed).
