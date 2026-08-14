-- Minimal Customers/Orders schema, just the columns the three answers touch.
-- Column names match the w3schools Northwind sample so the queries run
-- unmodified against this data.

CREATE TABLE Customers (
  CustomerID   INTEGER PRIMARY KEY,
  CustomerName TEXT NOT NULL,
  Country      TEXT NOT NULL
);

CREATE TABLE Orders (
  OrderID    INTEGER PRIMARY KEY,
  CustomerID INTEGER NOT NULL REFERENCES Customers(CustomerID),
  OrderDate  TEXT NOT NULL
);
