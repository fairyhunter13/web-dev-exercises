# PROVISIONED rather than PAY_PER_REQUEST.
#
# On-demand looks like the fit for a bursty demo, but DynamoDB's Always Free
# allowance is 25 read and 25 write capacity units and those units only exist
# under provisioned billing. On-demand gets the 25 GB of free storage and pays
# per request for everything else. Five units each is far more than two browser
# windows need and stays inside the free grant.

resource "aws_dynamodb_table" "connections" {
  name         = "${var.name_prefix}-connections"
  billing_mode = "PROVISIONED"

  read_capacity  = 5
  write_capacity = 5

  hash_key = "connectionId"

  attribute {
    name = "connectionId"
    type = "S"
  }

  # The backstop for connections whose $disconnect never fired: API Gateway
  # invokes it on a best-effort basis. TTL deletion is
  # asynchronous (AWS documents "typically within a few days"), so the handler
  # filters on expiresAt as well rather than trusting it to be prompt.
  ttl {
    attribute_name = "expiresAt"
    enabled        = true
  }

  point_in_time_recovery {
    # Off: PITR is billed per GB and the contents are ephemeral by design.
    enabled = false
  }
}

resource "aws_dynamodb_table" "messages" {
  name         = "${var.name_prefix}-messages"
  billing_mode = "PROVISIONED"

  read_capacity  = 5
  write_capacity = 5

  # One partition per room, sorted by time. The demo has a single room, so this
  # is a hot partition by construction. Fine at two clients, and the reason the
  # design would need sharding before real traffic.
  hash_key  = "room"
  range_key = "sortKey"

  attribute {
    name = "room"
    type = "S"
  }

  attribute {
    name = "sortKey"
    type = "S"
  }

  ttl {
    attribute_name = "expiresAt"
    enabled        = true
  }

  point_in_time_recovery {
    enabled = false
  }
}
