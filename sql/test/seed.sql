-- Synthetic data, built to hit the boundaries the answer comments argue,
-- not to resemble Northwind. Each block below maps to one argument.

-- Level 1: Germany vs non-Germany mix.
INSERT INTO Customers (CustomerID, CustomerName, Country) VALUES
  (1, 'Alpha GmbH', 'Germany'),
  (2, 'Beta GmbH',  'Germany'),
  (3, 'Gamma GmbH', 'Germany'),
  (4, 'Delta Inc',  'USA');

-- Level 2: one country with exactly 5 customers (kept by HAVING >= 5),
-- one with exactly 4 (dropped). These same five/four customers double as
-- the level 3 fixtures below.
INSERT INTO Customers (CustomerID, CustomerName, Country) VALUES
  (5, 'Zeta Co',      'Fiveland'),
  (6, 'Eta Co',       'Fiveland'),
  (7, 'Same Name Co', 'Fiveland'),
  (8, 'Same Name Co', 'Fiveland'),
  (9, 'Theta Co',     'Fiveland'),
  (10, 'Nine Co',    'Fourland'),
  (11, 'Ten Co',     'Fourland'),
  (12, 'Eleven Co',  'Fourland'),
  (13, 'Twelve Co',  'Fourland');

-- Level 3 order boundaries.
--
-- Customer 5 (Zeta Co): exactly 5 orders, the HAVING >= 5 boundary, kept.
INSERT INTO Orders (OrderID, CustomerID, OrderDate) VALUES
  (101, 5, '2024-04-01'),
  (102, 5, '2024-04-02'),
  (103, 5, '2024-04-03'),
  (104, 5, '2024-04-04'),
  (105, 5, '2024-04-05');

-- Customer 6 (Eta Co): exactly 4 orders, one under the boundary, dropped.
INSERT INTO Orders (OrderID, CustomerID, OrderDate) VALUES
  (106, 6, '2024-01-01'),
  (107, 6, '2024-01-02'),
  (108, 6, '2024-01-03'),
  (109, 6, '2024-01-04');

-- Customers 7 and 8 share the name "Same Name Co" but are different
-- CustomerIDs. Both clear the >= 5 boundary, so both must survive as two
-- separate rows -- this is what GROUP BY CustomerID, CustomerName protects.
INSERT INTO Orders (OrderID, CustomerID, OrderDate) VALUES
  (110, 7, '2024-02-01'),
  (111, 7, '2024-02-02'),
  (112, 7, '2024-02-03'),
  (113, 7, '2024-02-04'),
  (114, 7, '2024-02-05'),
  (115, 8, '2024-06-01'),
  (116, 8, '2024-06-02'),
  (117, 8, '2024-06-03'),
  (118, 8, '2024-06-04'),
  (119, 8, '2024-06-05'),
  (120, 8, '2024-06-06');

-- Customer 9 (Theta Co): zero orders. An INNER JOIN drops it before HAVING
-- ever runs; a LEFT JOIN would let it through with COUNT = 0 and NULL
-- FirstOrder/LastOrder, and HAVING would discard it immediately after.
-- No Orders rows for CustomerID 9 -- that absence is the fixture.

-- CustomerIDs 10-13 (Fourland) need no orders; they only exist to make
-- Fourland's customer count 4 for the level 2 boundary.
