-- Level 1 — How many customers are from Germany?
--
-- Dialect note: the w3schools "Try it" editor is Microsoft SQL Server
-- (ODBC Driver 17), not MySQL. Backtick-quoted identifiers fail with
-- "Incorrect syntax near '`'"; use [brackets] and TOP, never LIMIT.

SELECT COUNT(*) AS GermanCustomers
FROM Customers
WHERE Country = 'Germany';

-- Verified output (docs/evidence/sql-l1.png):
--   Number of Records: 1
--   GermanCustomers
--   11
