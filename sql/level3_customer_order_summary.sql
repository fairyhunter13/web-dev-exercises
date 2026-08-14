-- Level 3 — Reverse-engineered from the target result set.
--
-- What the screenshot tells you, column by column:
--   CustomerName  -> Customers
--   OrderCount    -> COUNT over Orders, so an aggregate join is required
--   FirstOrder    -> MIN(OrderDate)
--   LastOrder     -> MAX(OrderDate)
-- and from the rows themselves: every customer shown has 5 or more orders
-- (so HAVING COUNT(...) >= 5), and LastOrder descends down the page
-- (so ORDER BY LastOrder DESC).
--
-- INNER JOIN, not LEFT JOIN: a customer with zero orders could never satisfy
-- the >= 5 filter, so the outer join would only add rows that are immediately
-- discarded.
--
-- GROUP BY includes CustomerID as well as CustomerName. Names are not
-- guaranteed unique; grouping by the key keeps two same-named customers from
-- being collapsed into one row.

SELECT c.CustomerName,
       COUNT(o.OrderID) AS OrderCount,
       MIN(o.OrderDate) AS FirstOrder,
       MAX(o.OrderDate) AS LastOrder
FROM Customers c
JOIN Orders o ON o.CustomerID = c.CustomerID
GROUP BY c.CustomerID, c.CustomerName
HAVING COUNT(o.OrderID) >= 5
ORDER BY LastOrder DESC;

-- Verified output (docs/evidence/sql-l3.png): 9 rows matching the target
-- screenshot in counts, dates and ordering. The one difference is rendering, not
-- data: the emulator prints "La maison dAsie" where the target shows
-- "La maison d'Asie". The apostrophe is in the row below because that is what the
-- Customers table actually stores.
--
--   CustomerName                   OrderCount  FirstOrder  LastOrder
--   Ernst Handel                           10  1996-07-17  1997-02-11
--   Mère Paillarde                          5  1996-10-17  1997-02-07
--   Wartian Herkku                          7  1996-07-26  1997-02-05
--   Split Rail Beer & Ale                   6  1996-08-01  1997-01-31
--   Hungry Owl All-Night Grocers            6  1996-09-05  1997-01-29
--   La maison d'Asie                        5  1996-11-11  1997-01-24
--   QUICK-Stop                              7  1996-08-05  1997-01-17
--   Rattlesnake Canyon Grocery              7  1996-07-22  1997-01-01
--   LILA-Supermercado                       5  1996-08-16  1996-12-12
