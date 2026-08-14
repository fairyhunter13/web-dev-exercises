-- Level 2 — Number of customers per country, highest first,
-- excluding countries with fewer than 5 customers.
--
-- HAVING, not WHERE: the filter is on an aggregate, and WHERE is evaluated
-- before grouping, so the aggregate does not exist yet at that point.
--
-- COUNT(CustomerID) rather than COUNT(*), unaliased, only to match the column
-- the target table shows. CustomerID is the primary key, so the counts are
-- identical either way.
--
-- The second ORDER BY key is not cosmetic. France and Germany both have 11 and
-- Spain and Mexico both have 5, and SQL Server does not guarantee the relative
-- order of rows that tie on the sort key -- without a tie-break the result can
-- change between runs. DESC rather than ASC because that is the order the
-- target table is in.

SELECT COUNT(CustomerID), Country
FROM Customers
GROUP BY Country
HAVING COUNT(CustomerID) >= 5
ORDER BY COUNT(CustomerID) DESC, Country DESC;

-- Verified output (docs/evidence/sql-l2.png) -- matches the target exactly:
--   Number of Records: 7
--   (count)  Country
--   13       USA
--   11       Germany
--   11       France
--    9       Brazil
--    7       UK
--    5       Spain
--    5       Mexico
