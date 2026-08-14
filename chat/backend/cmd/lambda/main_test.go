package main

import (
	"context"
	"errors"
	"testing"

	"github.com/aws/aws-lambda-go/events"
	"github.com/aws/aws-sdk-go-v2/aws"

	"github.com/fairyhunter13/web-dev-exercises/chat/backend/internal/chat"
	"github.com/fairyhunter13/web-dev-exercises/chat/backend/internal/gateway"
)

// fakeStore is a minimal gateway.Store whose methods can be told to fail, so
// handle's route dispatch and error contract can be tested without DynamoDB.
type fakeStore struct {
	connectErr    error
	disconnectErr error
	connected     []string
	disconnected  []string
}

func (s *fakeStore) AddConnection(_ context.Context, id string) error {
	if s.connectErr != nil {
		return s.connectErr
	}
	s.connected = append(s.connected, id)
	return nil
}

func (s *fakeStore) RemoveConnection(_ context.Context, id string) error {
	if s.disconnectErr != nil {
		return s.disconnectErr
	}
	s.disconnected = append(s.disconnected, id)
	return nil
}

func (s *fakeStore) Connections(context.Context) ([]string, error) { return nil, nil }
func (s *fakeStore) AppendMessage(context.Context, chat.Message) error {
	return nil
}
func (s *fakeStore) Recent(context.Context, int) ([]chat.Message, error) { return nil, nil }

// fakePoster never actually posts; the routes under test ($connect,
// $disconnect) never call Post, so a nil-returning stub is enough to keep
// handle's dependency on posterFor satisfied without a live API Gateway.
type fakePoster struct{}

func (fakePoster) Post(context.Context, string, []byte) error { return nil }

func withFakePoster(t *testing.T) {
	t.Helper()
	orig := posterFor
	posterFor = func(aws.Config, string, string) gateway.Poster { return fakePoster{} }
	t.Cleanup(func() { posterFor = orig })
}

func TestHandleRoutesConnect(t *testing.T) {
	withFakePoster(t)
	store := &fakeStore{}
	req := events.APIGatewayWebsocketProxyRequest{
		RequestContext: events.APIGatewayWebsocketProxyRequestContext{RouteKey: routeConnect, ConnectionID: "c1"},
	}

	resp, err := handle(context.Background(), aws.Config{}, store, req)
	if err != nil {
		t.Fatalf("handle: %v", err)
	}
	if resp.StatusCode != 200 {
		t.Fatalf("status = %d, want 200", resp.StatusCode)
	}
	if len(store.connected) != 1 || store.connected[0] != "c1" {
		t.Fatalf("connected = %v, want [c1]", store.connected)
	}
}

func TestHandleRoutesDisconnect(t *testing.T) {
	withFakePoster(t)
	store := &fakeStore{}
	req := events.APIGatewayWebsocketProxyRequest{
		RequestContext: events.APIGatewayWebsocketProxyRequestContext{RouteKey: routeDisconnect, ConnectionID: "c1"},
	}

	resp, err := handle(context.Background(), aws.Config{}, store, req)
	if err != nil {
		t.Fatalf("handle: %v", err)
	}
	if resp.StatusCode != 200 {
		t.Fatalf("status = %d, want 200", resp.StatusCode)
	}
	if len(store.disconnected) != 1 || store.disconnected[0] != "c1" {
		t.Fatalf("disconnected = %v, want [c1]", store.disconnected)
	}
}

func TestHandleRoutesDefaultToMessage(t *testing.T) {
	// Any route key other than $connect/$disconnect is the custom sendmessage
	// route; a malformed body must not fail the invocation (Lambda would retry
	// a frame that can never become valid), it must come back 200.
	withFakePoster(t)
	store := &fakeStore{}
	req := events.APIGatewayWebsocketProxyRequest{
		RequestContext: events.APIGatewayWebsocketProxyRequestContext{RouteKey: "sendmessage", ConnectionID: "c1"},
		Body:           `{`,
	}

	resp, err := handle(context.Background(), aws.Config{}, store, req)
	if err != nil {
		t.Fatalf("handle: %v", err)
	}
	if resp.StatusCode != 200 {
		t.Fatalf("status = %d, want 200", resp.StatusCode)
	}
}

func TestHandleReturns500WithNilErrorOnRouteFailure(t *testing.T) {
	// A route failure is reported through the response's status code, not
	// through the returned error: returning a non-nil error here would make
	// the Lambda runtime treat a routing failure as an invocation failure and
	// retry it, which is wrong for $connect (the client would just reconnect).
	withFakePoster(t)
	store := &fakeStore{connectErr: errors.New("dynamo unavailable")}
	req := events.APIGatewayWebsocketProxyRequest{
		RequestContext: events.APIGatewayWebsocketProxyRequestContext{RouteKey: routeConnect, ConnectionID: "c1"},
	}

	resp, err := handle(context.Background(), aws.Config{}, store, req)
	if err != nil {
		t.Fatalf("handle returned error %v, want nil (the failure is carried in the response)", err)
	}
	if resp.StatusCode != 500 {
		t.Fatalf("status = %d, want 500", resp.StatusCode)
	}
}
