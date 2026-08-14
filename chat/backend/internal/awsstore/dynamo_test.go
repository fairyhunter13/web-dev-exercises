package awsstore

import (
	"context"
	"errors"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/aws/aws-sdk-go-v2/service/dynamodb"
	"github.com/aws/aws-sdk-go-v2/service/dynamodb/types"

	"github.com/fairyhunter13/web-dev-exercises/chat/backend/internal/chat"
)

// fakeDynamo is a hand-rolled dynamoAPI, not concurrency-safe: each test drives
// one Dynamo call at a time, matching how a single Lambda invocation uses it.
type fakeDynamo struct {
	putItems  []map[string]types.AttributeValue
	putErr    error
	deleted   []map[string]types.AttributeValue
	deleteErr error
	queryOut  *dynamodb.QueryOutput
	queryErr  error
	scanOut   *dynamodb.ScanOutput
	scanErr   error
	lastScan  *dynamodb.ScanInput
	lastQuery *dynamodb.QueryInput
}

func (f *fakeDynamo) PutItem(_ context.Context, in *dynamodb.PutItemInput, _ ...func(*dynamodb.Options)) (*dynamodb.PutItemOutput, error) {
	if f.putErr != nil {
		return nil, f.putErr
	}
	f.putItems = append(f.putItems, in.Item)
	return &dynamodb.PutItemOutput{}, nil
}

func (f *fakeDynamo) DeleteItem(_ context.Context, in *dynamodb.DeleteItemInput, _ ...func(*dynamodb.Options)) (*dynamodb.DeleteItemOutput, error) {
	if f.deleteErr != nil {
		return nil, f.deleteErr
	}
	f.deleted = append(f.deleted, in.Key)
	return &dynamodb.DeleteItemOutput{}, nil
}

func (f *fakeDynamo) Query(_ context.Context, in *dynamodb.QueryInput, _ ...func(*dynamodb.Options)) (*dynamodb.QueryOutput, error) {
	f.lastQuery = in
	if f.queryErr != nil {
		return nil, f.queryErr
	}
	return f.queryOut, nil
}

func (f *fakeDynamo) Scan(_ context.Context, in *dynamodb.ScanInput, _ ...func(*dynamodb.Options)) (*dynamodb.ScanOutput, error) {
	f.lastScan = in
	if f.scanErr != nil {
		return nil, f.scanErr
	}
	return f.scanOut, nil
}

func stringAttrOf(v types.AttributeValue) string {
	if s, ok := v.(*types.AttributeValueMemberS); ok {
		return s.Value
	}
	return ""
}

// TestAppendMessageSortKeyOrdersLexicographicallyLikeChronologically locks in
// the claim in the AppendMessage doc comment: zero-padding the timestamp to 13
// digits keeps DynamoDB's lexicographic sort equal to numeric sort. Without the
// padding, a message at ms=999 would sort after one at ms=1000, because '9' >
// '1' as characters even though 999 < 1000 as numbers.
func TestAppendMessageSortKeyOrdersLexicographicallyLikeChronologically(t *testing.T) {
	client := &fakeDynamo{}
	d := &Dynamo{Client: client, MessageTable: "messages", Now: func() time.Time { return time.Unix(0, 0) }}

	if err := d.AppendMessage(context.Background(), chat.Message{ID: "earlier", SentAtMS: 999}); err != nil {
		t.Fatalf("AppendMessage: %v", err)
	}
	if err := d.AppendMessage(context.Background(), chat.Message{ID: "later", SentAtMS: 1000}); err != nil {
		t.Fatalf("AppendMessage: %v", err)
	}

	if len(client.putItems) != 2 {
		t.Fatalf("want 2 PutItem calls, got %d", len(client.putItems))
	}
	keyAt999 := stringAttrOf(client.putItems[0]["sortKey"])
	keyAt1000 := stringAttrOf(client.putItems[1]["sortKey"])

	if keyAt999 != "0000000000999#earlier" {
		t.Fatalf("sortKey = %q, want zero-padded to 13 digits", keyAt999)
	}
	if keyAt1000 != "0000000001000#later" {
		t.Fatalf("sortKey = %q, want zero-padded to 13 digits", keyAt1000)
	}
	// The claim under test: raw string comparison must agree with chronological
	// order even though "999" > "1000" as unpadded strings.
	if strings.Compare(keyAt999, keyAt1000) >= 0 {
		t.Fatalf("padded keys sort out of chronological order: %q >= %q", keyAt999, keyAt1000)
	}
}

// TestAppendMessageSortKeyDisambiguatesSameMillisecond locks in the id suffix:
// two messages stamped in the same millisecond must not collide on sortKey.
func TestAppendMessageSortKeyDisambiguatesSameMillisecond(t *testing.T) {
	client := &fakeDynamo{}
	d := &Dynamo{Client: client, MessageTable: "messages", Now: func() time.Time { return time.Unix(0, 0) }}

	if err := d.AppendMessage(context.Background(), chat.Message{ID: "a", SentAtMS: 1000}); err != nil {
		t.Fatalf("AppendMessage: %v", err)
	}
	if err := d.AppendMessage(context.Background(), chat.Message{ID: "b", SentAtMS: 1000}); err != nil {
		t.Fatalf("AppendMessage: %v", err)
	}

	keyA := stringAttrOf(client.putItems[0]["sortKey"])
	keyB := stringAttrOf(client.putItems[1]["sortKey"])
	if keyA == keyB {
		t.Fatalf("two messages in the same millisecond collided on sortKey: %q", keyA)
	}
}

func TestAddConnectionStoresIDAndTTL(t *testing.T) {
	client := &fakeDynamo{}
	now := time.Unix(1_000, 0)
	d := &Dynamo{Client: client, ConnectionTable: "connections", Now: func() time.Time { return now }}

	if err := d.AddConnection(context.Background(), "c1"); err != nil {
		t.Fatalf("AddConnection: %v", err)
	}
	if len(client.putItems) != 1 {
		t.Fatalf("want 1 PutItem call, got %d", len(client.putItems))
	}
	if got := stringAttrOf(client.putItems[0]["connectionId"]); got != "c1" {
		t.Fatalf("connectionId = %q, want c1", got)
	}
	wantExpiry := strconv.FormatInt(now.Add(connectionTTL).Unix(), 10)
	if got := client.putItems[0]["expiresAt"].(*types.AttributeValueMemberN).Value; got != wantExpiry {
		t.Fatalf("expiresAt = %q, want %q (now + connectionTTL)", got, wantExpiry)
	}
}

func TestAddConnectionPropagatesPutError(t *testing.T) {
	want := errors.New("throttled")
	client := &fakeDynamo{putErr: want}
	d := &Dynamo{Client: client, ConnectionTable: "connections"}

	err := d.AddConnection(context.Background(), "c1")
	if !errors.Is(err, want) {
		t.Fatalf("err = %v, want %v", err, want)
	}
}

func TestRemoveConnectionDeletesByID(t *testing.T) {
	client := &fakeDynamo{}
	d := &Dynamo{Client: client, ConnectionTable: "connections"}

	if err := d.RemoveConnection(context.Background(), "c1"); err != nil {
		t.Fatalf("RemoveConnection: %v", err)
	}
	if len(client.deleted) != 1 || stringAttrOf(client.deleted[0]["connectionId"]) != "c1" {
		t.Fatalf("deleted = %+v, want a delete keyed on c1", client.deleted)
	}
}

func TestRemoveConnectionPropagatesDeleteError(t *testing.T) {
	want := errors.New("throttled")
	client := &fakeDynamo{deleteErr: want}
	d := &Dynamo{Client: client, ConnectionTable: "connections"}

	err := d.RemoveConnection(context.Background(), "c1")
	if !errors.Is(err, want) {
		t.Fatalf("err = %v, want %v", err, want)
	}
}

func TestAppendMessagePropagatesPutError(t *testing.T) {
	want := errors.New("throttled")
	client := &fakeDynamo{putErr: want}
	d := &Dynamo{Client: client, MessageTable: "messages"}

	err := d.AppendMessage(context.Background(), chat.Message{ID: "1", SentAtMS: 1})
	if !errors.Is(err, want) {
		t.Fatalf("err = %v, want %v", err, want)
	}
}

func TestConnectionsPropagatesScanError(t *testing.T) {
	want := errors.New("throttled")
	client := &fakeDynamo{scanErr: want}
	d := &Dynamo{Client: client, ConnectionTable: "connections"}

	_, err := d.Connections(context.Background())
	if !errors.Is(err, want) {
		t.Fatalf("err = %v, want %v", err, want)
	}
}

func TestRecentPropagatesQueryError(t *testing.T) {
	want := errors.New("throttled")
	client := &fakeDynamo{queryErr: want}
	d := &Dynamo{Client: client, MessageTable: "messages"}

	_, err := d.Recent(context.Background(), 10)
	if !errors.Is(err, want) {
		t.Fatalf("err = %v, want %v", err, want)
	}
}

// TestNowDefaultsToWallClock covers the fallback branch: most Dynamo values in
// production leave Now nil, and only tests inject a fixed clock.
func TestNowDefaultsToWallClock(t *testing.T) {
	client := &fakeDynamo{}
	d := &Dynamo{Client: client, ConnectionTable: "connections"}
	before := time.Now()

	if err := d.AddConnection(context.Background(), "c1"); err != nil {
		t.Fatalf("AddConnection: %v", err)
	}

	got, err := strconv.ParseInt(client.putItems[0]["expiresAt"].(*types.AttributeValueMemberN).Value, 10, 64)
	if err != nil {
		t.Fatalf("expiresAt not numeric: %v", err)
	}
	wantMin := before.Add(connectionTTL).Unix()
	if got < wantMin {
		t.Fatalf("expiresAt = %d, want at least %d (real clock + connectionTTL)", got, wantMin)
	}
}

// TestRecentSkipsWrongTypeSentAtMs covers intAttr's type guard: a row whose
// sentAtMs arrived as a string degrades to 0 rather than failing the whole page.
func TestRecentSkipsWrongTypeSentAtMs(t *testing.T) {
	item := map[string]types.AttributeValue{
		"id":       &types.AttributeValueMemberS{Value: "bad"},
		"sentAtMs": &types.AttributeValueMemberS{Value: "not-a-number"},
	}
	client := &fakeDynamo{queryOut: &dynamodb.QueryOutput{Items: []map[string]types.AttributeValue{item}}}
	d := &Dynamo{Client: client, MessageTable: "messages"}

	got, err := d.Recent(context.Background(), 1)
	if err != nil {
		t.Fatalf("Recent: %v", err)
	}
	if len(got) != 1 || got[0].SentAtMS != 0 {
		t.Fatalf("Recent = %+v, want SentAtMS 0 for a malformed value", got)
	}
}

// TestRecentReadsEveryField is the round trip the other Recent tests assume: a
// well-formed row comes back with its timestamp parsed and its optional
// clientId carried through, which is what lets the browser reconcile the copy
// the sender already rendered.
func TestRecentReadsEveryField(t *testing.T) {
	item := map[string]types.AttributeValue{
		"id":       &types.AttributeValueMemberS{Value: "m1"},
		"author":   &types.AttributeValueMemberS{Value: "ada"},
		"body":     &types.AttributeValueMemberS{Value: "hello"},
		"sentAtMs": &types.AttributeValueMemberN{Value: "1700000000123"},
		"clientId": &types.AttributeValueMemberS{Value: "c-9"},
	}
	client := &fakeDynamo{queryOut: &dynamodb.QueryOutput{Items: []map[string]types.AttributeValue{item}}}
	d := &Dynamo{Client: client, MessageTable: "messages"}

	got, err := d.Recent(context.Background(), 1)
	if err != nil {
		t.Fatalf("Recent: %v", err)
	}
	want := chat.Message{ID: "m1", Author: "ada", Body: "hello", SentAtMS: 1_700_000_000_123, ClientID: "c-9"}
	if len(got) != 1 || got[0] != want {
		t.Fatalf("Recent = %+v, want [%+v]", got, want)
	}
}

// TestRecentSkipsUnparseableSentAtMs covers intAttr's other failure: the
// attribute is a number, so the type guard passes, but the value overflows
// int64. DynamoDB numbers are wider than int64, so this is reachable from real
// data rather than only from a corrupt write.
func TestRecentSkipsUnparseableSentAtMs(t *testing.T) {
	item := map[string]types.AttributeValue{
		"id":       &types.AttributeValueMemberS{Value: "m1"},
		"sentAtMs": &types.AttributeValueMemberN{Value: "99999999999999999999"},
	}
	client := &fakeDynamo{queryOut: &dynamodb.QueryOutput{Items: []map[string]types.AttributeValue{item}}}
	d := &Dynamo{Client: client, MessageTable: "messages"}

	got, err := d.Recent(context.Background(), 1)
	if err != nil {
		t.Fatalf("Recent: %v", err)
	}
	if len(got) != 1 || got[0].SentAtMS != 0 {
		t.Fatalf("Recent = %+v, want SentAtMS 0 for a value that overflows int64", got)
	}
}

func TestRecentReversesQueryOrder(t *testing.T) {
	// Query runs newest-first (ScanIndexForward false) so Limit takes the
	// newest rows; Recent must reverse that back to chronological order.
	newest := map[string]types.AttributeValue{
		"id": &types.AttributeValueMemberS{Value: "new"},
	}
	oldest := map[string]types.AttributeValue{
		"id": &types.AttributeValueMemberS{Value: "old"},
	}
	client := &fakeDynamo{queryOut: &dynamodb.QueryOutput{Items: []map[string]types.AttributeValue{newest, oldest}}}
	d := &Dynamo{Client: client, MessageTable: "messages"}

	got, err := d.Recent(context.Background(), 2)
	if err != nil {
		t.Fatalf("Recent: %v", err)
	}
	if len(got) != 2 || got[0].ID != "old" || got[1].ID != "new" {
		t.Fatalf("Recent = %+v, want [old, new]", got)
	}
}

func TestConnectionsFiltersExpired(t *testing.T) {
	// Without the expiresAt filter, a row DynamoDB has not yet swept would be
	// broadcast to until the GoneException reaped it.
	now := time.Unix(1_000, 0)
	client := &fakeDynamo{scanOut: &dynamodb.ScanOutput{}}
	d := &Dynamo{Client: client, ConnectionTable: "connections", Now: func() time.Time { return now }}

	if _, err := d.Connections(context.Background()); err != nil {
		t.Fatalf("Connections: %v", err)
	}

	if client.lastScan.FilterExpression == nil || *client.lastScan.FilterExpression != "expiresAt > :now" {
		t.Fatalf("FilterExpression = %v, want %q", client.lastScan.FilterExpression, "expiresAt > :now")
	}
	got, ok := client.lastScan.ExpressionAttributeValues[":now"].(*types.AttributeValueMemberN)
	if !ok || got.Value != "1000" {
		t.Fatalf(":now = %+v, want the injected clock's epoch seconds", client.lastScan.ExpressionAttributeValues[":now"])
	}
}
