// Package awsstore adapts DynamoDB and the API Gateway management API to the
// interfaces in package gateway. It is the only place in the backend that
// imports the AWS SDK, which is what keeps the routing logic testable without
// mocking a cloud.
package awsstore

import (
	"context"
	"fmt"
	"slices"
	"strconv"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/dynamodb"
	"github.com/aws/aws-sdk-go-v2/service/dynamodb/types"

	"github.com/fairyhunter13/web-dev-exercises/chat/backend/internal/chat"
)

// The transcript is one DynamoDB partition. A real chat would partition by
// room; this demo has a single room, and pretending otherwise would add a key
// nobody ever varies.
const room = "main"

// TTLs. Both tables expire their own rows, so the demo stays inside the free
// tier without a scheduled sweeper. Connections cannot outlive API Gateway's
// own 2-hour hard cap, and the transcript only has to survive a demo.
const (
	connectionTTL = 3 * time.Hour
	messageTTL    = 24 * time.Hour
)

// dynamoAPI is the part of *dynamodb.Client that Dynamo actually calls. It
// exists so the store can be tested without AWS. The real client already
// satisfies it, so nothing in production changes.
type dynamoAPI interface {
	PutItem(context.Context, *dynamodb.PutItemInput, ...func(*dynamodb.Options)) (*dynamodb.PutItemOutput, error)
	DeleteItem(context.Context, *dynamodb.DeleteItemInput, ...func(*dynamodb.Options)) (*dynamodb.DeleteItemOutput, error)
	Query(context.Context, *dynamodb.QueryInput, ...func(*dynamodb.Options)) (*dynamodb.QueryOutput, error)
	Scan(context.Context, *dynamodb.ScanInput, ...func(*dynamodb.Options)) (*dynamodb.ScanOutput, error)
}

// Dynamo implements gateway.Store.
type Dynamo struct {
	Client          dynamoAPI
	ConnectionTable string
	MessageTable    string
	Now             func() time.Time
}

func (d *Dynamo) now() time.Time {
	if d.Now != nil {
		return d.Now()
	}
	return time.Now()
}

func (d *Dynamo) AddConnection(ctx context.Context, connID string) error {
	_, err := d.Client.PutItem(ctx, &dynamodb.PutItemInput{
		TableName: aws.String(d.ConnectionTable),
		Item: map[string]types.AttributeValue{
			"connectionId": &types.AttributeValueMemberS{Value: connID},
			"expiresAt":    epoch(d.now().Add(connectionTTL)),
		},
	})
	if err != nil {
		return fmt.Errorf("put connection: %w", err)
	}
	return nil
}

func (d *Dynamo) RemoveConnection(ctx context.Context, connID string) error {
	_, err := d.Client.DeleteItem(ctx, &dynamodb.DeleteItemInput{
		TableName: aws.String(d.ConnectionTable),
		Key: map[string]types.AttributeValue{
			"connectionId": &types.AttributeValueMemberS{Value: connID},
		},
	})
	if err != nil {
		return fmt.Errorf("delete connection: %w", err)
	}
	return nil
}

// Connections lists every live connection.
//
// A Scan. The table holds only currently-open sockets, so it is a handful of
// rows, and a GSI over a table this small costs more write capacity than it
// saves. At a scale where that stops being true, the fix is sharded partitions.
//
// TTL deletion is not immediate. DynamoDB typically removes expired items
// within a couple of days, so rows are filtered on expiresAt here too. Without
// that filter, a stale row would be broadcast to on every message until the
// GoneException reaped it.
func (d *Dynamo) Connections(ctx context.Context) ([]string, error) {
	var out []string
	pages := dynamodb.NewScanPaginator(d.Client, &dynamodb.ScanInput{
		TableName:            aws.String(d.ConnectionTable),
		ProjectionExpression: aws.String("connectionId"),
		FilterExpression:     aws.String("expiresAt > :now"),
		ExpressionAttributeValues: map[string]types.AttributeValue{
			":now": epoch(d.now()),
		},
	})
	for pages.HasMorePages() {
		page, err := pages.NextPage(ctx)
		if err != nil {
			return nil, fmt.Errorf("scan connections: %w", err)
		}
		for _, item := range page.Items {
			if v, ok := item["connectionId"].(*types.AttributeValueMemberS); ok {
				out = append(out, v.Value)
			}
		}
	}
	return out, nil
}

// AppendMessage stores one message. The sort key is the zero-padded timestamp
// followed by the message id: padding keeps DynamoDB's lexicographic ordering
// equal to numeric ordering, and the id suffix keeps two messages in the same
// millisecond from overwriting each other.
func (d *Dynamo) AppendMessage(ctx context.Context, m chat.Message) error {
	item := map[string]types.AttributeValue{
		"room":      &types.AttributeValueMemberS{Value: room},
		"sortKey":   &types.AttributeValueMemberS{Value: fmt.Sprintf("%013d#%s", m.SentAtMS, m.ID)},
		"id":        &types.AttributeValueMemberS{Value: m.ID},
		"author":    &types.AttributeValueMemberS{Value: m.Author},
		"body":      &types.AttributeValueMemberS{Value: m.Body},
		"sentAtMs":  &types.AttributeValueMemberN{Value: strconv.FormatInt(m.SentAtMS, 10)},
		"expiresAt": epoch(d.now().Add(messageTTL)),
	}
	if m.ClientID != "" {
		item["clientId"] = &types.AttributeValueMemberS{Value: m.ClientID}
	}

	if _, err := d.Client.PutItem(ctx, &dynamodb.PutItemInput{
		TableName: aws.String(d.MessageTable),
		Item:      item,
	}); err != nil {
		return fmt.Errorf("put message: %w", err)
	}
	return nil
}

// Recent returns the last `limit` messages in chronological order.
//
// The query runs backwards (ScanIndexForward false) so the Limit takes the
// newest rows rather than the oldest, then the slice is reversed for display.
func (d *Dynamo) Recent(ctx context.Context, limit int) ([]chat.Message, error) {
	out, err := d.Client.Query(ctx, &dynamodb.QueryInput{
		TableName:              aws.String(d.MessageTable),
		KeyConditionExpression: aws.String("room = :room"),
		ExpressionAttributeValues: map[string]types.AttributeValue{
			":room": &types.AttributeValueMemberS{Value: room},
		},
		ScanIndexForward: aws.Bool(false),
		Limit:            aws.Int32(int32(limit)),
	})
	if err != nil {
		return nil, fmt.Errorf("query messages: %w", err)
	}

	msgs := make([]chat.Message, 0, len(out.Items))
	for _, item := range out.Items {
		msgs = append(msgs, chat.Message{
			ID:       stringAttr(item, "id"),
			Author:   stringAttr(item, "author"),
			Body:     stringAttr(item, "body"),
			SentAtMS: intAttr(item, "sentAtMs"),
			ClientID: stringAttr(item, "clientId"),
		})
	}
	slices.Reverse(msgs)
	return msgs, nil
}

func epoch(t time.Time) types.AttributeValue {
	return &types.AttributeValueMemberN{Value: strconv.FormatInt(t.Unix(), 10)}
}

func stringAttr(item map[string]types.AttributeValue, key string) string {
	if v, ok := item[key].(*types.AttributeValueMemberS); ok {
		return v.Value
	}
	return ""
}

func intAttr(item map[string]types.AttributeValue, key string) int64 {
	v, ok := item[key].(*types.AttributeValueMemberN)
	if !ok {
		return 0
	}
	n, err := strconv.ParseInt(v.Value, 10, 64)
	if err != nil {
		return 0
	}
	return n
}
